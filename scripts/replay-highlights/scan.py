"""Locate official goals on a finalized Cloudflare replay using its burnt-in scoreboard."""

import argparse
from collections import Counter
from io import BytesIO
import itertools
import json
import math
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.parse import urljoin, urlsplit
from urllib.request import Request, urlopen
import uuid

import numpy as np
from PIL import Image, ImageOps


# The OBS scoreboard CSS positions its two scores relative to the video width.
# Scale to one coordinate space first (referee/public/broadcast-scoreboard.css).
WIDTH, HEIGHT = 340, 110
MAX_SECONDS = 3 * 3600
SIDE = {"WHITE": 0, "BLACK": 1, "HOME": 0, "AWAY": 1}


class IncompleteReplay(RuntimeError):
    """The source could not be reliably decoded; the worker should retry later."""


class Unmatched(ValueError):
    """The replay does not provide an unambiguous location for every credited goal."""


def recognize_digit(mask):
    image = Image.fromarray(np.uint8(~mask) * 255).resize((96, 128), Image.Resampling.NEAREST)
    buffer = BytesIO()
    ImageOps.expand(image, 24, 255).save(buffer, "PNG")
    votes = []
    for mode in ("8", "13", "10"):
        result = subprocess.run(
            ["tesseract", "stdin", "stdout", "--psm", mode, "-c", "tessedit_char_whitelist=0123456789"],
            input=buffer.getvalue(), capture_output=True, timeout=10, check=True,
        )
        text = result.stdout.decode().strip()
        if len(text) == 1 and text.isascii() and text.isdigit():
            votes.append(int(text))
    if votes:
        winner, count = Counter(votes).most_common(1)[0]
        if count >= 2:
            return winner
    return None


class ScoreReader:
    def __init__(self):
        self.templates = []

    def digit(self, mask):
        rows, cols = np.where(mask)
        if not len(rows) or np.ptp(rows) < 15 or np.ptp(cols) < 4:
            return None
        isolated = mask[rows.min():rows.max() + 1, cols.min():cols.max() + 1]
        normalized = np.asarray(Image.fromarray(isolated).resize((24, 32), Image.Resampling.NEAREST))
        # The same rendered glyph recurs for hundreds of frames. Tolerate minor
        # compression differences, but never accumulate drift by updating a template.
        for reference, value in self.templates:
            if np.count_nonzero(normalized != reference) < 68:
                return value
        if len(self.templates) >= 160:
            return None
        value = recognize_digit(normalized)
        self.templates.append((normalized, value))
        return value

    def read(self, frame):
        # Verify both panel backgrounds before treating imagery as scoreboard text.
        if np.median(frame[20:60, 166:169]) < 210 or np.median(frame[20:60, 171:174]) > 60:
            return None
        dark = frame[17:61] < 174
        light = frame[17:61] > 110
        # The overlay changes padding and type size on BOTH panels at 10 goals.
        wide = dark[:, 153:164].sum() >= 10 or light[:, 176:187].sum() >= 10
        if wide:
            scores = (self.wide_score(dark[:, 100:165], True), self.wide_score(light[:, 175:240], False))
        else:
            scores = (self.digit(dark[:, 116:153]), self.digit(light[:, 184:221]))
        return scores if None not in scores else None

    def wide_score(self, region, home):
        # Read the tightly spaced digits nearest the central divider. Team labels
        # sit beyond a CSS flex gap and must never be interpreted as a score.
        occupied = np.flatnonzero(region.any(axis=0))
        groups = np.split(occupied, np.flatnonzero(np.diff(occupied) > 1) + 1)
        groups = [group for group in groups if len(group) >= 3]
        if home:
            groups.reverse()
        digits = []
        previous = None
        for group in groups:
            if previous is not None and min(abs(group[0] - previous[-1]), abs(previous[0] - group[-1])) > 5:
                break
            value = self.digit(region[:, group[0]:group[-1] + 1])
            if value is None or len(digits) == 3:
                return None
            digits.append(value)
            previous = group
        if home:
            digits.reverse()
        return int("".join(map(str, digits))) if digits else None


def official_changes(events):
    if not isinstance(events, list):
        raise Unmatched("Expected a chronological list of official events")
    score = [0, 0]
    changes = []
    originals = {}
    seen = set()
    for event in events:
        try:
            event_id = str(uuid.UUID(event["id"]))
            side = SIDE[event["team"]]
            kind = event["event_type"]
            goal_id = event.get("goal_id")
            if goal_id is not None:
                goal_id = str(uuid.UUID(goal_id))
        except (TypeError, AttributeError, KeyError, ValueError):
            raise Unmatched("Incomplete official event") from None
        if event_id in seen:
            raise Unmatched("Duplicate official event")
        seen.add(event_id)
        credited_id = None
        if kind == "GOAL":
            if type(event.get("is_credited")) is not bool or (goal_id is not None and goal_id in originals):
                raise Unmatched("Ambiguous official goal")
            if goal_id is not None:
                originals[goal_id] = (side, event["is_credited"])
            credited_id = event_id if event["is_credited"] else None
            score[side] += 1
        elif kind == "CORRECTION":
            if goal_id is None or originals.pop(goal_id, None) != (side, False):
                raise Unmatched("Correction does not identify a disallowed goal")
            score[side] -= 1
        else:
            raise Unmatched("Unsupported scoreboard event")
        changes.append((tuple(score), credited_id))
    return changes


def align(scores, changes):
    changes = iter(changes)
    previous = None
    last_seen = None
    positions = {}
    for score, samples in itertools.groupby(enumerate(scores), key=lambda sample: sample[1]):
        first, _ = next(samples)
        last = first
        for last, _ in samples:
            pass
        # Reject single-frame OCR spikes. Do not silently bridge long blind spots:
        # a score first visible after an outage cannot establish the goal's time.
        if score is None or first == last:
            continue
        if previous is None:
            if score != (0, 0):
                raise Unmatched("Opening score is missing")
        elif score != previous:
            expected = next(changes, None)
            if expected is None or expected[0] != score or first - last_seen > 5:
                raise Unmatched("Score change does not match the official timeline")
            if expected[1] is not None:
                positions[expected[1]] = first
        previous, last_seen = score, last
    if previous is None or next(changes, None) is not None:
        raise Unmatched("Replay is missing official score changes")
    return positions


def playlist(url):
    parsed = urlsplit(url)
    host = parsed.hostname or ""
    cloudflare = host == "videodelivery.net" or host.endswith((".cloudflarestream.com", ".videodelivery.net"))
    if parsed.scheme != "https" or not cloudflare:
        raise ValueError("Expected a Cloudflare playback URL")
    request = Request(url, headers={"User-Agent": "Mozilla/5.0", "Referer": "https://fieldrush.gg/"})
    # A three-hour replay can contain 5,400 long signed segment URLs.
    limit = 16 * 1024 * 1024
    with urlopen(request, timeout=20) as response:
        body = response.read(limit + 1)
    if len(body) > limit:
        raise IncompleteReplay("Unexpectedly large replay playlist")
    lines = body.decode("utf-8-sig").splitlines()
    if not lines or lines[0] != "#EXTM3U":
        raise IncompleteReplay("Invalid replay playlist")
    return lines


def media_source(url):
    lines = playlist(url)
    variants = []
    for line, following in zip(lines, lines[1:]):
        if line.startswith("#EXT-X-STREAM-INF:"):
            match = re.search(r"(?:^|[:,])RESOLUTION=\d+x(\d+)(?:,|$)", line)
            if match and following and not following.startswith("#"):
                height = int(match[1])
                variants.append((abs(height - 720), height, urljoin(url, following)))
    if variants:
        # One 720p rendition preserves the scoreboard at its calibrated size.
        # Passing the whole master to libavformat can open unused audio/video tracks.
        _, _, url = min(variants)
        lines = playlist(url)
    if "#EXT-X-ENDLIST" not in lines:
        raise IncompleteReplay("Replay playlist is not finalized")
    duration = sum(float(line[8:].split(",")[0]) for line in lines if line.startswith("#EXTINF:"))
    if not math.isfinite(duration) or duration <= 0:
        raise IncompleteReplay("Replay duration is unavailable")
    if duration > MAX_SECONDS:
        raise Unmatched("Replay exceeds supported match duration")
    return url, duration


def check_decoded_duration(frame_count, duration):
    # With 1 Hz sampling the last partial second may round either way.
    if frame_count == 0 or abs(frame_count - duration) > 1:
        raise IncompleteReplay("Decoded timeline does not cover the complete playlist")


def decode_scores(url):
    url, duration = media_source(url)
    command = [
        "ffmpeg", "-nostdin", "-v", "error", "-xerror",
        "-protocol_whitelist", "https,tls,tcp,crypto", "-rw_timeout", "20000000",
        "-user_agent", "Mozilla/5.0", "-referer", "https://fieldrush.gg/",
        "-i", url, "-map", "0:v:0", "-an", "-sn", "-dn", "-threads", "2",
        "-vf", "fps=1:start_time=0:round=up,scale=1280:720,crop=340:110:470:20,format=gray",
        "-frames:v", str(MAX_SECONDS + 1), "-f", "rawvideo", "pipe:1",
    ]
    # Decoder errors may contain signed media URLs. Keep them out of job logs.
    reader = ScoreReader()
    scores = []
    # Buffer at most one score pair per second and finish decoding before deciding
    # a replay is unmatchable. Missing segments can otherwise resemble missed goals.
    with tempfile.TemporaryFile() as errors, subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=errors
    ) as process:
        try:
            while frame := process.stdout.read(WIDTH * HEIGHT):
                if len(frame) != WIDTH * HEIGHT:
                    raise IncompleteReplay("Incomplete decoded frame")
                if len(scores) >= MAX_SECONDS:
                    raise IncompleteReplay("Decoded timeline exceeds the replay duration")
                scores.append(reader.read(np.frombuffer(frame, np.uint8).reshape(HEIGHT, WIDTH)))
            # HLS can skip a failed segment and still exit 0. At -v error, any
            # diagnostic disqualifies this attempt. URLs in stderr stay private.
            if process.wait() != 0 or errors.tell():
                raise IncompleteReplay("Could not decode complete replay")
            check_decoded_duration(len(scores), duration)
        finally:
            process.kill()
            process.stdout.close()
    return scores


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("events", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        changes = official_changes(json.loads(args.events.read_text()))
        positions = align(decode_scores(os.environ["REPLAY_HLS_URL"]), changes)
        args.output.write_text(json.dumps(positions) + "\n")
    except Unmatched as error:
        print(f"Replay could not be aligned: {error}", file=sys.stderr)
        return 2
    except IncompleteReplay as error:
        print(f"Replay scan failed: {error}", file=sys.stderr)
        return 1
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        print(f"Replay scan failed ({type(error).__name__})", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

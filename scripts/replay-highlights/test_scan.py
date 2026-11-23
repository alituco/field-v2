from pathlib import Path
import unittest
from unittest.mock import patch
from uuid import UUID

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from scan import HEIGHT, WIDTH, ScoreReader, Unmatched, align, check_decoded_duration, media_source, official_changes


def goal(number, side, credited=True):
    return {"id": str(UUID(int=number)), "goal_id": str(UUID(int=number + 1000)),
            "team": side, "event_type": "GOAL", "is_credited": credited}


class ReplayScanTests(unittest.TestCase):
    def test_november_score_sequence_retains_only_credited_goals(self):
        events = [goal(1, "BLACK"), goal(2, "WHITE"), goal(3, "BLACK"), goal(4, "BLACK", False),
                  {**goal(5, "BLACK", False), "event_type": "CORRECTION", "goal_id": goal(4, "BLACK")["goal_id"]},
                  goal(6, "WHITE"), goal(7, "BLACK"), goal(8, "WHITE"), goal(9, "BLACK"), goal(10, "BLACK")]
        readings = [(0, (0, 0)), (129, (0, 1)), (158, (1, 1)), (238, (1, 2)), (262, (1, 3)),
                    (279, (1, 2)), (282, (2, 2)), (630, (2, 3)), (882, (3, 3)),
                    (940, (3, 4)), (993, (3, 5))]
        frames = []
        for (start, score), (end, _) in zip(readings, readings[1:] + [(1156, None)]):
            frames.extend([score] * (end - start))
        self.assertEqual(
            align(frames, official_changes(events)),
            {e["id"]: t for e, t in zip(events, [129, 158, 238, 262, 279, 282, 630, 882, 940, 993])
             if e["is_credited"]},
        )

    def test_incomplete_or_unreliable_observations_do_not_publish(self):
        changes = official_changes([goal(1, "HOME")])
        for frames in (
            [(1, 0)] * 5,  # join after kickoff
            [(0, 0)] * 5,  # missing goal
            [(0, 0)] * 2 + [(0, 1)] * 2,  # wrong scoring team
            [(0, 0)] * 2 + [None] * 10 + [(1, 0)] * 2,  # unknown transition time
            [(0, 0)] * 2 + [(1, 0)] + [(0, 0)] * 2,  # transient OCR error
        ):
            with self.subTest(frames=frames), self.assertRaises(Unmatched):
                align(frames, changes)

    def test_full_media_is_required_before_alignment(self):
        for actual in (0, 88, 95):
            with self.subTest(actual=actual), self.assertRaises(RuntimeError):
                check_decoded_duration(actual, 90.75)
        check_decoded_duration(90, 90.75)
        check_decoded_duration(91, 90.75)

    def test_pick_single_720p_rendition_and_require_finalized_playlist(self):
        master = ["#EXTM3U", "#EXT-X-STREAM-INF:BANDWIDTH=5500000,RESOLUTION=1920x1080", "hd.m3u8",
                  "#EXT-X-STREAM-INF:RESOLUTION=1280x720,BANDWIDTH=1550000", "sd.m3u8"]
        media = ["#EXTM3U", "#EXTINF:1.999,", "1.mp4", "#EXTINF:2.000,", "2.mp4", "#EXT-X-ENDLIST"]
        root = "https://customer-example.cloudflarestream.com/video/"
        with patch("scan.playlist", side_effect=[master, media]):
            url, duration = media_source(root + "master.m3u8")
            self.assertEqual(url, root + "sd.m3u8")
            self.assertAlmostEqual(duration, 3.999)
        with patch("scan.playlist", return_value=media[:-1]), self.assertRaises(RuntimeError):
            media_source(root + "processing.m3u8")

    def test_wrong_correction_is_rejected(self):
        event = goal(1, "HOME")
        correction = {**goal(2, "AWAY", False), "event_type": "CORRECTION", "goal_id": event["goal_id"]}
        with self.assertRaises(Unmatched):
            official_changes([event, correction])

    def test_score_reader_works_on_the_overlay_without_using_event_order(self):
        font_path = Path(__file__).resolve().parents[2] / "referee/public/fonts/Outfit.ttf"
        reader = ScoreReader()
        self.assertIsNone(reader.read(np.zeros((HEIGHT, WIDTH), dtype=np.uint8)))
        for home, away in [(0, 0), (2, 5), (3, 0), (10, 3), (5, 12)]:
            with self.subTest(home=home, away=away):
                wide = max(home, away) > 9
                font = ImageFont.truetype(str(font_path), 28 if wide else 39)
                font.set_variation_by_axes([900])
                im = Image.new("L", (WIDTH, HEIGHT), 244)
                draw = ImageDraw.Draw(im)
                draw.rectangle((170, 0, WIDTH - 1, HEIGHT - 1), fill=20)
                edge = 8 if wide else 23
                draw.text((170 - edge, 54), str(home), font=font, fill=25, anchor="rs")
                draw.text((170 + edge, 54), str(away), font=font, fill=196, anchor="ls")
                self.assertEqual(reader.read(np.array(im)), (home, away))


if __name__ == "__main__":
    unittest.main()

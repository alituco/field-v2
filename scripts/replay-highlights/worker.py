"""Claim replay work with a short-lived GitHub identity. Only queue metadata enters the runner."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

STAGING = "nfdkdhdevpstfspazbfn"
PRODUCTION = "zjsjuuhborxrlmdcpvlj"
QUEUE_FILE = Path(os.environ.get("RUNNER_TEMP", tempfile.gettempdir())) / "fieldrush-replay-jobs.json"


def queue_api(project, payload):
    oidc_url = os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"]
    separator = "&" if "?" in oidc_url else "?"
    token_request = Request(oidc_url + separator + urlencode({"audience": "fieldrush-replay-" + project}),
                            headers={"Authorization": "Bearer " + os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]})
    with urlopen(token_request, timeout=20) as response:
        token = json.load(response)["value"]
    request = Request(f"https://{project}.supabase.co/functions/v1/replay-scan-worker",
                      data=json.dumps(payload).encode(),
                      headers={"Content-Type": "application/json", "Authorization": "Bearer " + token})
    with urlopen(request, timeout=30) as response:
        return json.load(response)


def claim(project):
    # A replaced recording or game awaiting finalization can yield to another queued job.
    for _ in range(8):
        result = queue_api(project, {"action": "claim"})
        if not result or not result.get("skip"):
            return result
    return None


def process(project, item, directory):
    event_file = directory / "events.json"
    output = directory / "positions.json"
    event_file.write_text(json.dumps(item["events"]))
    # The media decoder has no access to GitHub's job credentials.
    env = {"PATH": os.environ["PATH"], "REPLAY_HLS_URL": item["hls"], "HOME": str(directory)}
    script = Path(__file__).with_name("scan.py")
    run = subprocess.run([sys.executable, script, event_file, output], env=env, timeout=2400)
    if run.returncode not in (0, 2):
        raise RuntimeError("Replay decoder failed; the lease will expire for retry")
    status = "scanned" if run.returncode == 0 else "unmatched"
    positions = json.loads(output.read_text()) if status == "scanned" else {}
    queue_api(project, {"action": "finish", "job": item["job"], "events": item["events"],
                        "status": status, "positions": positions})
    print(f"{item['job']['source_type']} replay {item['job']['video_id']}: {status}, {len(positions)} goal positions")


def main(command):
    if command == "claim":
        projects = [STAGING]
        if os.environ.get("SCAN_PRODUCTION", "").lower() == "true":
            projects.append(PRODUCTION)
        jobs = []
        for project in projects:
            try:
                pending = queue_api(project, {"action": "available"})
            except HTTPError as error:
                # Production recording functions have an independent deployment switch.
                if project == PRODUCTION and error.code == 404:
                    continue
                raise
            if pending:
                jobs.append(project)
        QUEUE_FILE.write_text(json.dumps(jobs))
        with open(os.environ["GITHUB_OUTPUT"], "a") as outputs:
            print("pending=" + str(bool(jobs)).lower(), file=outputs)
    elif command == "process":
        jobs = json.loads(QUEUE_FILE.read_text())
        QUEUE_FILE.unlink()
        with tempfile.TemporaryDirectory() as directory:
            deadline = time.monotonic() + 40 * 60
            failures = []
            while jobs and time.monotonic() < deadline:
                project = jobs.pop(0)
                try:
                    item = claim(project)
                    if item:
                        process(project, item, Path(directory))
                        jobs.append(project)
                except (HTTPError, RuntimeError, subprocess.TimeoutExpired) as error:
                    failures.append((project, type(error).__name__))
            if failures:
                raise RuntimeError(f"Pending scans will be retried: {failures}")
    else:
        raise ValueError("Unknown worker command")


if __name__ == "__main__":
    main(sys.argv[1])

# Replay goal scanning

When an enabled project publishes a new Cloudflare recording, the broadcast transaction queues it for analysis. The worker samples the scoreboard once per second and compares stable score changes with the referee's ordered goals and reversals. A complete match stores credited event IDs and replay seconds. A completed scan with ambiguous evidence suppresses automatic highlights for that recording. Decoder and network failures leave the recording available for retry.

The app and goal clip service use 30 seconds before the detected scoreboard change and five seconds after, clamped to the video boundaries. The full replay remains playable throughout processing. Older replays without a queue record retain their existing timing. Publishing a replacement recording or amending a queued game's goals triggers fresh analysis.

## Staging verification

After the staging backend deploys, play a recorded game to final and wait for its replay to become ready. Run the existing **Staging smoke** workflow on the staging branch with **Process queued staging replay highlights** selected. The worker uses a short-lived GitHub identity restricted to the approved workflow and branch. The staging mobile build should open the play from its buildup, and downloading or saving that goal should produce the same window.

GitHub reads schedules from the default branch. Once promoted there, the workflow checks for due scans twice hourly. Before promotion, the staging workflow dispatch processes staged recordings on demand. Production queueing follows the existing production recording deployment switch. A manual staging dispatch accesses only staging.

## Testing the detector locally

Install FFmpeg, Tesseract with English trained data, NumPy and Pillow. Run the scanner with the HLS playback URL in the environment and a JSON file of chronological events. The worker supplies each event's ID, side, type, linked goal ID and official credit. The scanner emits a JSON object keyed by event ID on success.

```sh
python3 -m unittest discover -s scripts/replay-highlights
python3 scripts/replay-highlights/scan.py events.json positions.json
```

The second command reads `REPLAY_HLS_URL`. Exit code 2 means the scoreboard could not be aligned. Exit code 1 indicates a processing error.

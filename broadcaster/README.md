# Fieldrush Broadcaster for Mac

The Mac app guides a referee through USB-C camera setup, a local recording test,
a private connection test, and pairing to one solo or clan match. OBS does the
encoding; the referee website controls live video independently of the match clock.
This first release is staging-only and supports one camera/pitch at a time.

## Referee setup

1. Install OBS Studio (developed against OBS 32.1.2) and Fieldrush Broadcaster.
   Connect the Osmo using a **data-capable USB-C cable** and select **Webcam** on
   its screen. The camera must support macOS UVC webcam mode.
2. Open OBS → Tools → WebSocket Server Settings. Enable port 4455 and
   authentication. Enter its password in Fieldrush once. It is encrypted with
   the Mac Keychain; do not share it or disable authentication.
3. Select the USB camera and field-audio input. Verify the picture and moving
   audio meter. Choosing “Muted” intentionally records without audio. The app
   does not capture the laptop screen or desktop sound.
4. Choose a backup folder with at least **5 GB free**, then save the setup.
   Fieldrush creates its own unique OBS profile and scene collection without
   editing personal profiles. It refuses to take over active non-Fieldrush
   outputs. Run the ten-second local recording test.
5. On the assigned match’s referee page, open **Camera and broadcast**, create a
   pairing code, and enter it on the Mac. Codes expire after ten minutes and bind
   this laptop to exactly that match. A shared laptop can be disconnected and
   paired to the next referee’s match after the current output stops.
6. Run **Test private stream**. It checks OBS output and Cloudflare ingestion on
   a separate, non-recording input, never on the public match. Cleanup must
   succeed before a normal stream can start.
7. Use **Start Stream** on the referee website. Local MKV recording starts before
   live output. Start the match clock separately at kickoff. Keep both apps open,
   the Mac powered and its lid open. Fieldrush prevents idle system sleep but
   cannot prevent lid-close sleep, power loss, camera overheating, or cable loss.

OBS retries network interruptions; Fieldrush retries its local OBS connection
after an explicit connection in that app session. An internet error does not
stop the owned local backup. Watch warnings and disk space. Do not change OBS
profiles, stream destinations, recording settings, or pause recording mid-match.

An expired/revoked pairing stops owned output when the app can reach OBS. If OBS
is disconnected and may still be running, reconnect it and stop the output before
changing pairings or closing Fieldrush. Administrators can force-disconnect a
failed laptop through the referee panel. Provider cleanup failures retain the hold.

If OBS lost an output command and cleanup cannot establish its state, fully quit
and reopen OBS, reconnect in Fieldrush, then choose **Stop video and recording**.
The app verifies that the local OBS process actually changed and is idle before
releasing the interrupted session. If its saved recording path was lost, it keeps
the match/time/folder evidence for manual recovery instead of guessing a file;
keep the backup folder and contact the organizer. This reset verification expects
OBS installed at `/Applications/OBS.app`.

A historical **unconfirmed backup** notice stays visible so its original file
and recovery evidence are not forgotten. Once OBS has been verified idle, that
notice alone does not mark the laptop as an error or disable Start Stream on
the phone. Current faults—including disconnected devices, uncertain OBS
operations, or a missing/paused current backup—still block readiness. No old
recording or recovery metadata is deleted to make the laptop ready.

## Guided backup recovery

After the match is FINAL and recording has stopped, choose **Recover a recording**
and select the original complete backup from this paired match. Fieldrush stores
its exact start time and match identity locally. Edited/other-match recordings
and recordings without that metadata are not accepted by this flow.

The resumable upload remains private until you preview and explicitly confirm
replacement. The server checks full-match duration and guards against concurrent
replay changes. Existing webhooks cannot overwrite an attached recovery. There
is no automatic stitching or event-time estimation: partial recordings and
missing match timelines require manual help.

- Finish recovery **before disconnecting or the 24-hour pairing expires**.
  Later recovery or a new laptop for a finished match is not supported yet.
- Maximum file: 20 GiB / three hours. Upload window: six hours, up to three
  preparations per device/day. Keep the original file unchanged.
- Pause/resume is supported. **Start recovery over** forgets the pending local
  upload, not the local recording or an already attached replay.
- Recovery never deletes the local backup. Retain it until the replay is checked.
  Unattached private cloud uploads may incur storage charges; this MVP does not
  automatically delete them.
- If a confirmed replay replacement is interrupted, retry that same recovery.
  Its publication reservation protects the existing replay. If the pairing is
  revoked or expires during this step, an organizer must reconcile the reserved
  recovery; it is deliberately not abandoned automatically.

## Local development and distribution

```sh
cd broadcaster
npm ci
node node_modules/electron/install.js
npm test
npm start
npm run package:mac:local
```

The unsigned local app is generated at `dist/mac-arm64/Fieldrush Broadcaster.app`.
It is for this development Mac, not a referee download. The development build
also offers localhost:3000 for mocked testing. Packaged builds permit only the
Fieldrush staging origin. Opening the app never connects OBS or starts outputs.

`npm run package:mac` builds arm64 and Intel DMG/ZIP files. It requires `CSC_NAME`
to name a **Developer ID Application** certificate plus Apple notarization
credentials (`APPLE_API_KEY`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`, or the supported
Apple ID/password/team combination). An **Apple Distribution** certificate is
not a substitute. Keep signing credentials outside Git. Add signed-installer
hosting before distributing to referees; this build does not publish files.

Dependency check at implementation: the shipped runtime dependencies have no
reported npm advisories. The pinned installer toolchain has a moderate, build-only
`sprintf-js` advisory through electron-builder's downloader/logging dependencies
(GHSA-hp3w-g68c-fv3c). It is not included in the packaged runtime. Do not blindly
apply `npm audit fix --force`, which proposes an older builder version; recheck
the upstream toolchain before distributing signed installers.

## Backend rollout (not run by the desktop build)

Deploy these together after normal review and staging approval:

- Migrations `20261018000100` and `20261018000200`.
- Referee pairing, private-test, command, and recovery endpoints.
- Updated Cloudflare webhook using the atomic replay RPC.
- The matching desktop app.

Cloudflare server credentials remain on the server. The desktop gets only its
scoped device capability and stream credentials, never a Supabase service key.
The old `src/index.mjs` / `.env.local` CLI agent is legacy, is not packaged, and
**will not authenticate against paired-only endpoints**; stop it before rollout.
An uncertain private-test creation older than 5.5 hours also requires organizer
inspection in Cloudflare before releasing its hold; re-creating the input after
the provider's six-hour idempotency window could leave an orphan stream.

Before release, physically test the specific Osmo’s camera/audio support, a full
match, disconnect/reconnect, shared-laptop handoff, private-test cleanup, phone
controls, and recovery on staging. Test signed installers on clean Apple Silicon
and Intel Macs. Offline tests cannot prove camera runtime, USB stability, field
bandwidth, or microphone pickup.

References: [OBS remote control](https://obsproject.com/kb/remote-control-guide),
[Cloudflare live video](https://developers.cloudflare.com/stream/stream-live/),
[resumable uploads](https://developers.cloudflare.com/stream/uploading-videos/resumable-uploads/).

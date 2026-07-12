# Field Broadcaster

The broadcaster is a small process that keeps an outbound connection between
the camera laptop and the Field referee app. It controls the local OBS instance;
the Cloudflare stream key never enters the mobile app or database.

## Camera laptop setup

1. Install and open OBS Studio 28 or newer.
2. Add the camera and microphone to an OBS scene.
3. In OBS, open **Tools > WebSocket Server Settings**.
4. Enable the WebSocket server on port `4455` and set a password.
5. Add that password to `broadcaster/.env.local`.
6. Run `npm install`, then `npm start` from this directory.

Keep OBS and the broadcaster process open on the camera laptop for the whole
match. A healthy process prints `Waiting for a stream command...`; the referee
can then start the broadcast without touching OBS.

The agent creates or updates an OBS Browser Source named `Field Scoreboard`,
sets the Cloudflare RTMPS destination, starts a local backup recording, and
starts or stops streaming when the assigned referee requests it.

When the referee finishes a match, Field leaves the stream running for 30
seconds, then stops OBS and the local recording. Cloudflare notifies the hosted
Supabase function when its recording is ready, and the Flutter match page then
shows the replay automatically.

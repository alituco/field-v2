import { type ReplayClient, syncFinishedRecording } from "./replay.ts";

function assert(ok: unknown, message = "Replay assertion failed."): asserts ok {
  if (!ok) throw new Error(message);
}

const args = {
  kind: "SOLO" as const,
  target_id: "e9d165c0-ef09-4f99-bb84-a934701cfc4d",
  video_id: "abcdef1234567890abcdef1234567890",
  replay_url:
    "https://customer-test.cloudflarestream.com/abcdef1234567890abcdef1234567890/manifest/video.m3u8",
  ready_at: "2026-10-18T12:05:00.000Z",
  expected_requested_at: "2026-10-18T11:00:00.000Z",
  recording_started_at: "2026-10-18T11:00:05.000Z",
  expected_input_id: "1234567890abcdef1234567890abcdef",
};

Deno.test("ready recording uses one atomic RPC with observed stream identity", async () => {
  const calls: unknown[] = [];
  const client: ReplayClient = {
    rpc: (name, input) => {
      calls.push({ name, input });
      return Promise.resolve({ data: true, error: null });
    },
  };
  const result = await syncFinishedRecording(client, args);
  assert(result === "updated");
  assert(calls.length === 1);
  assert(
    JSON.stringify(calls[0]) ===
      JSON.stringify({ name: "sync_broadcast_replay", input: args }),
  );
});

Deno.test("a recovered or superseded stream remains stale with no write fallback", async () => {
  let calls = 0;
  const client: ReplayClient = {
    rpc: () => {
      calls++;
      return Promise.resolve({ data: false, error: null });
    },
  };
  assert(await syncFinishedRecording(client, args) === "stale");
  assert(calls === 1);
});

Deno.test("RPC failure and malformed results never acknowledge a successful attachment", async () => {
  for (const data of [null, undefined, {}, [], [true], "true", 1]) {
    const client: ReplayClient = {
      rpc: () => Promise.resolve({ data, error: null }),
    };
    assert(await syncFinishedRecording(client, args) === "error");
  }
  assert(
    await syncFinishedRecording({
      rpc: () => Promise.resolve({ data: true, error: { message: "private" } }),
    }, args) === "error",
  );
  assert(
    await syncFinishedRecording({
      rpc: () => Promise.reject(new Error("private provider diagnostic")),
    }, args) === "error",
  );
});

Deno.test("clan recordings and absent timestamps retain exact null guards", async () => {
  const input = {
    ...args,
    kind: "CLAN" as const,
    expected_requested_at: null,
    recording_started_at: null,
    expected_input_id: null,
  };
  const client: ReplayClient = {
    rpc: (_name, received) => {
      assert(received.kind === "CLAN");
      assert(received.expected_requested_at === null);
      assert(received.recording_started_at === null);
      assert(received.expected_input_id === null);
      return Promise.resolve({ data: true, error: null });
    },
  };
  assert(await syncFinishedRecording(client, input) === "updated");
});

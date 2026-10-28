type ReplayArguments = {
  kind: "CLAN" | "SOLO";
  target_id: string;
  video_id: string;
  replay_url: string;
  ready_at: string;
  expected_requested_at: string | null;
  recording_started_at: string | null;
  expected_input_id: string | null;
};

export type ReplayClient = {
  rpc(
    name: "sync_broadcast_replay",
    args: ReplayArguments,
  ): PromiseLike<{ data: unknown; error: unknown }>;
};

/** The RPC locks and updates both rows together; a recovered replay always wins. */
export async function syncFinishedRecording(
  client: ReplayClient,
  args: ReplayArguments,
): Promise<"updated" | "stale" | "error"> {
  try {
    const result = await client.rpc("sync_broadcast_replay", args);
    if (result.error || typeof result.data !== "boolean") return "error";
    return result.data ? "updated" : "stale";
  } catch {
    return "error";
  }
}

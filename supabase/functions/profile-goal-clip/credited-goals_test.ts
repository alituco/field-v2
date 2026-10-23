import { creditedGoal, type GoalCreditClient } from "./credited-goals.ts";

function assert(value: unknown): asserts value {
  if (!value) throw new Error("Goal credit assertion failed.");
}

Deno.test("download validates the selected event against authoritative remaining goals", async () => {
  const calls: unknown[] = [];
  const client: GoalCreditClient = {
    rpc: (name, args) => {
      calls.push({ name, args });
      return Promise.resolve({
        data: [{ id: "valid", occurred_at: "2026-10-23T07:00:00Z" }],
        error: null,
      });
    },
  };
  assert(await creditedGoal(client, "SOLO", "match", "removed") === null);
  const valid = await creditedGoal(client, "SOLO", "match", "valid");
  assert(valid?.occurredAt === "2026-10-23T07:00:00Z");
  assert(valid.timestamps.length === 1);
  assert(
    JSON.stringify(calls[0]) === JSON.stringify({
      name: "get_credited_replay_goals",
      args: { source_type_to_use: "SOLO", match_id_to_use: "match" },
    }),
  );
});

Deno.test("cached saved goal revalidation and malformed responses fail closed", async () => {
  for (
    const data of [null, {}, [{ id: "removed" }], [{
      id: "removed",
      occurred_at: "bad",
    }]]
  ) {
    let failed = false;
    try {
      await creditedGoal(
        { rpc: () => Promise.resolve({ data, error: null }) },
        "SOLO",
        "match",
        "removed",
      );
    } catch {
      failed = true;
    }
    assert(failed);
  }
  let failed = false;
  try {
    await creditedGoal(
      { rpc: () => Promise.resolve({ data: [], error: new Error("offline") }) },
      "CLAN",
      "match",
      "goal",
    );
  } catch {
    failed = true;
  }
  assert(failed);
});

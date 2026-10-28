import type { AdminClient, E2EAccount } from "./_shared.ts";
import { cleanAndAssertE2ECheckoutPool } from "./checkouts.ts";

type Checkout = {
  id: string;
  profile_id: string;
  provider: string;
  status: string;
  payload: unknown;
};
type Response<T> = { data: T | null; error: { message: string } | null };
type QueryResponse = Response<Checkout[]>;
type Call = [string, ...unknown[]];

const players = [account(1), account(2)];
const actor = account(99);

Deno.test("checkout preflight uses the guarded RPC then checks every active checkout in the player pool", async () => {
  const mock = mockClient();

  await cleanAndAssertE2ECheckoutPool(mock.client, players, actor);

  assertEquals(mock.calls, expectedCalls());
});

Deno.test("checkout preflight can run again after legacy checkouts have already expired", async () => {
  const mock = mockClient({
    rpcResponses: [
      { data: [uuid(30)], error: null },
      { data: [], error: null },
    ],
  });

  await cleanAndAssertE2ECheckoutPool(mock.client, players, actor);
  await cleanAndAssertE2ECheckoutPool(mock.client, players, actor);

  assertEquals(mock.calls, [...expectedCalls(), ...expectedCalls()]);
});

for (
  const [provider, status, label] of [
    ["STRIPE", "CAPTURED", "captured Stripe"],
    ["STRIPE", "PENDING", "pending Stripe"],
    ["LEGACY", "PENDING", "foreign/manual legacy"],
  ]
) {
  Deno.test(`checkout preflight blocks ${label} payments with actionable diagnostics and no direct mutations`, async () => {
    const intent = Object.freeze({
      id: uuid(30),
      profile_id: players[0].profileId,
      provider,
      status,
      payload: Object.freeze({ game_id: uuid(40) }),
    });
    const original = structuredClone(intent);
    const mock = mockClient({ rows: [intent] });

    const error = await assertRejects(() =>
      cleanAndAssertE2ECheckoutPool(mock.client, players, actor)
    );

    for (
      const diagnostic of [
        players[0].displayName,
        players[0].profileId,
        intent.id,
        `${provider}/${status}`,
        uuid(40),
        "No remaining payments were altered",
        "Manual reconciliation is required",
      ]
    ) {
      assertIncludes(error.message, diagnostic);
    }
    assertEquals(mock.calls, expectedCalls());
    assertEquals(intent, original);
  });
}

Deno.test("checkout preflight reports all blocked players rather than stopping at the first intent", async () => {
  const rows = players.map((player, index) => ({
    id: uuid(30 + index),
    profile_id: player.profileId,
    provider: "STRIPE",
    status: index === 0 ? "CAPTURED" : "PENDING",
    payload: { game_id: uuid(40 + index) },
  }));
  const mock = mockClient({ rows });

  const error = await assertRejects(() =>
    cleanAndAssertE2ECheckoutPool(mock.client, players, actor)
  );

  for (const [index, player] of players.entries()) {
    assertIncludes(error.message, player.displayName);
    assertIncludes(error.message, rows[index].id);
    assertIncludes(error.message, uuid(40 + index));
  }
});

Deno.test("checkout preflight does not query or attempt another write when the cleanup RPC fails", async () => {
  const mock = mockClient({
    rpcResponses: [{
      data: null,
      error: { message: "Protected fixture required" },
    }],
  });

  const error = await assertRejects(() =>
    cleanAndAssertE2ECheckoutPool(mock.client, players, actor)
  );

  assertIncludes(error.message, "E2E checkout cleanup failed");
  assertIncludes(error.message, "Protected fixture required");
  assertEquals(mock.calls, expectedCalls().slice(0, 1));
});

Deno.test("checkout preflight fails closed when remaining checkouts cannot be read", async () => {
  const mock = mockClient({ queryError: "Checkout read unavailable" });

  const error = await assertRejects(() =>
    cleanAndAssertE2ECheckoutPool(mock.client, players, actor)
  );

  assertIncludes(error.message, "E2E checkout preflight failed");
  assertIncludes(error.message, "Checkout read unavailable");
  assertEquals(mock.calls, expectedCalls());
});

Deno.test("checkout preflight still identifies an unresolved intent with malformed game metadata", async () => {
  const mock = mockClient({
    rows: [{
      id: uuid(30),
      profile_id: players[0].profileId,
      provider: "LEGACY",
      status: "PENDING",
      payload: null,
    }],
  });

  const error = await assertRejects(() =>
    cleanAndAssertE2ECheckoutPool(mock.client, players, actor)
  );

  assertIncludes(error.message, uuid(30));
  assertIncludes(error.message, "missing game ID");
  assertIncludes(error.message, "Manual reconciliation is required");
});

function mockClient(options: {
  rows?: Checkout[];
  queryError?: string;
  rpcResponses?: Response<string[]>[];
} = {}) {
  const calls: Call[] = [];
  const rpcResponses = [...(options.rpcResponses ?? [])];
  const queryResponse: QueryResponse = {
    data: options.queryError ? null : options.rows ?? [],
    error: options.queryError ? { message: options.queryError } : null,
  };
  const client = {
    rpc(name: string, args: Record<string, unknown>) {
      calls.push(["rpc", name, args]);
      return Promise.resolve(
        rpcResponses.shift() ?? { data: [], error: null },
      );
    },
    from(table: string) {
      calls.push(["from", table]);
      return new MockCheckoutQuery(calls, queryResponse);
    },
  } as unknown as AdminClient;
  return { client, calls };
}

/** A thenable query recorder with no update/insert/delete capability. */
class MockCheckoutQuery implements PromiseLike<QueryResponse> {
  constructor(
    private calls: Call[],
    private response: QueryResponse,
  ) {}

  select(columns: string): this {
    this.calls.push(["select", columns]);
    return this;
  }

  in(column: string, values: unknown[]): this {
    this.calls.push(["in", column, values]);
    return this;
  }

  eq(column: string, value: unknown): this {
    this.calls.push(["eq", column, value]);
    return this;
  }

  then<TResult1 = QueryResponse, TResult2 = never>(
    onfulfilled?:
      | ((value: QueryResponse) => TResult1 | PromiseLike<TResult1>)
      | null,
    onrejected?:
      | ((reason: unknown) => TResult2 | PromiseLike<TResult2>)
      | null,
  ): PromiseLike<TResult1 | TResult2> {
    return Promise.resolve(this.response).then(onfulfilled, onrejected);
  }
}

function expectedCalls(): Call[] {
  const profileIds = players.map((player) => player.profileId);
  return [
    ["rpc", "expire_staging_e2e_legacy_checkouts", {
      actor_admin_id: actor.profileId,
      player_ids_to_check: profileIds,
    }],
    ["from", "payment_intents"],
    ["select", "id,profile_id,provider,status,payload"],
    ["in", "profile_id", profileIds],
    ["eq", "purpose", "SOLO_BOOKING"],
    ["in", "status", ["PENDING", "CAPTURED"]],
  ];
}

function account(index: number): E2EAccount {
  return {
    profileId: uuid(index),
    phone: `+1555000${String(index).padStart(4, "0")}`,
    displayName: `[E2E] Player ${index}`,
    username: `field_e2e_${index}`,
  };
}

function uuid(index: number): string {
  return `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`;
}

function assertEquals(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, received ${
        JSON.stringify(actual)
      }.`,
    );
  }
}

function assertIncludes(actual: string, expected: string): void {
  if (!actual.includes(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(actual)} to include ${expected}.`,
    );
  }
}

async function assertRejects(run: () => Promise<unknown>): Promise<Error> {
  try {
    await run();
  } catch (error) {
    if (error instanceof Error) return error;
    throw new Error("Expected an Error rejection.");
  }
  throw new Error("Expected the operation to reject.");
}

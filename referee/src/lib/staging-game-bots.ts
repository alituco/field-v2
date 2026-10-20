import { resolveFieldEnvironment } from "./app-environment.ts";
import type { RefereeFixture } from "./types.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type StagingGameBotFill = {
  gameId: string;
  requestId: string;
  createdBots: number;
  confirmedCount: number;
  capacity: number;
  alreadyFilled: boolean;
};

export function isStagingGameBotsEnabled(
  appEnvironment = process.env.NEXT_PUBLIC_APP_ENV,
  supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL,
): boolean {
  const environment = resolveFieldEnvironment(appEnvironment, supabaseUrl);
  return environment.environment === "staging" && environment.error === null;
}

export function canFillGameWithBots(fixture: Pick<RefereeFixture,
  "matchKind" | "status" | "operationalState" | "teamsAssignedAt" | "clock"
>): boolean {
  const clock = fixture.clock;
  return fixture.matchKind === "SOLO" &&
    ["OPEN", "FULL"].includes(fixture.status) &&
    fixture.operationalState === "NORMAL" &&
    fixture.teamsAssignedAt == null &&
    (clock == null || (clock.status === "NOT_STARTED" &&
      clock.startedAt === null && clock.accumulatedSeconds === 0));
}

export function parseStagingBotFillInput(value: unknown): {
  requestId: string;
  confirmation: "FILL_WITH_BOTS";
} {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Confirm that you want to fill this staging game with bots.");
  }
  const body = value as Record<string, unknown>;
  if (Object.keys(body).some(key => !["requestId", "confirmation"].includes(key)) ||
    typeof body.requestId !== "string" || !UUID.test(body.requestId) ||
    body.confirmation !== "FILL_WITH_BOTS") {
    throw new Error("Provide a valid request ID and confirm filling this game with bots.");
  }
  return { requestId: body.requestId.toLowerCase(), confirmation: "FILL_WITH_BOTS" };
}

export function validateStagingBotFillReply(
  value: unknown,
  expected: { gameId: string; requestId: string },
): StagingGameBotFill {
  const invalid = () => new Error("The bot fill could not be confirmed. Refresh the game before trying again.");
  if (!value || typeof value !== "object" || Array.isArray(value)) throw invalid();
  const reply = value as Record<string, unknown>;
  const count = (value: unknown): value is number =>
    typeof value === "number" && Number.isFinite(value) && Number.isInteger(value) && value >= 0;
  if (reply.gameId !== expected.gameId || reply.requestId !== expected.requestId ||
    !count(reply.createdBots) || !count(reply.confirmedCount) || !count(reply.capacity) || reply.capacity < 1 ||
    reply.createdBots > reply.confirmedCount || reply.confirmedCount !== reply.capacity ||
    typeof reply.alreadyFilled !== "boolean" || reply.alreadyFilled !== (reply.createdBots === 0)) {
    throw invalid();
  }
  return {
    gameId: reply.gameId as string,
    requestId: reply.requestId as string,
    createdBots: reply.createdBots,
    confirmedCount: reply.confirmedCount,
    capacity: reply.capacity,
    alreadyFilled: reply.alreadyFilled,
  };
}

import type { SupabaseClient } from "@supabase/supabase-js";
import { parseSoloFormation, type SoloFormation } from "./admin-solo-games.ts";

type Row = Record<string, unknown>;
export type AdminGameFormation = SoloFormation & { canEdit: boolean; lockedReason: string | null };

export function parseGameFormationUpdate(value: unknown): SoloFormation & { reason: string } {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid formation update.");
  const body = value as Row;
  if (Object.keys(body).some((key) => !["goalkeepersPerSide", "defendersPerSide", "attackersPerSide", "reason"].includes(key))) throw new Error("Unknown formation detail.");
  const formation = parseSoloFormation(body);
  if (typeof body.reason !== "string" || body.reason.trim().length < 8 || body.reason.trim().length > 1000) throw new Error("Give a formation change reason between 8 and 1000 characters.");
  return { ...formation, reason: body.reason.trim() };
}

export function buildAdminGameFormation(game: Row, hasBooking: boolean, hasPayment: boolean, clock: Row | null = null, now = new Date()): AdminGameFormation {
  const capacities = [game.goalkeeper_capacity, game.defender_capacity, game.attacker_capacity];
  if (capacities.some((value) => typeof value !== "number" || !Number.isInteger(value) || value < 0 || value % 2 !== 0)) throw new Error("The game’s saved formation is missing or invalid.");
  const [goalkeepersPerSide, defendersPerSide, attackersPerSide] = capacities.map((value) => Number(value) / 2);
  let lockedReason: string | null = null;
  if (game.format_version !== "FIELDRUSH_7V7") lockedReason = "Historical game formations are read-only.";
  else if (goalkeepersPerSide !== 1 || defendersPerSide + attackersPerSide !== 6) throw new Error("The game’s saved formation is invalid.");
  else if (hasBooking || hasPayment) lockedReason = "Formation is locked after the first booking or payment attempt. Create a new game to use a different formation.";
  else if (game.teams_assigned_at != null || game.white_score != null || game.black_score != null) lockedReason = "Teams or match results are already recorded. Formation is locked.";
  else if (game.status !== "OPEN" || game.operational_state !== "NORMAL") lockedReason = "Only an upcoming open game without an operational review can change formation.";
  else if (!Number.isFinite(Date.parse(String(game.starts_at))) || Date.parse(String(game.starts_at)) <= now.getTime()) lockedReason = "The game has reached its scheduled kickoff. Formation is locked.";
  else if (clock && (clock.status !== "NOT_STARTED" || clock.started_at != null || clock.accumulated_seconds !== 0)) lockedReason = "The match clock has already started. Formation is locked.";
  return { goalkeepersPerSide, defendersPerSide, attackersPerSide, canEdit: lockedReason === null, lockedReason };
}

export async function loadAdminGameFormation(db: SupabaseClient, gameId: string): Promise<AdminGameFormation | null> {
  const [game, bookings, payments, clock] = await Promise.all([
    db.from("open_queue_games").select("goalkeeper_capacity,defender_capacity,attacker_capacity,format_version,status,starts_at,operational_state,teams_assigned_at,white_score,black_score").eq("id", gameId).single(),
    db.from("open_queue_bookings").select("id").eq("game_id", gameId).limit(1),
    db.from("payment_intents").select("id").eq("payload->>game_id", gameId).limit(1),
    db.from("open_queue_clock_states").select("status,started_at,accumulated_seconds").eq("game_id", gameId).maybeSingle(),
  ]);
  const error = [game, bookings, payments, clock].find((result) => result.error)?.error;
  if (error || !game.data) throw new Error(`Could not load game formation: ${error?.message ?? "Game not found."}`);
  if (game.data.format_version !== "FIELDRUSH_7V7") return null;
  return buildAdminGameFormation(game.data, Boolean(bookings.data?.length), Boolean(payments.data?.length), clock.data);
}

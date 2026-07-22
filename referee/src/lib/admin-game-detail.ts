import type { SupabaseClient } from "@supabase/supabase-js";

import {
  loadAdminGameParticipants,
  type AdminGameParticipants,
} from "./admin-game-participants";
import {
  loadAdminGameReserves,
  type AdminGameReserve,
} from "./admin-game-reserves";
import { loadAdminOpenQueueGames } from "./open-queue-referee-data";
import { loadAdminFixtures } from "./referee-data";
import type { RefereeFixture } from "./types";

export type AdminGameAuditItem = {
  id: string;
  action: string;
  reason: string;
  actorName: string;
  createdAt: string;
};

export type AdminGameReportSummary = {
  id: string;
  category: string;
  status: string;
  priority: string;
  details: string;
  createdAt: string;
};

export type AdminGameStoppageSummary = {
  id: string;
  mode: string;
  state: string;
  reasonCode: string;
  note: string | null;
  createdAt: string;
};

export type AdminGameDetail = {
  fixture: RefereeFixture;
  participants: AdminGameParticipants;
  reserves: {
    active: AdminGameReserve[];
    history: AdminGameReserve[];
  };
  assignedReferee: {
    profileId: string;
    displayName: string;
    phone: string;
  } | null;
  audit: AdminGameAuditItem[];
  reports: AdminGameReportSummary[];
  stoppages: AdminGameStoppageSummary[];
};

type Row = Record<string, unknown>;

export async function loadAdminGameDetail(
  db: SupabaseClient,
  matchKind: "SOLO" | "CLAN",
  matchId: string,
): Promise<AdminGameDetail> {
  const gamePromise = matchKind === "SOLO"
    ? loadAdminOpenQueueGames(db)
    : loadAdminFixtures(db);
  const assignmentTable = matchKind === "SOLO"
    ? "open_queue_referee_assignments"
    : "fixture_referee_assignments";
  const assignmentKey = matchKind === "SOLO" ? "game_id" : "fixture_id";
  const entityType = matchKind === "SOLO" ? "SOLO_MATCH" : "CLAN_MATCH";
  const reportKey = matchKind === "SOLO" ? "open_queue_game_id" : "fixture_id";

  const [
    games,
    participants,
    reserves,
    assignmentResult,
    auditResult,
    reportResult,
    stoppageResult,
  ] = await Promise.all([
    gamePromise,
    loadAdminGameParticipants(db, matchKind, matchId),
    loadAdminGameReserves(db, matchKind, matchId),
    db.from(assignmentTable).select(`
      referee_id,
      referee:referee_profiles!${assignmentTable}_referee_id_fkey(
        profile_id,
        display_name,
        phone
      )
    `).eq(assignmentKey, matchId).maybeSingle(),
    db.from("admin_audit_events").select(`
      id,
      action,
      reason,
      created_at,
      actor:referee_profiles!admin_audit_events_actor_referee_id_fkey(
        display_name
      )
    `).eq("entity_type", entityType).eq("entity_id", matchId)
      .order("created_at", { ascending: false }).limit(30),
    db.from("moderation_reports")
      .select("id,category,status,priority,details,created_at")
      .eq(reportKey, matchId).order("created_at", { ascending: false }).limit(20),
    db.from("match_stoppages")
      .select("id,mode,state,reason_code,note,created_at")
      .eq(reportKey, matchId).order("created_at", { ascending: false }).limit(20),
  ]);

  const fixture = games.find((game) => game.id === matchId);
  if (!fixture) throw new Error(matchKind === "SOLO" ? "Solo game not found." : "Clan fixture not found.");
  if (assignmentResult.error) throw new Error(`Could not load referee: ${assignmentResult.error.message}`);
  if (auditResult.error) throw new Error(`Could not load game audit: ${auditResult.error.message}`);
  if (reportResult.error) throw new Error(`Could not load game reports: ${reportResult.error.message}`);
  if (stoppageResult.error) throw new Error(`Could not load stoppages: ${stoppageResult.error.message}`);

  const assignment = assignmentResult.data as Row | null;
  const referee = relation(assignment?.referee);
  return {
    fixture,
    participants,
    reserves,
    assignedReferee: assignment && referee.profile_id ? {
      profileId: text(referee.profile_id),
      displayName: text(referee.display_name, "Referee"),
      phone: text(referee.phone),
    } : null,
    audit: rows(auditResult.data).map((row) => ({
      id: text(row.id),
      action: text(row.action),
      reason: text(row.reason),
      actorName: text(relation(row.actor).display_name, "Administrator"),
      createdAt: text(row.created_at),
    })),
    reports: rows(reportResult.data).map((row) => ({
      id: text(row.id),
      category: text(row.category),
      status: text(row.status),
      priority: text(row.priority),
      details: text(row.details),
      createdAt: text(row.created_at),
    })),
    stoppages: rows(stoppageResult.data).map((row) => ({
      id: text(row.id),
      mode: text(row.mode),
      state: text(row.state),
      reasonCode: text(row.reason_code),
      note: nullableText(row.note),
      createdAt: text(row.created_at),
    })),
  };
}

function relation(value: unknown): Row {
  if (Array.isArray(value)) return relation(value[0]);
  return value && typeof value === "object" ? value as Row : {};
}

function rows(value: unknown): Row[] {
  return Array.isArray(value)
    ? value.filter((row): row is Row => Boolean(row) && typeof row === "object")
    : [];
}

function text(value: unknown, fallback = "") {
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return typeof value === "string" && value.trim() ? value.trim() : fallback;
}

function nullableText(value: unknown) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

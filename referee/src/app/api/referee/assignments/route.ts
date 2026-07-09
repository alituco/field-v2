import { NextRequest, NextResponse } from "next/server";

import {
  adminOnly,
  isRefereeContext,
  requireReferee,
} from "@/lib/referee-session";
import type {
  AssignableFixture,
  RefereeAssignmentsResponse,
  RefereeListItem,
} from "@/lib/types";

const assignmentFixtureSelect = `
  id,
  status,
  venue,
  match_date,
  time_slot,
  home_clan:clans!fixtures_home_clan_id_fkey(
    id,
    name,
    tag,
    emblem,
    skill_rating
  ),
  away_clan:clans!fixtures_away_clan_id_fkey(
    id,
    name,
    tag,
    emblem,
    skill_rating
  )
`;

export async function GET(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const adminError = adminOnly(context.referee);
  if (adminError) return adminError;

  try {
    const [refereesResult, fixturesResult, assignmentsResult] = await Promise.all([
      context.db
        .from("referee_profiles")
        .select("profile_id,display_name,phone,role")
        .eq("is_active", true)
        .order("display_name"),
      context.db
        .from("fixtures")
        .select(assignmentFixtureSelect)
        .in("status", ["SCHEDULED", "LIVE"])
        .not("away_clan_id", "is", null)
        .order("match_date")
        .order("time_slot"),
      context.db
        .from("fixture_referee_assignments")
        .select("fixture_id,referee_id"),
    ]);

    if (refereesResult.error) throw refereesResult.error;
    if (fixturesResult.error) throw fixturesResult.error;
    if (assignmentsResult.error) throw assignmentsResult.error;

    const refereeByFixture = new Map(
      (assignmentsResult.data ?? []).map((row) => [
        String(row.fixture_id),
        String(row.referee_id),
      ]),
    );

    const payload: RefereeAssignmentsResponse = {
      referees: (refereesResult.data ?? []).map((row) => ({
        profileId: String(row.profile_id),
        displayName: String(row.display_name),
        phone: String(row.phone),
        role: String(row.role) === "admin" ? "admin" : "referee",
      } satisfies RefereeListItem)),
      fixtures: (fixturesResult.data ?? []).map((row) =>
        normalizeAssignableFixture(
          row as Record<string, unknown>,
          refereeByFixture.get(String(row.id)) ?? null,
        )
      ),
    };

    return NextResponse.json(payload);
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Could not load assignments." },
      { status: 500 },
    );
  }
}

export async function POST(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const adminError = adminOnly(context.referee);
  if (adminError) return adminError;

  try {
    const body = (await request.json()) as {
      fixtureId?: string;
      refereeId?: string | null;
    };
    const fixtureId = requireValue(body.fixtureId, "Missing fixture.");

    if (!body.refereeId) {
      const { error } = await context.db
        .from("fixture_referee_assignments")
        .delete()
        .eq("fixture_id", fixtureId);

      if (error) throw error;
      return NextResponse.json({ ok: true });
    }

    const { error } = await context.db
      .from("fixture_referee_assignments")
      .upsert(
        {
          fixture_id: fixtureId,
          referee_id: body.refereeId,
          assigned_by: context.referee.profileId,
        },
        { onConflict: "fixture_id" },
      );

    if (error) throw error;
    return NextResponse.json({ ok: true });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Could not assign referee." },
      { status: 400 },
    );
  }
}

function normalizeAssignableFixture(
  row: Record<string, unknown>,
  assignedRefereeId: string | null,
): AssignableFixture {
  return {
    id: String(row.id),
    status: String(row.status) as AssignableFixture["status"],
    venue: String(row.venue ?? ""),
    matchDate: String(row.match_date ?? ""),
    timeSlot: String(row.time_slot ?? ""),
    homeClan: normalizeClan(asObject(row.home_clan)),
    awayClan: normalizeClan(asObject(row.away_clan)),
    assignedRefereeId,
  };
}

function normalizeClan(row: Record<string, unknown>) {
  return {
    id: String(row.id),
    name: String(row.name ?? ""),
    tag: String(row.tag ?? ""),
    emblem: String(row.emblem ?? "⚽"),
    skillRating: Number(row.skill_rating ?? 1500),
  };
}

function asObject(value: unknown): Record<string, unknown> {
  if (Array.isArray(value)) return asObject(value[0]);
  if (value && typeof value === "object") {
    return value as Record<string, unknown>;
  }
  return {};
}

function requireValue(value: string | undefined, message: string) {
  if (!value) throw new Error(message);
  return value;
}

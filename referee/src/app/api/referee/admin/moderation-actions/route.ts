import { NextRequest, NextResponse } from "next/server";

import {
  adminOnly,
  isRefereeContext,
  requireReferee,
} from "@/lib/referee-session";

type ActionMapping = {
  canonical: "WARNING" | "SUSPENSION" | "BAN";
  scope: "NONE" | "PLAY" | "ACCOUNT" | "SCHEDULING";
};

const ACTIONS: Record<string, ActionMapping> = {
  WARNING: { canonical: "WARNING", scope: "NONE" },
  PLAY_SUSPENSION: { canonical: "SUSPENSION", scope: "PLAY" },
  ACCOUNT_SUSPENSION: { canonical: "SUSPENSION", scope: "ACCOUNT" },
  PERMANENT_BAN: { canonical: "BAN", scope: "ACCOUNT" },
  CLAN_SCHEDULING_FREEZE: { canonical: "SUSPENSION", scope: "SCHEDULING" },
  CLAN_DISQUALIFICATION: { canonical: "BAN", scope: "SCHEDULING" },
};

function publicMessage(action: ActionMapping, reasonCode: string) {
  const reason = reasonCode
    .toLowerCase()
    .replaceAll("_", " ")
    .replace(/^./, (letter) => letter.toUpperCase());
  if (action.canonical === "WARNING") {
    return `A Field administrator issued a warning for: ${reason}. Please review the community rules.`;
  }
  if (action.scope === "PLAY") {
    return `Your ability to join Field matches is temporarily suspended for: ${reason}.`;
  }
  if (action.scope === "SCHEDULING") {
    return `This clan cannot schedule Field matches because of: ${reason}.`;
  }
  return action.canonical === "BAN"
    ? `This Field account has been permanently banned for: ${reason}.`
    : `This Field account is temporarily suspended for: ${reason}.`;
}

export async function POST(request: NextRequest) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;

  const body = (await request.json().catch(() => null)) as Record<string, unknown> | null;
  const subjectType = String(body?.subjectType ?? "").toUpperCase();
  const subjectId = typeof body?.subjectId === "string" ? body.subjectId : "";
  const requestedAction = String(body?.actionType ?? "").toUpperCase();
  const action = ACTIONS[requestedAction];
  const reasonCode = String(body?.reasonCode ?? "").trim().toUpperCase();
  const note = typeof body?.note === "string" ? body.note.trim() : "";
  const endsAt = typeof body?.endsAt === "string" && body.endsAt.length > 0
    ? body.endsAt
    : null;
  const reportId = typeof body?.reportId === "string" && body.reportId.length > 0
    ? body.reportId
    : null;

  if (!action) {
    return NextResponse.json({ error: "Choose a valid moderation action." }, { status: 400 });
  }
  if (!["PLAYER", "CLAN"].includes(subjectType) || !subjectId) {
    return NextResponse.json({ error: "Choose a player or clan." }, { status: 400 });
  }
  if (subjectType === "CLAN" && !["WARNING", "CLAN_SCHEDULING_FREEZE", "CLAN_DISQUALIFICATION"].includes(requestedAction)) {
    return NextResponse.json({ error: "That action does not apply to a clan." }, { status: 400 });
  }
  if (subjectType === "PLAYER" && ["CLAN_SCHEDULING_FREEZE", "CLAN_DISQUALIFICATION"].includes(requestedAction)) {
    return NextResponse.json({ error: "That action does not apply to a player." }, { status: 400 });
  }
  if (reasonCode.length < 2 || note.length < 10) {
    return NextResponse.json(
      { error: "Choose a reason and record the evidence for this decision." },
      { status: 400 },
    );
  }
  if (action.canonical === "SUSPENSION") {
    const end = endsAt ? Date.parse(endsAt) : Number.NaN;
    if (!Number.isFinite(end) || end <= Date.now()) {
      return NextResponse.json(
        { error: "Choose a future end date for the suspension." },
        { status: 400 },
      );
    }
  }

  if (action.canonical !== "WARNING") {
    const subjectColumn = subjectType === "PLAYER"
      ? "subject_profile_id"
      : "subject_clan_id";
    const now = new Date().toISOString();
    const { data: existingActions, error: existingError } = await context.db
      .from("moderation_actions")
      .select("id")
      .eq("subject_type", subjectType)
      .eq(subjectColumn, subjectId)
      .eq("action_type", action.canonical)
      .eq("restriction_scope", action.scope)
      .is("revoked_at", null)
      .lte("starts_at", now)
      .or(`ends_at.is.null,ends_at.gt.${now}`)
      .limit(1);
    if (existingError) {
      return NextResponse.json(
        { error: `Could not verify current restrictions: ${existingError.message}` },
        { status: 500 },
      );
    }
    if (existingActions && existingActions.length > 0) {
      return NextResponse.json(
        { error: "That restriction is already active. Revoke it before issuing a replacement." },
        { status: 409 },
      );
    }
  }

  const { data, error } = await context.db.rpc("admin_apply_moderation_action", {
    actor_admin_id: context.referee.profileId,
    subject_type_to_use: subjectType,
    subject_id_to_use: subjectId,
    action_type_to_use: action.canonical,
    reason_code_to_use: reasonCode,
    user_message_to_use: publicMessage(action, reasonCode),
    private_note_to_use: note,
    ends_at_to_use: action.canonical === "SUSPENSION" ? endsAt : null,
    report_id_to_use: reportId,
    restriction_scope_to_use: action.scope,
  });
  if (error) {
    return NextResponse.json({ error: error.message }, { status: 400 });
  }

  return NextResponse.json({ actionId: data });
}

import { NextRequest, NextResponse } from "next/server";

import {
  adminOnly,
  isRefereeContext,
  requireReferee,
} from "@/lib/referee-session";

type RouteContext = { params: Promise<{ reportId: string }> };
type ReportAction = "TRIAGE" | "INVESTIGATE" | "RESOLVE" | "DISMISS" | "DUPLICATE";

const ACTIONS = new Set<ReportAction>([
  "TRIAGE",
  "INVESTIGATE",
  "RESOLVE",
  "DISMISS",
  "DUPLICATE",
]);

export async function POST(request: NextRequest, route: RouteContext) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;

  const { reportId } = await route.params;
  const body = (await request.json().catch(() => null)) as {
    action?: unknown;
    resolutionNote?: unknown;
  } | null;
  const action = String(body?.action ?? "").toUpperCase() as ReportAction;
  const resolutionNote = typeof body?.resolutionNote === "string"
    ? body.resolutionNote.trim()
    : null;

  if (!ACTIONS.has(action)) {
    return NextResponse.json({ error: "Choose a valid report action." }, { status: 400 });
  }
  if (["RESOLVE", "DISMISS", "DUPLICATE"].includes(action) &&
      (!resolutionNote || resolutionNote.length < 3)) {
    return NextResponse.json(
      { error: "Add a short decision note for the audit log." },
      { status: 400 },
    );
  }

  const { data: currentReport, error: currentError } = await context.db
    .from("moderation_reports")
    .select("status")
    .eq("id", reportId)
    .maybeSingle();
  if (currentError) {
    return NextResponse.json(
      { error: `Could not verify report state: ${currentError.message}` },
      { status: 500 },
    );
  }
  if (!currentReport) {
    return NextResponse.json({ error: "Report not found." }, { status: 404 });
  }
  const allowedByStatus: Record<string, ReportAction[]> = {
    OPEN: ["TRIAGE", "INVESTIGATE", "RESOLVE", "DISMISS", "DUPLICATE"],
    TRIAGED: ["INVESTIGATE", "RESOLVE", "DISMISS", "DUPLICATE"],
    INVESTIGATING: ["RESOLVE", "DISMISS", "DUPLICATE"],
  };
  if (!allowedByStatus[String(currentReport.status)]?.includes(action)) {
    return NextResponse.json(
      { error: "This report is already closed or that transition is not allowed." },
      { status: 409 },
    );
  }

  const { data, error } = await context.db.rpc("admin_update_moderation_report", {
    actor_admin_id: context.referee.profileId,
    report_id_to_update: reportId,
    action_to_take: action,
    resolution_note_to_use: resolutionNote,
  });
  if (error) {
    return NextResponse.json({ error: error.message }, { status: 400 });
  }

  return NextResponse.json({ report: data });
}

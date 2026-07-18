import { NextRequest, NextResponse } from "next/server";

import {
  loadAdminSupportTicket,
  parseAdminSupportActionInput,
} from "@/lib/admin-support";
import {
  adminOnly,
  isRefereeContext,
  requireReferee,
} from "@/lib/referee-session";

type RouteContext = { params: Promise<{ ticketId: string }> };

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function POST(request: NextRequest, route: RouteContext) {
  const context = await requireReferee(request);
  if (!isRefereeContext(context)) return context;
  const denied = adminOnly(context.referee);
  if (denied) return denied;

  const { ticketId } = await route.params;
  if (!UUID_PATTERN.test(ticketId)) {
    return NextResponse.json(
      { error: "Support request not found." },
      { status: 404 },
    );
  }

  let input;
  try {
    input = parseAdminSupportActionInput(
      await request.json().catch(() => null),
    );
  } catch (error) {
    return NextResponse.json(
      {
        error: error instanceof Error
          ? error.message
          : "Choose a valid support action.",
      },
      { status: 400 },
    );
  }

  const { error } = await context.db.rpc("admin_update_support_ticket", {
    actor_admin_id: context.referee.profileId,
    ticket_id_to_update: ticketId,
    action_to_take: input.action,
    expected_revision_to_use: input.expectedRevision,
    resolution_note_to_use: input.resolutionNote,
    admin_note_to_use: input.adminNote,
  });
  if (error) {
    const message = error.message || "Could not update the support request.";
    return NextResponse.json(
      { error: message },
      { status: supportActionErrorStatus(message) },
    );
  }

  try {
    const ticket = await loadAdminSupportTicket(context.db, ticketId);
    if (!ticket) {
      return NextResponse.json(
        { error: "Support request not found." },
        { status: 404 },
      );
    }
    return NextResponse.json({ ticket });
  } catch (error) {
    return NextResponse.json(
      {
        error: error instanceof Error
          ? error.message
          : "The request was updated, but could not be reloaded.",
      },
      { status: 500 },
    );
  }
}

function supportActionErrorStatus(message: string): number {
  const normalized = message.toLowerCase();
  if (normalized.includes("not found")) return 404;
  if (
    normalized.includes("revision") ||
    normalized.includes("refresh") ||
    normalized.includes("changed") ||
    normalized.includes("transition") ||
    normalized.includes("already")
  ) {
    return 409;
  }
  return 400;
}

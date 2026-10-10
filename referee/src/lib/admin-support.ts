import type { createSupabaseAdmin } from "./supabase-admin";

type AdminDb = ReturnType<typeof createSupabaseAdmin>;
type Row = Record<string, unknown>;

export const ACTIVE_SUPPORT_TICKET_STATUSES = ["OPEN", "IN_PROGRESS"] as const;
export const SUPPORT_TICKET_STATUSES = [
  "ACTIVE",
  "OPEN",
  "IN_PROGRESS",
  "RESOLVED",
  "CLOSED",
  "DUPLICATE",
  "ALL",
] as const;
export const SUPPORT_TICKET_ACTIONS = [
  "START",
  "RESOLVE",
  "CLOSE",
  "REOPEN",
  "DUPLICATE",
] as const;

export type SupportTicketStatusFilter =
  typeof SUPPORT_TICKET_STATUSES[number];
export type SupportTicketAction = typeof SUPPORT_TICKET_ACTIONS[number];

export type AdminSupportTicket = {
  id: string;
  reference: string;
  status: string;
  priority: string;
  category: string;
  subject: string;
  description: string;
  source: string;
  requesterId: string | null;
  requesterName: string;
  requesterUsername: string | null;
  requesterAvatarUrl: string | null;
  assignedTo: string | null;
  resolutionNote: string | null;
  adminNote: string | null;
  revision: number;
  createdAt: string | null;
  updatedAt: string | null;
};

export type AdminSupportActionInput = {
  action: SupportTicketAction;
  expectedRevision: number;
  resolutionNote: string | null;
  adminNote: string | null;
};

export function parseSupportTicketStatusFilter(
  value: unknown,
): SupportTicketStatusFilter {
  const normalized = String(value ?? "ACTIVE").trim().toUpperCase();
  if (!SUPPORT_TICKET_STATUSES.includes(
    normalized as SupportTicketStatusFilter,
  )) {
    throw new Error("Unknown support ticket status.");
  }
  return normalized as SupportTicketStatusFilter;
}

export function parseAdminSupportActionInput(
  value: unknown,
): AdminSupportActionInput {
  const body = row(value);
  const action = String(body.action ?? "").trim().toUpperCase();
  if (!SUPPORT_TICKET_ACTIONS.includes(action as SupportTicketAction)) {
    throw new Error("Choose a valid support action.");
  }

  const expectedRevision = integerValue(body.expectedRevision);
  if (expectedRevision === null || expectedRevision < 0) {
    throw new Error("Refresh this ticket before changing it.");
  }

  const resolutionNote = optionalNote(
    body.resolutionNote,
    "The response to the player",
    2000,
  );
  const adminNote = optionalNote(
    body.adminNote,
    "The private admin note",
    3000,
  );

  if (["RESOLVE", "DUPLICATE"].includes(action) && !resolutionNote) {
    throw new Error("Add a short response for the player.");
  }
  if (["CLOSE", "DUPLICATE"].includes(action) && !adminNote) {
    throw new Error(
      action === "DUPLICATE"
        ? "Record which request this duplicates in the private note."
        : "Record why this resolved request is being closed.",
    );
  }

  return {
    action: action as SupportTicketAction,
    expectedRevision,
    resolutionNote,
    adminNote,
  };
}

export async function loadAdminSupportTickets(
  db: AdminDb,
  status: SupportTicketStatusFilter = "ACTIVE",
): Promise<AdminSupportTicket[]> {
  let query = db
    .from("support_tickets")
    .select("*")
    .order("created_at", { ascending: false })
    .limit(250);

  if (status === "ACTIVE") {
    query = query.in("status", [...ACTIVE_SUPPORT_TICKET_STATUSES]);
  } else if (status !== "ALL") {
    query = query.eq("status", status);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Could not load support requests: ${error.message}`);
  }
  return hydrateSupportTickets(db, rows(data));
}

export async function loadAdminSupportTicket(
  db: AdminDb,
  ticketId: string,
): Promise<AdminSupportTicket | null> {
  const { data, error } = await db
    .from("support_tickets")
    .select("*")
    .eq("id", ticketId)
    .maybeSingle();
  if (error) {
    throw new Error(`Could not load the support request: ${error.message}`);
  }
  if (!data) return null;
  const [ticket] = await hydrateSupportTickets(db, [row(data)]);
  return ticket ?? null;
}

async function hydrateSupportTickets(
  db: AdminDb,
  tickets: Row[],
): Promise<AdminSupportTicket[]> {
  const requesterIds = unique(
    tickets.map((ticket) => stringValue(ticket.requester_profile_id)),
  );
  const refereeIds = unique(
    tickets.flatMap((ticket) => [
      stringValue(ticket.assigned_admin_id),
      stringValue(ticket.resolved_by),
      stringValue(ticket.closed_by),
    ]),
  );

  const [profileResult, refereeResult] = await Promise.all([
    requesterIds.length > 0
      ? db
          .from("profiles")
          .select("id,display_name,username,avatar_url")
          .in("id", requesterIds)
      : Promise.resolve({ data: [], error: null }),
    refereeIds.length > 0
      ? db
          .from("referee_profiles")
          .select("profile_id,display_name")
          .in("profile_id", refereeIds)
      : Promise.resolve({ data: [], error: null }),
  ]);

  if (profileResult.error) {
    throw new Error(
      `Could not load support request players: ${profileResult.error.message}`,
    );
  }
  if (refereeResult.error) {
    throw new Error(
      `Could not load support request admins: ${refereeResult.error.message}`,
    );
  }

  const profiles = new Map(
    rows(profileResult.data).map((profile) => [String(profile.id), profile]),
  );
  const referees = new Map(
    rows(refereeResult.data).map((referee) => [
      String(referee.profile_id),
      referee,
    ]),
  );

  return tickets.map((ticket) =>
    normalizeAdminSupportTicket(ticket, profiles, referees)
  );
}

export function normalizeAdminSupportTicket(
  ticket: Row,
  profiles: Map<string, Row> = new Map(),
  referees: Map<string, Row> = new Map(),
): AdminSupportTicket {
  const id = String(ticket.id ?? "");
  const requesterId = stringValue(ticket.requester_profile_id);
  const requester = requesterId ? profiles.get(requesterId) : undefined;
  const assignedAdminId = stringValue(ticket.assigned_admin_id);
  const assignedAdmin = assignedAdminId
    ? referees.get(assignedAdminId)
    : undefined;
  const category = upperValue(ticket.category, "OTHER");
  const context = row(ticket.context);
  const referenceNumber = integerValue(ticket.reference_number);

  return {
    id,
    reference:
      stringValue(ticket.reference) ??
      stringValue(ticket.ticket_reference) ??
      (referenceNumber !== null
        ? `FIELD-${String(referenceNumber).padStart(6, "0")}`
        : supportTicketReference(id)),
    status: upperValue(ticket.status, "OPEN"),
    priority: upperValue(ticket.priority, "NORMAL"),
    category,
    subject: stringValue(ticket.subject) ?? supportTicketSubject(category),
    description:
      stringValue(ticket.details) ??
      stringValue(ticket.description) ??
      "",
    source: upperValue(
      ticket.source ?? context.source ?? context.entry_point,
      "MOBILE_PROFILE",
    ),
    requesterId,
    requesterName:
      stringValue(requester?.display_name) ??
      stringValue(ticket.requester_name) ??
      (requesterId ? "Unknown player" : "Deleted account"),
    requesterUsername:
      stringValue(requester?.username) ??
      stringValue(ticket.requester_username),
    requesterAvatarUrl:
      stringValue(requester?.avatar_url) ??
      stringValue(ticket.requester_avatar_url),
    assignedTo:
      stringValue(assignedAdmin?.display_name) ??
      stringValue(ticket.assigned_to),
    resolutionNote:
      stringValue(ticket.resolution_note) ??
      stringValue(ticket.user_resolution_note),
    adminNote:
      stringValue(ticket.admin_note) ??
      stringValue(ticket.private_admin_note),
    revision: Math.max(0, integerValue(ticket.revision) ?? 0),
    createdAt: stringValue(ticket.created_at),
    updatedAt: stringValue(ticket.updated_at),
  };
}

export function supportTicketReference(id: string): string {
  const normalized = id.replaceAll("-", "").slice(0, 8).toUpperCase();
  return normalized ? `SUP-${normalized}` : "SUP-UNKNOWN";
}

export function supportTicketSubject(category: string): string {
  return {
    APP_OR_TECHNICAL: "App or technical problem",
    BOOKING_OR_PAYMENT: "Booking or payment",
    MATCH_OR_VENUE: "Match or venue",
    ACCOUNT_OR_PROFILE: "Account or profile",
    SAFETY: "Safety concern",
    FEEDBACK: "Feedback",
    OTHER: "Something else",
  }[category.toUpperCase()] ?? "Support request";
}

function optionalNote(
  value: unknown,
  label: string,
  maximumLength: number,
): string | null {
  if (value === null || value === undefined) return null;
  if (typeof value !== "string") {
    throw new Error(`${label} must be text.`);
  }
  const normalized = value.trim();
  if (!normalized) return null;
  if (normalized.length < 3) {
    throw new Error(`${label} is too short.`);
  }
  if (normalized.length > maximumLength) {
    throw new Error(`${label} is too long.`);
  }
  return normalized;
}

function integerValue(value: unknown): number | null {
  if (
    typeof value === "number" &&
    Number.isSafeInteger(value)
  ) {
    return value;
  }
  return null;
}

function upperValue(value: unknown, fallback: string): string {
  return stringValue(value)?.toUpperCase() ?? fallback;
}

function stringValue(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0
    ? value.trim()
    : null;
}

function row(value: unknown): Row {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Row
    : {};
}

function rows(value: unknown): Row[] {
  return Array.isArray(value)
    ? value
        .filter((item) =>
          item !== null && typeof item === "object" && !Array.isArray(item)
        )
        .map((item) => item as Row)
    : [];
}

function unique(values: Array<string | null>): string[] {
  return [...new Set(values.filter((value): value is string => value !== null))];
}

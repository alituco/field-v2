export type AdminReferralEntry = {
  id: string;
  name: string;
  username: string;
  rank: number | null;
  referralCount: number;
  gamesPlayed: number;
  referredGamesPlayed: number;
  needsReview: boolean;
  prizeEligible: boolean;
};

export type AdminReferralTie = {
  evidenceToken: string;
  rank: number;
  referralCount: number;
  gamesPlayed: number;
  referredGamesPlayed: number;
  entries: AdminReferralEntry[];
  resolved: boolean;
  reviewNote: string | null;
  orderedProfileIds: string[];
};

export type AdminReferralCatalog = {
  season: { id: string; label: string; ended: boolean; startsOn: string; endsOn: string };
  qualifiedTotal: number;
  tieGroups: AdminReferralTie[];
  entries: AdminReferralEntry[];
};

function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid referral details. Refresh and try again.");
  return value as Record<string, unknown>;
}

function text(value: unknown): string { return typeof value === "string" ? value : ""; }
function count(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) throw new Error("Invalid referral standings. Refresh and try again.");
  return value;
}
function rows(value: unknown): unknown[] {
  if (!Array.isArray(value)) throw new Error("Invalid referral standings. Refresh and try again.");
  return value;
}

function entry(value: unknown): AdminReferralEntry {
  const row = record(value);
  return {
    id: text(row.id), name: text(row.name), username: text(row.username),
    rank: row.rank == null ? null : count(row.rank),
    referralCount: count(row.referral_count), gamesPlayed: count(row.games_played),
    referredGamesPlayed: count(row.referred_games_played),
    needsReview: row.needs_review === true, prizeEligible: row.prize_eligible === true,
  };
}

export function serializeAdminReferrals(value: unknown): AdminReferralCatalog {
  const data = record(value); const season = record(data.season);
  return {
    season: { id: text(season.id), label: text(season.label), ended: season.ended === true,
      startsOn: text(season.starts_on), endsOn: text(season.ends_on) },
    qualifiedTotal: count(data.qualified_total),
    entries: rows(data.entries).map(entry),
    tieGroups: rows(data.tie_groups).map((value) => {
      const group = record(value);
      return {
        evidenceToken: text(group.evidence_token), rank: count(group.rank),
        referralCount: count(group.referral_count), gamesPlayed: count(group.games_played),
        referredGamesPlayed: count(group.referred_games_played),
        entries: rows(group.entries).map(entry), resolved: group.resolved === true,
        reviewNote: typeof group.review_note === "string" ? group.review_note : null,
        orderedProfileIds: rows(group.ordered_profile_ids).map(text),
      };
    }),
  };
}

export function parseReferralTieReview(value: unknown) {
  const body = record(value);
  if (Object.keys(body).some((key) => !["evidenceToken", "orderedProfileIds", "note"].includes(key))) {
    throw new Error("Unknown referral review detail. Refresh and try again.");
  }
  const evidenceToken = text(body.evidenceToken);
  if (!/^[a-zA-Z0-9_-]{16,128}$/.test(evidenceToken)) throw new Error("Refresh the referral tie before reviewing it.");
  const orderedProfileIds = body.orderedProfileIds;
  if (!Array.isArray(orderedProfileIds) || orderedProfileIds.length < 2 || orderedProfileIds.length > 10000 ||
      orderedProfileIds.some((id) => typeof id !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id))) {
    throw new Error("Choose an order containing every tied player exactly once.");
  }
  const ids = orderedProfileIds.map((id: string) => id.toLowerCase());
  if (new Set(ids).size !== ids.length) throw new Error("Choose each tied player only once.");
  const note = text(body.note).trim();
  if (note.length < 10 || note.length > 2000) throw new Error("Explain the review decision in 10–2,000 characters.");
  return { evidenceToken, orderedProfileIds: ids, note };
}

export function referralError(error: { code?: string; message?: string }) {
  if (error.code === "PGRST202" || error.code === "42883") return { status: 503, message: "The referral database update is not installed yet." };
  if (error.code === "40001" || /stale|changed|refresh/i.test(error.message ?? "")) return { status: 409, message: "These standings changed. Refresh the tie and review the latest players and counts." };
  if (error.code === "42501") return { status: 403, message: "An active admin account is required to review referrals." };
  if (error.code === "22023") return { status: 400, message: error.message ?? "Check the referral review details." };
  return { status: 500, message: "Could not load or save referrals. Try again." };
}

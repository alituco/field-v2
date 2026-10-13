import type { createSupabaseAdmin } from "./supabase-admin";

type AdminDb = ReturnType<typeof createSupabaseAdmin>;
type Row = Record<string, unknown>;

export const WAITLIST_STATUSES = [
  "WAITING",
  "CONTACTED",
  "SELECTED",
  "DECLINED",
  "ONBOARDED",
] as const;

export const WAITLIST_INTERESTS = [
  "LAUNCH_UPDATES",
  "SOLO_PLAYER",
  "CLAN_PLAYER",
  "CLAN_LEADER",
] as const;

export const WAITLIST_POSITIONS = [
  "GOALKEEPER",
  "DEFENDER",
  "MIDFIELDER",
  "ATTACKER",
] as const;

export type WaitlistStatus = typeof WAITLIST_STATUSES[number];
export type WaitlistInterest = typeof WAITLIST_INTERESTS[number];
export type WaitlistPosition = typeof WAITLIST_POSITIONS[number];

export type AdminWaitlistApplicant = {
  id: string;
  fullName: string | null;
  email: string;
  phone: string | null;
  age: number | null;
  preferredPosition: WaitlistPosition | null;
  interest: WaitlistInterest | null;
  status: WaitlistStatus;
  source: string;
  createdAt: string | null;
  updatedAt: string | null;
  launchUpdatesConsentedAt: string | null;
  launchUpdatesConsentVersion: string | null;
  signupPlacement: string | null;
};

export type AdminWaitlistFilters = {
  query?: string;
  status?: WaitlistStatus | "ALL";
  interest?: WaitlistInterest | "ALL";
  position?: WaitlistPosition | "ALL";
};

export async function loadAdminWaitlist(
  db: AdminDb,
): Promise<AdminWaitlistApplicant[]> {
  const { data, error } = await db
    .from("season_zero_waitlist")
    .select(
      "id,full_name,email,phone,age,preferred_position,interest,status,source,created_at,updated_at,launch_updates_consented_at,launch_updates_consent_version,signup_placement",
    )
    .order("created_at", { ascending: false })
    .limit(1000);

  if (error) {
    throw new Error(`Could not load interest signups: ${error.message}`);
  }

  return rows(data).map(normalizeAdminWaitlistApplicant);
}

export function normalizeAdminWaitlistApplicant(
  applicant: Row,
): AdminWaitlistApplicant {
  return {
    id: stringValue(applicant.id) ?? "",
    fullName: stringValue(applicant.full_name),
    email: stringValue(applicant.email) ?? "",
    phone: stringValue(applicant.phone),
    age: integerValue(applicant.age),
    preferredPosition: enumValue(
      applicant.preferred_position,
      WAITLIST_POSITIONS,
    ),
    interest: enumValue(applicant.interest, WAITLIST_INTERESTS),
    status: enumValue(applicant.status, WAITLIST_STATUSES) ?? "WAITING",
    source: stringValue(applicant.source) ?? "FIELD_BH",
    createdAt: stringValue(applicant.created_at),
    updatedAt: stringValue(applicant.updated_at),
    launchUpdatesConsentedAt: stringValue(applicant.launch_updates_consented_at),
    launchUpdatesConsentVersion: stringValue(applicant.launch_updates_consent_version),
    signupPlacement: stringValue(applicant.signup_placement),
  };
}

export function isLaunchUpdatesSubscriber(applicant: AdminWaitlistApplicant) {
  return Boolean(applicant.launchUpdatesConsentedAt);
}

export function filterAdminWaitlist(
  applicants: AdminWaitlistApplicant[],
  filters: AdminWaitlistFilters,
) {
  const needle = filters.query?.trim().toLowerCase() ?? "";
  const status = filters.status ?? "ALL";
  const interest = filters.interest ?? "ALL";
  const position = filters.position ?? "ALL";

  return applicants.filter((applicant) => {
    if (status !== "ALL" && applicant.status !== status) return false;
    if (interest === "LAUNCH_UPDATES") {
      if (!isLaunchUpdatesSubscriber(applicant)) return false;
    } else if (interest !== "ALL" && applicant.interest !== interest) {
      return false;
    }
    if (position !== "ALL" && applicant.preferredPosition !== position) {
      return false;
    }
    if (!needle) return true;

    return [
      applicant.fullName ?? "",
      applicant.email,
      applicant.phone ?? "",
      applicant.preferredPosition ?? "",
      applicant.interest ?? "",
      applicant.status,
      applicant.source,
      applicant.signupPlacement ?? "",
      isLaunchUpdatesSubscriber(applicant) ? "launch updates" : "",
    ].some((value) => value.toLowerCase().includes(needle));
  });
}

function rows(value: unknown): Row[] {
  if (!Array.isArray(value)) return [];
  return value.filter(
    (item): item is Row =>
      typeof item === "object" && item !== null && !Array.isArray(item),
  );
}

function stringValue(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function integerValue(value: unknown): number | null {
  const number =
    typeof value === "number"
      ? value
      : typeof value === "string" && value.trim()
        ? Number(value)
        : Number.NaN;
  return Number.isInteger(number) ? number : null;
}

function enumValue<T extends string>(
  value: unknown,
  allowed: readonly T[],
): T | null {
  const normalized = stringValue(value)?.toUpperCase() as T | undefined;
  return normalized && allowed.includes(normalized) ? normalized : null;
}

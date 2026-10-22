"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { adminGameStartTimestamp } from "@/lib/admin-game-time";
import { LoadingSkeleton } from "@/components/loading-skeleton";

import { createSupabaseBrowserClient } from "@/lib/supabase-browser";
import { isStaffBrowserSession, STAFF_SIGN_IN_REQUIRED } from "@/lib/staff-browser-session";
import type {
  AdminGameParticipant,
  AdminGameParticipants,
} from "@/lib/admin-game-participants";
import {
  filterAdminWaitlist,
  isLaunchUpdatesSubscriber,
  WAITLIST_INTERESTS,
  WAITLIST_POSITIONS,
  WAITLIST_STATUSES,
  type AdminWaitlistApplicant,
  type WaitlistInterest,
  type WaitlistPosition,
  type WaitlistStatus,
} from "@/lib/admin-waitlist";
import type {
  BroadcastControlResponse,
  RefereeAssignmentsResponse,
  RefereeFixture,
  RefereeFixturesResponse,
} from "@/lib/types";

import forfeitStyles from "./forfeit-review.module.css";
import { ReliabilitySection } from "./reliability-section";
import { GamePaymentSettingsPanel } from "./game-payment-settings";
import { refundRetryNotice } from "@/lib/payment-refunds";
import { FieldsPanel } from "./fields-panel";
import { SchedulesPanel } from "./schedules-panel";
import { CitiesPanel } from "./cities-panel";
import { SeasonsPanel } from "./seasons-panel";
import type { AdminField } from "@/lib/admin-fields";
import { DEFAULT_SOLO_FORMATION, parseSoloFormation, type SoloFormation } from "@/lib/admin-solo-games";
import { SoloFormationFields } from "./solo-formation-fields";

type AdminSection =
  | "overview"
  | "games"
  | "schedules"
  | "fields"
  | "cities"
  | "seasons"
  | "reliability"
  | "support"
  | "reports"
  | "waitlist"
  | "people"
  | "staff"
  | "audit";
type AdminGamesView = "SCHEDULED" | "FINAL";
type AdminGamesDisplay = "LIST" | "CALENDAR";
type JsonRecord = Record<string, unknown>;

type OverviewMetric = {
  key: string;
  label: string;
  value: number;
  detail: string;
  tone: "neutral" | "good" | "warning" | "danger";
};

type AttentionItem = {
  id: string;
  title: string;
  detail: string;
  severity: "LOW" | "MEDIUM" | "HIGH" | "CRITICAL";
  kind: string;
  createdAt: string | null;
  matchKind: "SOLO" | "CLAN" | null;
  gameId: string | null;
  resolution: string | null;
  dismissible: boolean;
  paymentRefundId: string | null;
};

type AuditItem = {
  id: string;
  action: string;
  actor: string;
  target: string;
  detail: string;
  createdAt: string | null;
};

type AdminReport = {
  id: string;
  status: string;
  priority: string;
  category: string;
  description: string;
  reporterName: string;
  reporterRole: string;
  subjectType: "PLAYER" | "CLAN" | "MATCH" | "REFEREE";
  subjectId: string;
  subjectName: string;
  matchLabel: string | null;
  matchKind: string | null;
  matchId: string | null;
  replayOffsetSeconds: number | null;
  assignedTo: string | null;
  resolutionNote: string | null;
  createdAt: string | null;
  updatedAt: string | null;
};

type AdminSupportTicket = {
  id: string;
  reference: string;
  status: "OPEN" | "IN_PROGRESS" | "RESOLVED" | "CLOSED" | "DUPLICATE";
  priority: "LOW" | "NORMAL" | "HIGH" | "URGENT";
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

type AdminForfeit = {
  id: string;
  status: "PENDING_REVIEW" | "CONFIRMED" | "OVERTURNED";
  fixtureId: string;
  fixtureStatus: string;
  matchDate: string | null;
  timeSlot: string | null;
  venue: string | null;
  homeClanId: string | null;
  awayClanId: string | null;
  reportedClan: { id: string; name: string; tag: string | null; emblem: string | null };
  awardedClan: { id: string; name: string; tag: string | null; emblem: string | null };
  provisionalHomeScore: number;
  provisionalAwayScore: number;
  previousHomeScore: number | null;
  previousAwayScore: number | null;
  reportId: string;
  reportStatus: string | null;
  reportCategory: string | null;
  reportPriority: string | null;
  reportDetails: string | null;
  replayOffsetSeconds: number | null;
  stoppageId: string;
  stoppageStatus: string | null;
  reasonCode: string | null;
  reason: string | null;
  elapsedSeconds: number;
  referee: { id: string; name: string; role: string };
  reviewer: { id: string; name: string } | null;
  reviewNote: string | null;
  reviewedAt: string | null;
  createdAt: string | null;
  ratingPolicy: string;
};

type ActiveModerationAction = {
  id: string;
  actionType: string;
  restrictionScope: string | null;
  reasonCode: string;
  userMessage: string;
  startsAt: string | null;
  endsAt: string | null;
  issuedBy: string;
};

type FlaggedSubject = {
  subjectType: "PLAYER" | "CLAN" | "REFEREE";
  subjectId: string;
  name: string;
  username: string | null;
  avatarUrl: string | null;
  openReports: number;
  highPriorityReports: number;
  reports30d: number;
  distinctReporters30d: number;
  lifetimeReports: number;
  actionedReports: number;
  appearances: number;
  reportsPerTenAppearances: number | null;
  activeAction: string | null;
  activeActionEndsAt: string | null;
  activeActions: ActiveModerationAction[];
  lastReportedAt: string | null;
};

type AdminStaffMember = {
  profileId: string;
  displayName: string;
  phone: string | null;
  email: string | null;
  setupRequired?: boolean;
  role: "admin" | "referee";
  isActive: boolean;
  createdAt: string | null;
  updatedAt: string | null;
};

type ModerationActionType =
  | "WARNING"
  | "PLAY_SUSPENSION"
  | "ACCOUNT_SUSPENSION"
  | "PERMANENT_BAN"
  | "CLAN_SCHEDULING_FREEZE"
  | "CLAN_DISQUALIFICATION";

type GameDialog =
  | { kind: "cancel"; fixture: RefereeFixture }
  | { kind: "score"; fixture: RefereeFixture }
  | null;

type SoloGameDialog =
  | { kind: "create"; fieldId?: string }
  | { kind: "remove"; fixture: RefereeFixture }
  | null;

type SoloGameDraft = SoloFormation & {
  minimumPlayers: number;
  matchDate: string;
  kickoffTime: string;
  durationMinutes: number;
  priceUsd: string;
  ageLabel: string;
  highestDivision: number;
  lowestDivision: number;
};

type ReportDialog =
  | { report: AdminReport; action: "RESOLVE" | "DISMISS" }
  | null;

type SupportDialog =
  | {
      ticket: AdminSupportTicket;
      action: "RESOLVE" | "CLOSE" | "DUPLICATE";
    }
  | null;

type RevokeDialog = {
  subject: FlaggedSubject;
  action: ActiveModerationAction;
} | null;

type ForfeitReviewDialog = {
  decision: AdminForfeit;
  action: "CONFIRM" | "OVERTURN";
} | null;

const supabase = createSupabaseBrowserClient();

export default function AdminPage() {
  const [accessToken, setAccessToken] = useState<string | null>(null);
  const [sessionChecked, setSessionChecked] = useState(false);
  const [section, setSection] = useState<AdminSection>("overview");
  const [me, setMe] = useState<RefereeFixturesResponse["me"] | null>(null);
  const [overviewRaw, setOverviewRaw] = useState<unknown>(null);
  const [games, setGames] = useState<RefereeFixture[]>([]);
  const [assignments, setAssignments] = useState<RefereeAssignmentsResponse>({
    referees: [],
    fixtures: [],
  });
  const [reports, setReports] = useState<AdminReport[]>([]);
  const [supportTickets, setSupportTickets] = useState<AdminSupportTicket[]>([]);
  const [waitlistApplicants, setWaitlistApplicants] = useState<
    AdminWaitlistApplicant[]
  >([]);
  const [activeSupportCount, setActiveSupportCount] = useState(0);
  const [forfeits, setForfeits] = useState<AdminForfeit[]>([]);
  const [subjects, setSubjects] = useState<FlaggedSubject[]>([]);
  const [staff, setStaff] = useState<AdminStaffMember[]>([]);
  const [reportStatus, setReportStatus] = useState("OPEN");
  const [supportStatus, setSupportStatus] = useState("ACTIVE");
  const [waitlistLoading, setWaitlistLoading] = useState(false);
  const [waitlistLoaded, setWaitlistLoaded] = useState(false);
  const [waitlistAttempted, setWaitlistAttempted] = useState(false);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [reliabilityRefreshKey, setReliabilityRefreshKey] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState<string | null>(null);
  const [gameDialog, setGameDialog] = useState<GameDialog>(null);
  const [soloGameDialog, setSoloGameDialog] = useState<SoloGameDialog>(null);
  const [fields, setFields] = useState<AdminField[]>([]);
  const [soloDraft, setSoloDraft] = useState<SoloGameDraft | null>(null);
  const [addingField, setAddingField] = useState(false);
  const [returnToSolo, setReturnToSolo] = useState(false);
  const [returnToSchedules, setReturnToSchedules] = useState(false);
  const [schedulesRefreshKey, setSchedulesRefreshKey] = useState(0);
  const [scheduleAddedFieldId, setScheduleAddedFieldId] = useState<string | null>(null);
  const [fieldsRefreshKey, setFieldsRefreshKey] = useState(0);
  const [citiesRefreshKey, setCitiesRefreshKey] = useState(0);
  const [seasonsRefreshKey, setSeasonsRefreshKey] = useState(0);
  const [reportDialog, setReportDialog] = useState<ReportDialog>(null);
  const [supportDialog, setSupportDialog] = useState<SupportDialog>(null);
  const [moderationSubject, setModerationSubject] =
    useState<FlaggedSubject | null>(null);
  const [revokeDialog, setRevokeDialog] = useState<RevokeDialog>(null);
  const [forfeitDialog, setForfeitDialog] = useState<ForfeitReviewDialog>(null);
  const loadedSession = useRef(false);

  const authHeaders = useCallback(() => {
    if (!accessToken) throw new Error("Sign in required.");
    return { authorization: `Bearer ${accessToken}` };
  }, [accessToken]);

  const loadOverview = useCallback(async () => {
    if (!accessToken) return;
    const payload = await fetchJson<unknown>("/api/referee/admin/overview", {
      headers: authHeaders(),
      cache: "no-store",
    });
    setOverviewRaw(payload);
  }, [accessToken, authHeaders]);

  const loadGames = useCallback(async () => {
    if (!accessToken) return;
    const [gamePayload, assignmentPayload] = await Promise.all([
      fetchJson<RefereeFixturesResponse>("/api/referee/fixtures?scope=admin", {
        headers: authHeaders(),
        cache: "no-store",
      }),
      fetchJson<RefereeAssignmentsResponse>("/api/referee/assignments", {
        headers: authHeaders(),
        cache: "no-store",
      }),
    ]);
    setMe(gamePayload.me);
    setGames(gamePayload.fixtures);
    setAssignments(assignmentPayload);
  }, [accessToken, authHeaders]);

  const loadReports = useCallback(async () => {
    if (!accessToken) return;
    const query = reportStatus === "ALL" ? "" : `?status=${encodeURIComponent(reportStatus)}`;
    const payload = await fetchJson<unknown>(
      `/api/referee/admin/reports${query}`,
      { headers: authHeaders(), cache: "no-store" },
    );
    setReports(normalizeReports(payload));
  }, [accessToken, authHeaders, reportStatus]);

  const loadSupportTickets = useCallback(async () => {
    if (!accessToken) return;
    const query = `?status=${encodeURIComponent(supportStatus)}`;
    const payload = await fetchJson<{
      tickets?: AdminSupportTicket[];
      activeCount?: number;
    }>(
      `/api/referee/admin/support${query}`,
      { headers: authHeaders(), cache: "no-store" },
    );
    setSupportTickets(
      Array.isArray(payload.tickets) ? payload.tickets : [],
    );
    setActiveSupportCount(
      typeof payload.activeCount === "number" ? payload.activeCount : 0,
    );
  }, [accessToken, authHeaders, supportStatus]);

  const loadWaitlist = useCallback(
    async (quiet = false) => {
      if (!accessToken) return;
      setWaitlistAttempted(true);
      if (quiet) setRefreshing(true);
      else setWaitlistLoading(true);
      setError(null);
      try {
        const payload = await fetchJson<{
          applicants?: AdminWaitlistApplicant[];
        }>("/api/referee/admin/waitlist", {
          headers: authHeaders(),
          cache: "no-store",
        });
        setWaitlistApplicants(
          Array.isArray(payload.applicants) ? payload.applicants : [],
        );
        setWaitlistLoaded(true);
      } catch (loadError) {
        setError(
          errorMessage(loadError, "Could not load interest signups."),
        );
      } finally {
        setWaitlistLoading(false);
        if (quiet) setRefreshing(false);
      }
    },
    [accessToken, authHeaders],
  );

  const loadForfeits = useCallback(async () => {
    if (!accessToken) return;
    const payload = await fetchJson<{ forfeits?: AdminForfeit[] }>(
      "/api/referee/admin/forfeits",
      { headers: authHeaders(), cache: "no-store" },
    );
    setForfeits(Array.isArray(payload.forfeits) ? payload.forfeits : []);
  }, [accessToken, authHeaders]);

  const loadSubjects = useCallback(async () => {
    if (!accessToken) return;
    const payload = await fetchJson<unknown>("/api/referee/admin/subjects", {
      headers: authHeaders(),
      cache: "no-store",
    });
    setSubjects(normalizeSubjects(payload));
  }, [accessToken, authHeaders]);

  const loadStaff = useCallback(async () => {
    if (!accessToken) return;
    const payload = await fetchJson<{ staff?: AdminStaffMember[] }>(
      "/api/referee/referees",
      { headers: authHeaders(), cache: "no-store" },
    );
    setStaff(Array.isArray(payload.staff) ? payload.staff : []);
  }, [accessToken, authHeaders]);

  const loadAll = useCallback(
    async (quiet = false) => {
      if (!accessToken) return;
      if (quiet) setRefreshing(true);
      else setLoading(true);
      setError(null);
      try {
        const results = await Promise.allSettled([
          loadOverview(),
          loadGames(),
          loadSupportTickets(),
          loadReports(),
          loadSubjects(),
          loadForfeits(),
          loadStaff(),
        ]);
        const failure = results.find(
          (result): result is PromiseRejectedResult => result.status === "rejected",
        );
        if (failure) throw failure.reason;
      } catch (loadError) {
        setError(errorMessage(loadError, "Could not load the admin panel."));
      } finally {
        setLoading(false);
        setRefreshing(false);
      }
    },
    [
      accessToken,
      loadForfeits,
      loadGames,
      loadOverview,
      loadReports,
      loadSubjects,
      loadSupportTickets,
      loadStaff,
    ],
  );

  useEffect(() => {
    if (loadedSession.current) return;
    loadedSession.current = true;
    void supabase.auth.getSession().then(({ data }) => {
      const valid = isStaffBrowserSession(data.session);
      setAccessToken(isStaffBrowserSession(data.session) ? data.session.access_token : null);
      if (data.session && !valid) {
        setError(STAFF_SIGN_IN_REQUIRED);
        void supabase.auth.signOut({ scope: "local" });
      }
      setSessionChecked(true);
    });
    const { data: listener } = supabase.auth.onAuthStateChange((_event, session) => {
      const valid = isStaffBrowserSession(session);
      setAccessToken(valid ? session.access_token : null);
      if (session && !valid) {
        setError(STAFF_SIGN_IN_REQUIRED);
        queueMicrotask(() => void supabase.auth.signOut({ scope: "local" }));
      }
      setSessionChecked(true);
    });
    return () => listener.subscription.unsubscribe();
  }, []);

  useEffect(() => {
    const requested = new URLSearchParams(window.location.search).get("section");
    if (window.location.pathname.startsWith("/admin/fields")) {
      setSection("fields");
      setAddingField(window.location.pathname.endsWith("/new"));
      setReturnToSolo(new URLSearchParams(window.location.search).get("returnTo") === "solo");
      setReturnToSchedules(new URLSearchParams(window.location.search).get("returnTo") === "schedules");
      return;
    }
    if (window.location.pathname.startsWith("/admin/schedules")) {
      setSection("schedules");
      return;
    }
    if (window.location.pathname.startsWith("/admin/cities")) {
      setSection("cities");
      return;
    }
    if (window.location.pathname.startsWith("/admin/seasons")) {
      setSection("seasons");
      return;
    }
    if (adminNavItems.some((item) => item.id === requested)) {
      setSection(requested as AdminSection);
    }
  }, []);

  useEffect(() => {
    if (accessToken) void loadAll();
  }, [accessToken, loadAll]);

  useEffect(() => {
    if (!accessToken || loading) return;
    void loadReports().catch((loadError) => {
      setError(errorMessage(loadError, "Could not refresh reports."));
    });
  }, [accessToken, loadReports, loading, reportStatus]);

  useEffect(() => {
    if (!accessToken || loading) return;
    void loadSupportTickets().catch((loadError) => {
      setError(errorMessage(loadError, "Could not refresh support tickets."));
    });
  }, [accessToken, loadSupportTickets, loading, supportStatus]);

  useEffect(() => {
    setWaitlistApplicants([]);
    setWaitlistLoaded(false);
    setWaitlistAttempted(false);
  }, [accessToken]);

  useEffect(() => {
    if (
      section !== "waitlist" ||
      !accessToken ||
      waitlistAttempted ||
      waitlistLoaded ||
      waitlistLoading
    ) {
      return;
    }
    void loadWaitlist();
  }, [
    accessToken,
    loadWaitlist,
    section,
    waitlistAttempted,
    waitlistLoaded,
    waitlistLoading,
  ]);

  async function signOut() {
    await supabase.auth.signOut();
    window.location.href = "/";
  }

  async function runGameAction(
    fixture: RefereeFixture,
    body: JsonRecord,
    successMessage: string,
  ) {
    setSubmitting(String(body.action ?? "game-action"));
    setError(null);
    try {
      const path = fixture.matchKind === "SOLO"
        ? `/api/referee/open-queue-games/${fixture.id}/action`
        : `/api/referee/fixtures/${fixture.id}/action`;
      await fetchJson(path, {
        method: "POST",
        headers: { "Content-Type": "application/json", ...authHeaders() },
        body: JSON.stringify(body),
      });
      setGameDialog(null);
      setNotice(successMessage);
      await Promise.all([loadGames(), loadOverview()]);
    } catch (actionError) {
      setError(errorMessage(actionError, "Game action failed."));
    } finally {
      setSubmitting(null);
    }
  }

  async function createSoloGame(input: {
    minimumPlayers: number;
    fieldId: string;
    matchDate: string;
    kickoffTime: string;
    durationMinutes: number;
    priceUsd: string;
    ageLabel: string;
    highestDivision: number;
    lowestDivision: number;
    goalkeepersPerSide: number;
    defendersPerSide: number;
    attackersPerSide: number;
  }) {
    setSubmitting("create-solo-game");
    setError(null);
    try {
      await fetchJson("/api/referee/admin/solo-games", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...authHeaders() },
        body: JSON.stringify(input),
      });
      setSoloGameDialog(null);
      setNotice("Solo game created and opened for bookings.");
      await Promise.all([loadGames(), loadOverview()]);
    } catch (actionError) {
      setError(errorMessage(actionError, "Could not create the solo game."));
    } finally {
      setSubmitting(null);
    }
  }

  function navigateSection(next: AdminSection) {
    setSection(next);
    setAddingField(false);
    setReturnToSolo(false);
    setReturnToSchedules(false);
    window.history.replaceState(null, "", ["fields", "schedules", "cities", "seasons"].includes(next) ? `/admin/${next}` : `/admin?section=${next}`);
  }

  function addFieldForGame(draft?: SoloGameDraft) {
    if (draft) setSoloDraft(draft);
    setSoloGameDialog(null);
    setSection("fields");
    setAddingField(true);
    setReturnToSolo(true);
    setReturnToSchedules(false);
    window.history.replaceState(null, "", "/admin/fields/new?returnTo=solo");
  }

  async function startSoloGame() {
    setSoloDraft(null);
    setSubmitting("load-fields");
    setError(null);
    try {
      const payload = await fetchJson<{ fields: AdminField[] }>("/api/referee/admin/fields", {
        headers: authHeaders(), cache: "no-store",
      });
      const available = payload.fields.filter((field) => field.isActive && field.marketActive);
      setFields(available);
      if (!available.length) addFieldForGame();
      else setSoloGameDialog({ kind: "create" });
    } catch (loadError) {
      setError(errorMessage(loadError, "Could not load fields. Try again before creating a game."));
    } finally {
      setSubmitting(null);
    }
  }

  async function removeSoloGame(fixture: RefereeFixture, reason: string) {
    setSubmitting("remove-solo-game");
    setError(null);
    try {
      await fetchJson(`/api/referee/admin/solo-games/${fixture.id}`, {
        method: "DELETE",
        headers: { "Content-Type": "application/json", ...authHeaders() },
        body: JSON.stringify({ reason }),
      });
      setSoloGameDialog(null);
      setNotice("Empty solo game removed. The admin action remains audited.");
      await Promise.all([loadGames(), loadOverview()]);
    } catch (actionError) {
      setError(errorMessage(actionError, "Could not remove the solo game."));
    } finally {
      setSubmitting(null);
    }
  }

  async function assignReferee(
    fixture: RefereeFixture,
    refereeId: string,
  ) {
    setSubmitting(`assign-${fixture.matchKind}-${fixture.id}`);
    setError(null);
    try {
      await fetchJson("/api/referee/assignments", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...authHeaders() },
        body: JSON.stringify({
          fixtureId: fixture.id,
          matchKind: fixture.matchKind,
          refereeId: refereeId || null,
        }),
      });
      setNotice(refereeId ? "Referee assigned." : "Game is now unassigned.");
      await loadGames();
      return true;
    } catch (assignError) {
      setError(errorMessage(assignError, "Could not update the referee assignment."));
      return false;
    } finally {
      setSubmitting(null);
    }
  }

  async function createReferee(input: { displayName: string; email: string }) {
    setSubmitting("create-referee");
    setError(null);
    try {
      const result = await fetchJson<{ warning?: string | null }>("/api/referee/referees", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...authHeaders() },
        body: JSON.stringify({
          displayName: input.displayName,
          email: input.email,
          role: "referee",
          sendOtp: true,
        }),
      });
      setNotice(result.warning ?? `A separate staff account is ready for ${input.displayName}. A login code was requested by email.`);
      await Promise.all([loadGames(), loadStaff()]);
      return true;
    } catch (createError) {
      setError(errorMessage(createError, "Could not create the referee account."));
      return false;
    } finally {
      setSubmitting(null);
    }
  }

  async function createStaff(input: {
    displayName: string;
    email: string;
    role: "admin" | "referee";
    existingStaffProfileId?: string;
  }) {
    setSubmitting("create-staff");
    setError(null);
    try {
      const result = await fetchJson<{ warning?: string | null }>("/api/referee/referees", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...authHeaders() },
        body: JSON.stringify({ ...input, sendOtp: true }),
      });
      setNotice(result.warning ?? `${input.role === "admin" ? "Admin" : "Referee"} staff email is ready and a login code was requested.`);
      await Promise.all([loadStaff(), loadGames()]);
      return true;
    } catch (createError) {
      setError(errorMessage(createError, "Could not create the staff account."));
      return false;
    } finally {
      setSubmitting(null);
    }
  }

  async function runReportAction(
    report: AdminReport,
    action: "TRIAGE" | "INVESTIGATE" | "RESOLVE" | "DISMISS",
    resolutionNote?: string,
  ) {
    setSubmitting(`report-${report.id}-${action}`);
    setError(null);
    try {
      await fetchJson(`/api/referee/admin/reports/${report.id}/action`, {
        method: "POST",
        headers: { "Content-Type": "application/json", ...authHeaders() },
        body: JSON.stringify({ action, resolutionNote }),
      });
      setReportDialog(null);
      setNotice(
        action === "DISMISS"
          ? "Report dismissed with an audit record."
          : action === "RESOLVE"
            ? "Report resolved."
            : action === "INVESTIGATE"
              ? "Investigation started."
              : "Report triaged.",
      );
      await Promise.all([loadReports(), loadOverview(), loadSubjects()]);
    } catch (actionError) {
      setError(errorMessage(actionError, "Could not update the report."));
    } finally {
      setSubmitting(null);
    }
  }

  async function runSupportAction(
    ticket: AdminSupportTicket,
    action: "START" | "RESOLVE" | "CLOSE" | "REOPEN" | "DUPLICATE",
    input: {
      resolutionNote?: string;
      adminNote?: string;
    } = {},
  ) {
    setSubmitting(`support-${ticket.id}-${action}`);
    setError(null);
    try {
      await fetchJson(`/api/referee/admin/support/${ticket.id}/action`, {
        method: "POST",
        headers: { "Content-Type": "application/json", ...authHeaders() },
        body: JSON.stringify({
          action,
          expectedRevision: ticket.revision,
          resolutionNote: input.resolutionNote,
          adminNote: input.adminNote,
        }),
      });
      setSupportDialog(null);
      setNotice(
        action === "START"
          ? `${ticket.reference} is now being handled.`
          : action === "REOPEN"
            ? `${ticket.reference} reopened.`
            : action === "DUPLICATE"
              ? `${ticket.reference} closed as a duplicate.`
              : action === "CLOSE"
                ? `${ticket.reference} closed.`
                : `${ticket.reference} resolved and the player was notified.`,
      );
      await loadSupportTickets();
    } catch (actionError) {
      setError(
        errorMessage(actionError, "Could not update the support ticket."),
      );
    } finally {
      setSubmitting(null);
    }
  }

  async function issueModerationAction(input: {
    subject: FlaggedSubject;
    actionType: ModerationActionType;
    reasonCode: string;
    note: string;
    endsAt: string | null;
    reportId: string | null;
  }) {
    setSubmitting("moderation-action");
    setError(null);
    try {
      await fetchJson("/api/referee/admin/moderation-actions", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...authHeaders() },
        body: JSON.stringify({
          subjectType: input.subject.subjectType,
          subjectId: input.subject.subjectId,
          actionType: input.actionType,
          reasonCode: input.reasonCode,
          note: input.note,
          endsAt: input.endsAt,
          reportId: input.reportId,
        }),
      });
      setModerationSubject(null);
      setNotice(`${moderationActionLabel(input.actionType)} issued to ${input.subject.name}.`);
      await Promise.all([loadSubjects(), loadOverview(), loadReports()]);
    } catch (actionError) {
      setError(errorMessage(actionError, "Could not issue moderation action."));
    } finally {
      setSubmitting(null);
    }
  }

  async function revokeModerationAction(
    subject: FlaggedSubject,
    action: ActiveModerationAction,
    reason: string,
  ) {
    setSubmitting(`revoke-${action.id}`);
    setError(null);
    try {
      await fetchJson(`/api/referee/admin/moderation-actions/${action.id}/revoke`, {
        method: "POST",
        headers: { "Content-Type": "application/json", ...authHeaders() },
        body: JSON.stringify({ reason }),
      });
      setRevokeDialog(null);
      setNotice(`${activeActionLabel(action)} revoked for ${subject.name}.`);
      const refreshResults = await Promise.allSettled([
        loadSubjects(),
        loadOverview(),
      ]);
      if (refreshResults.some((result) => result.status === "rejected")) {
        setError(
          "The restriction was revoked, but the latest admin data could not be refreshed. Use Refresh to reload it.",
        );
      }
    } catch (actionError) {
      setError(errorMessage(actionError, "Could not revoke this restriction."));
    } finally {
      setSubmitting(null);
    }
  }

  async function reviewForfeit(
    decision: AdminForfeit,
    action: "CONFIRM" | "OVERTURN",
    note: string,
  ) {
    setSubmitting(`forfeit-${decision.id}-${action}`);
    setError(null);
    try {
      await fetchJson("/api/referee/admin/forfeits", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...authHeaders() },
        body: JSON.stringify({ decisionId: decision.id, action, note }),
      });
      setForfeitDialog(null);
      setNotice(
        action === "CONFIRM"
          ? `The provisional 3–0 result for ${decision.awardedClan.name} is now official.`
          : "The provisional forfeit was overturned and the prior score restored.",
      );
      const refreshResults = await Promise.allSettled([
        loadForfeits(),
        loadOverview(),
        loadGames(),
        loadReports(),
      ]);
      if (refreshResults.some((result) => result.status === "rejected")) {
        setError(
          "The forfeit decision was saved, but some admin data could not be refreshed. Use Refresh to reload it.",
        );
      }
    } catch (actionError) {
      setError(errorMessage(actionError, "Could not review the provisional forfeit."));
    } finally {
      setSubmitting(null);
    }
  }

  const overview = useMemo(
    () => normalizeOverview(overviewRaw, games, reports, subjects),
    [games, overviewRaw, reports, subjects],
  );

  if (!sessionChecked) {
    return <AdminLoadingScreen label="Checking your admin session" />;
  }

  if (!accessToken) {
    return (
      <main className="admin-entry-shell">
        <section className="admin-entry-card">
          <div className="admin-entry-mark">F</div>
          <span className="admin-eyebrow">Field operations</span>
          <h1>Sign in with your staff email</h1>
          <p>{error ?? "Use your dedicated staff email and six-digit code. Ask an administrator to set up your staff email if you previously used phone sign-in."}</p>
          <a className="admin-primary-link" href="/">
            Go to staff sign in
          </a>
        </section>
      </main>
    );
  }

  return (
    <main className="admin-app-shell">
      <AdminSidebar
        section={section}
        me={me}
        counts={{
          reports: overview.openReports,
          support: activeSupportCount,
          attention:
            overview.attention.length +
            forfeits.filter((decision) => decision.status === "PENDING_REVIEW").length,
        }}
        onSection={navigateSection}
        onSignOut={() => void signOut()}
      />

      <div className="admin-main">
        <header className="admin-topbar">
          <div>
            <div className="admin-mobile-brand">FIELDRUSH OPERATIONS</div>
            <h1>{sectionTitle(section)}</h1>
            <p>{sectionSubtitle(section)}</p>
          </div>
          <div className="admin-topbar-actions">
            <span className="admin-live-system"><i /> Operations workspace</span>
            <button
              className="admin-icon-button"
              disabled={refreshing}
              onClick={() => {
                if (section === "fields") {
                  setFieldsRefreshKey((value) => value + 1);
                } else if (section === "schedules") {
                  setSchedulesRefreshKey((value) => value + 1);
                } else if (section === "cities") {
                  setCitiesRefreshKey((value) => value + 1);
                } else if (section === "seasons") {
                  setSeasonsRefreshKey((value) => value + 1);
                } else if (section === "reliability") {
                  setReliabilityRefreshKey((value) => value + 1);
                } else if (section === "waitlist") {
                  void loadWaitlist(true);
                } else {
                  void loadAll(true);
                }
              }}
              title="Refresh admin data"
              type="button"
            >
              <AdminIcon name="refresh" />
            </button>
          </div>
        </header>

        <div className="admin-mobile-nav" role="navigation">
          {adminNavItems.map((item) => (
            <button
              className={section === item.id ? "active" : ""}
              key={item.id}
              onClick={() => navigateSection(item.id)}
              type="button"
            >
              <AdminIcon name={item.icon} />
              <span>{item.shortLabel}</span>
            </button>
          ))}
        </div>

        {error ? (
          <div className="admin-banner danger">
            <AdminIcon name="alert" />
            <span>{error}</span>
            <button onClick={() => setError(null)} type="button">Dismiss</button>
          </div>
        ) : null}
        {notice ? (
          <div className="admin-banner success">
            <AdminIcon name="check" />
            <span>{notice}</span>
            <button onClick={() => setNotice(null)} type="button">Dismiss</button>
          </div>
        ) : null}

        <div className="admin-page-content">
          {loading ? (
            <AdminPageSkeleton />
          ) : section === "overview" ? (
            <OverviewSection
              accessToken={accessToken}
              onRefundRetried={async (message) => {
                setNotice(message);
                await loadAll(true);
              }}
              overview={overview}
              games={games}
              reports={reports}
              forfeits={forfeits}
              onNavigate={navigateSection}
            />
          ) : section === "games" ? (
            <GamesSection
              accessToken={accessToken}
              assignments={assignments}
              games={games}
              submitting={submitting}
              onAssignReferee={assignReferee}
              onCancel={(fixture) => setGameDialog({ kind: "cancel", fixture })}
              onCreateSoloGame={() => void startSoloGame()}
              onCreateReferee={createReferee}
              onOverrideScore={(fixture) => setGameDialog({ kind: "score", fixture })}
              onRemoveSoloGame={(fixture) =>
                setSoloGameDialog({ kind: "remove", fixture })
              }
            />
          ) : section === "cities" ? (
            <CitiesPanel accessToken={accessToken} refreshKey={citiesRefreshKey} />
          ) : section === "seasons" ? (
            <SeasonsPanel accessToken={accessToken} refreshKey={seasonsRefreshKey} />
          ) : section === "schedules" ? (
            <SchedulesPanel accessToken={accessToken} refreshKey={schedulesRefreshKey} newlyAddedFieldId={scheduleAddedFieldId ?? undefined} onAddField={() => {
              setSection("fields"); setAddingField(true); setReturnToSolo(false); setReturnToSchedules(true);
              window.history.replaceState(null, "", "/admin/fields/new?returnTo=schedules");
            }} />
          ) : section === "fields" ? (
            <FieldsPanel
              accessToken={accessToken}
              startAdding={addingField}
              returnToSolo={returnToSolo || returnToSchedules}
              returnToSchedules={returnToSchedules}
              refreshKey={fieldsRefreshKey}
              onNavigate={(adding) => {
                setAddingField(adding);
                window.history.replaceState(null, "", `/admin/fields${adding ? "/new" : ""}${returnToSolo ? "?returnTo=solo" : returnToSchedules ? "?returnTo=schedules" : ""}`);
              }}
              onReturnToGame={(field) => {
                if (returnToSchedules) { setScheduleAddedFieldId(field?.id ?? null); navigateSection("schedules"); return; }
                navigateSection("games");
                if (field) {
                  setFields((current) => [...current.filter((item) => item.id !== field.id), field]);
                  setSoloGameDialog({ kind: "create", fieldId: field.id });
                }
              }}
            />
          ) : section === "reports" ? (
            <ReportsSection
              forfeits={forfeits}
              reports={reports}
              status={reportStatus}
              submitting={submitting}
              onStatus={setReportStatus}
              onAction={(report, action) => {
                if (action === "RESOLVE" || action === "DISMISS") {
                  setReportDialog({ report, action });
                } else {
                  void runReportAction(report, action);
                }
              }}
              onModerate={(report) => {
                if (report.subjectType === "MATCH") return;
                const subject = subjects.find(
                  (candidate) =>
                    candidate.subjectId === report.subjectId &&
                    candidate.subjectType === report.subjectType,
                );
                if (subject) setModerationSubject(subject);
                else {
                  setModerationSubject(subjectFromReport(report));
                }
              }}
              onReviewForfeit={(decision, action) =>
                setForfeitDialog({ decision, action })
              }
            />
          ) : section === "support" ? (
            <SupportSection
              status={supportStatus}
              submitting={submitting}
              tickets={supportTickets}
              onStatus={setSupportStatus}
              onAction={(ticket, action) => {
                if (
                  action === "RESOLVE" ||
                  action === "CLOSE" ||
                  action === "DUPLICATE"
                ) {
                  setSupportDialog({ ticket, action });
                } else {
                  void runSupportAction(ticket, action);
                }
              }}
            />
          ) : section === "waitlist" ? (
            waitlistLoading && !waitlistLoaded ? (
              <AdminPageSkeleton />
            ) : (
              <WaitlistSection applicants={waitlistApplicants} />
            )
          ) : section === "people" ? (
            <PeopleSection
              subjects={subjects}
              onModerate={setModerationSubject}
              onRevoke={(subject, action) => setRevokeDialog({ subject, action })}
            />
          ) : section === "staff" ? (
            <StaffSection
              staff={staff}
              submitting={submitting}
              onCreate={createStaff}
            />
          ) : section === "reliability" ? (
            <ReliabilitySection
              accessToken={accessToken}
              refreshKey={reliabilityRefreshKey}
              onError={setError}
              onNotice={setNotice}
            />
          ) : (
            <AuditSection audit={overview.audit} />
          )}
        </div>
      </div>

      {gameDialog ? (
        <GameActionDialog
          dialog={gameDialog}
          submitting={submitting !== null}
          onClose={() => setGameDialog(null)}
          onSubmit={(body, successMessage) =>
            void runGameAction(gameDialog.fixture, body, successMessage)
          }
        />
      ) : null}
      {soloGameDialog ? (
        <SoloGameManagementDialog
          dialog={soloGameDialog}
          fields={fields}
          draft={soloDraft}
          error={error}
          onAddField={addFieldForGame}
          submitting={submitting !== null}
          onClose={() => setSoloGameDialog(null)}
          onCreate={(input) => void createSoloGame(input)}
          onRemove={(fixture, reason) => void removeSoloGame(fixture, reason)}
        />
      ) : null}
      {reportDialog ? (
        <ReportResolutionDialog
          dialog={reportDialog}
          submitting={submitting !== null}
          onClose={() => setReportDialog(null)}
          onSubmit={(note) =>
            void runReportAction(
              reportDialog.report,
              reportDialog.action,
              note,
            )
          }
        />
      ) : null}
      {supportDialog ? (
        <SupportActionDialog
          dialog={supportDialog}
          submitting={submitting !== null}
          onClose={() => setSupportDialog(null)}
          onSubmit={(input) =>
            void runSupportAction(
              supportDialog.ticket,
              supportDialog.action,
              input,
            )
          }
        />
      ) : null}
      {moderationSubject ? (
        <ModerationDialog
          reports={reports}
          subject={moderationSubject}
          submitting={submitting !== null}
          onClose={() => setModerationSubject(null)}
          onRevoke={(action) => {
            setRevokeDialog({ subject: moderationSubject, action });
            setModerationSubject(null);
          }}
          onSubmit={(input) => void issueModerationAction(input)}
        />
      ) : null}
      {revokeDialog ? (
        <RevokeRestrictionDialog
          dialog={revokeDialog}
          submitting={submitting !== null}
          onClose={() => setRevokeDialog(null)}
          onSubmit={(reason) =>
            void revokeModerationAction(
              revokeDialog.subject,
              revokeDialog.action,
              reason,
            )
          }
        />
      ) : null}
      {forfeitDialog ? (
        <ForfeitReviewConfirmationDialog
          dialog={forfeitDialog}
          submitting={submitting !== null}
          onClose={() => setForfeitDialog(null)}
          onSubmit={(note) =>
            void reviewForfeit(
              forfeitDialog.decision,
              forfeitDialog.action,
              note,
            )
          }
        />
      ) : null}
    </main>
  );
}

const adminNavItems: Array<{
  id: AdminSection;
  label: string;
  shortLabel: string;
  icon: AdminIconName;
}> = [
  { id: "overview", label: "Overview", shortLabel: "Home", icon: "overview" },
  { id: "games", label: "Games", shortLabel: "Games", icon: "games" },
  { id: "schedules", label: "Schedules", shortLabel: "Schedules", icon: "games" },
  { id: "fields", label: "Fields", shortLabel: "Fields", icon: "location" },
  { id: "cities", label: "Cities", shortLabel: "Cities", icon: "location" },
  { id: "seasons", label: "Seasons & rewards", shortLabel: "Seasons", icon: "policy" },
  { id: "reliability", label: "Reliability policy", shortLabel: "Policy", icon: "policy" },
  { id: "support", label: "Support", shortLabel: "Support", icon: "support" },
  { id: "reports", label: "Reports", shortLabel: "Reports", icon: "reports" },
  { id: "waitlist", label: "Interest", shortLabel: "Interest", icon: "waitlist" },
  { id: "people", label: "Players & clans", shortLabel: "People", icon: "people" },
  { id: "staff", label: "Admins & referees", shortLabel: "Staff", icon: "referee" },
  { id: "audit", label: "Audit log", shortLabel: "Audit", icon: "audit" },
];

function AdminSidebar({
  section,
  me,
  counts,
  onSection,
  onSignOut,
}: {
  section: AdminSection;
  me: RefereeFixturesResponse["me"] | null;
  counts: { reports: number; support: number; attention: number };
  onSection: (section: AdminSection) => void;
  onSignOut: () => void;
}) {
  return (
    <aside className="admin-sidebar">
      <a className="admin-sidebar-brand" href="/admin">
        <span>F</span>
        <div>
          <strong>Fieldrush</strong>
          <small>OPERATIONS</small>
        </div>
      </a>
      <div className="admin-sidebar-label">Workspace</div>
      <nav className="admin-sidebar-nav">
        {adminNavItems.map((item) => {
          const badge = item.id === "reports"
            ? counts.reports
            : item.id === "support"
              ? counts.support
              : item.id === "overview"
                ? counts.attention
                : 0;
          return (
            <button
              className={section === item.id ? "active" : ""}
              key={item.id}
              onClick={() => onSection(item.id)}
              type="button"
            >
              <AdminIcon name={item.icon} />
              <span>{item.label}</span>
              {badge > 0 ? <em>{badge > 99 ? "99+" : badge}</em> : null}
            </button>
          );
        })}
      </nav>
      <div className="admin-sidebar-spacer" />
      <a className="admin-referee-link" href="/">
        <AdminIcon name="referee" />
        Referee console
        <AdminIcon name="arrow" />
      </a>
      <div className="admin-account-card">
        <div className="admin-account-avatar">{initials(me?.displayName ?? "Admin")}</div>
        <div>
          <strong>{me?.displayName ?? "Admin"}</strong>
          <small>{me?.role === "admin" ? "Administrator" : "Checking access"}</small>
        </div>
        <button onClick={onSignOut} title="Sign out" type="button">
          <AdminIcon name="logout" />
        </button>
      </div>
    </aside>
  );
}

type NormalizedOverview = {
  metrics: OverviewMetric[];
  attention: AttentionItem[];
  audit: AuditItem[];
  openReports: number;
};

function OverviewSection({
  accessToken,
  onRefundRetried,
  overview,
  games,
  reports,
  forfeits,
  onNavigate,
}: {
  accessToken: string;
  onRefundRetried: (message: string) => Promise<void>;
  overview: NormalizedOverview;
  games: RefereeFixture[];
  reports: AdminReport[];
  forfeits: AdminForfeit[];
  onNavigate: (section: AdminSection) => void;
}) {
  const router = useRouter();
  const [retryPaymentRefund, setRetryPaymentRefund] = useState<AttentionItem | null>(null);
  const [showAllAttention, setShowAllAttention] = useState(false);
  const now = Date.now();
  const upcoming = games
    .filter((game) =>
      isScheduledAdminGame(game) &&
      (game.status === "LIVE" || adminGameStartTimestamp(game) >= now)
    )
    .sort(sortScheduledAdminGames)
    .slice(0, 2);
  const completedGames = games.filter((game) =>
    isFinalAdminGame(game) && adminGameStartTimestamp(game) <= now
  );
  const lastMatchdayDate = completedGames
    .map((game) => game.matchDate)
    .sort((left, right) => right.localeCompare(left))[0] ?? null;
  const lastMatchday = lastMatchdayDate
    ? completedGames
        .filter((game) => game.matchDate === lastMatchdayDate)
        .sort(sortFinalAdminGames)
        .slice(0, 2)
    : [];
  const urgentReports = reports
    .filter((report) => ["HIGH", "CRITICAL", "URGENT"].includes(report.priority))
    .slice(0, 4);
  const pendingForfeits = forfeits.filter(
    (decision) => decision.status === "PENDING_REVIEW",
  );

  return (
    <div className="admin-section-stack">
      {pendingForfeits.length > 0 ? (
        <ForfeitOverviewAlert
          decisions={pendingForfeits}
          onOpen={() => onNavigate("reports")}
        />
      ) : null}
      <section className="admin-metric-grid">
        {overview.metrics.map((metric) => (
          <article className={`admin-metric-card ${metric.tone}`} key={metric.key}>
            <div className="admin-metric-icon">
              <AdminIcon name={metricIcon(metric.key)} />
            </div>
            <span>{metric.label}</span>
            <strong>{metric.value.toLocaleString()}</strong>
            <small>{metric.detail}</small>
          </article>
        ))}
      </section>

      <div className="admin-overview-grid">
        <section className="admin-card admin-attention-card">
          <AdminCardHeader
            eyebrow="Live operations"
            title="Needs attention"
            actionLabel="View reports"
            onAction={() => onNavigate("reports")}
          />
          {overview.attention.length === 0 ? (
            <AdminEmpty
              icon="check"
              title="Nothing urgent right now"
              detail="New operational issues and high-priority reports will appear here."
            />
          ) : (
            <div className="admin-attention-list">
              {(showAllAttention ? overview.attention : overview.attention.slice(0, 7)).map((item) => (
                <article className={item.gameId ? "actionable" : ""} key={item.id}>
                  <span className={`admin-severity-dot ${item.severity.toLowerCase()}`} />
                  <div>
                    <strong>{item.title}</strong>
                    <p>{item.detail}</p>
                    {!item.dismissible ? (
                      <small className="admin-required-resolution">
                        {item.resolution === "PAYMENT_MANUAL_RECONCILIATION"
                          ? "Manual Stripe reconciliation required · cannot dismiss or retry"
                          : item.resolution?.startsWith("PAYMENT") || item.resolution === "RETRY_PAYMENT_REFUND"
                          ? "Payment resolution required · cannot dismiss"
                          : item.resolution === "RESOLVE_NO_DATA"
                          ? "Admin resolution required · cannot dismiss"
                          : "Assignment required · cannot dismiss"}
                      </small>
                    ) : null}
                  </div>
                  <div className="admin-attention-meta">
                    <span>{humanize(item.kind)}</span>
                    <time>{relativeTime(item.createdAt)}</time>
                    {item.paymentRefundId ? (
                      <button onClick={() => setRetryPaymentRefund(item)} type="button">Review refund →</button>
                    ) : item.gameId && item.matchKind ? (
                      <button
                        onClick={() => router.push(`/admin/games/${item.matchKind!.toLowerCase()}/${item.gameId}`)}
                        type="button"
                      >
                        Resolve or cancel →
                      </button>
                    ) : item.kind === "REPORT" || item.kind.includes("STOPPAGE") || item.kind.includes("FORFEIT") ? (
                      <button onClick={() => onNavigate("reports")} type="button">Review →</button>
                    ) : null}
                  </div>
                </article>
              ))}
              {overview.attention.length > 7 ? (
                <button className="admin-row-action" onClick={() => setShowAllAttention((value) => !value)} type="button">
                  {showAllAttention ? "Show fewer items" : `Show all ${overview.attention.length} items`}
                </button>
              ) : null}
            </div>
          )}
        </section>

        <section className="admin-card">
          <AdminCardHeader
            eyebrow="Schedule"
            title="Games snapshot"
            actionLabel="All games"
            onAction={() => onNavigate("games")}
          />
          <div className="admin-game-snapshot-section">
            <div className="admin-game-snapshot-label">
              <span>Next 2 games</span>
              <small>Closest first</small>
            </div>
            {upcoming.length === 0 ? (
              <p className="admin-game-snapshot-empty">No upcoming games scheduled.</p>
            ) : (
              <CompactGameList games={upcoming} />
            )}
          </div>
          <div className="admin-game-snapshot-section recent">
            <div className="admin-game-snapshot-label">
              <span>Last matchday</span>
              <small>{lastMatchdayDate ? formatAdminDate(lastMatchdayDate) : "No history"}</small>
            </div>
            {lastMatchday.length === 0 ? (
              <p className="admin-game-snapshot-empty">No completed or cancelled games yet.</p>
            ) : (
              <CompactGameList games={lastMatchday} />
            )}
          </div>
        </section>
      </div>

      <div className="admin-overview-grid lower">
        <section className="admin-card">
          <AdminCardHeader
            eyebrow="Moderation"
            title="Priority reports"
            actionLabel="Open inbox"
            onAction={() => onNavigate("reports")}
          />
          {urgentReports.length === 0 ? (
            <AdminEmpty icon="reports" title="No high-priority reports" detail="The queue is under control." />
          ) : (
            <div className="admin-priority-report-list">
              {urgentReports.map((report) => (
                <article key={report.id}>
                  <PriorityBadge priority={report.priority} />
                  <div>
                    <strong>{report.subjectName}</strong>
                    <p>{humanize(report.category)} · {relativeTime(report.createdAt)}</p>
                  </div>
                  <span>{report.status}</span>
                </article>
              ))}
            </div>
          )}
        </section>

        <section className="admin-card">
          <AdminCardHeader
            eyebrow="Accountability"
            title="Recent admin activity"
            actionLabel="Full audit"
            onAction={() => onNavigate("audit")}
          />
          <CompactAuditList items={overview.audit.slice(0, 5)} />
        </section>
      </div>
      {retryPaymentRefund ? (
        <PaymentRefundRetryDialog
          accessToken={accessToken}
          item={retryPaymentRefund}
          onClose={() => setRetryPaymentRefund(null)}
          onSaved={async (message) => {
            setRetryPaymentRefund(null);
            await onRefundRetried(message);
          }}
        />
      ) : null}
    </div>
  );
}

function PaymentRefundRetryDialog({ accessToken, item, onClose, onSaved }: {
  accessToken: string;
  item: AttentionItem;
  onClose: () => void;
  onSaved: (message: string) => Promise<void>;
}) {
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function retry() {
    setSaving(true);
    setError(null);
    try {
      const response = await fetchJson<{ result?: { status?: string; already_settled?: boolean } }>(
        `/api/referee/admin/payments/refunds/${item.paymentRefundId}/retry`,
        {
          method: "POST",
          headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
          body: JSON.stringify({ reason: reason.trim() }),
        },
      );
      await onSaved(refundRetryNotice({
        status: response.result?.status,
        alreadySettled: response.result?.already_settled,
        destination: "ORIGINAL_PAYMENT_METHOD",
      }));
    } catch (error) {
      setError(errorMessage(error, "Could not retry this refund."));
      setSaving(false);
    }
  }
  return (
    <AdminModal onClose={() => { if (!saving) onClose(); }}>
      <span className="admin-eyebrow">Payment refund</span>
      <h2>{item.title}</h2>
      <p className="admin-modal-lead">{item.detail}</p>
      <p>The refund returns to the original payment method. A retry checks the existing processor reference and never creates a duplicate refund.</p>
      <label className="admin-modal-field">
        <span>Reason for retry</span>
        <textarea value={reason} onChange={(event) => setReason(event.target.value)} maxLength={2000} disabled={saving} rows={4} />
        <small>Minimum 10 characters. Your reason is recorded in the audit trail.</small>
      </label>
      {error ? <p role="alert">{error}</p> : null}
      <div className="admin-modal-actions">
        <button type="button" disabled={saving} onClick={onClose} className="admin-secondary-button">Close</button>
        <button type="button" disabled={saving || reason.trim().length < 10} onClick={() => void retry()} className="admin-primary-button">{saving ? "Checking refund…" : "Retry refund"}</button>
      </div>
    </AdminModal>
  );
}

function CompactGameList({ games }: { games: RefereeFixture[] }) {
  return (
    <div className="admin-compact-game-list">
      {games.map((game) => (
        <article key={`${game.matchKind}-${game.id}`}>
          <div className={`admin-game-emblem ${game.matchKind.toLowerCase()}`}>
            {game.matchKind === "SOLO" ? "S" : game.homeClan.emblem}
          </div>
          <div>
            <strong>{game.homeClan.tag} <span>vs</span> {game.awayClan.tag}</strong>
            <p>{formatAdminDate(game.matchDate)} · {game.timeSlot}{game.timezone ? ` (${game.timezone})` : ""}</p>
          </div>
          <StatusBadge status={adminDisplayStatus(game)} />
        </article>
      ))}
    </div>
  );
}

function ForfeitOverviewAlert({
  decisions,
  onOpen,
}: {
  decisions: AdminForfeit[];
  onOpen: () => void;
}) {
  const next = decisions[0];
  const home = forfeitHomeClan(next);
  const away = forfeitAwayClan(next);
  return (
    <section className={forfeitStyles.overviewAlert}>
      <div className={forfeitStyles.overviewIcon}><AdminIcon name="alert" /></div>
      <div className={forfeitStyles.overviewCopy}>
        <span>Admin decision required</span>
        <h2>
          {decisions.length === 1
            ? "Review a provisional 3–0 forfeit"
            : `${decisions.length} provisional forfeits need review`}
        </h2>
        <p>
          {home.tag ?? home.name} {next.provisionalHomeScore}–{next.provisionalAwayScore} {away.tag ?? away.name}
          {next.reasonCode ? ` · ${humanize(next.reasonCode)}` : ""}
          {decisions.length > 1 ? ` · ${decisions.length - 1} more waiting` : ""}
        </p>
      </div>
      <button onClick={onOpen} type="button">
        Review evidence <AdminIcon name="arrow" />
      </button>
    </section>
  );
}

function ForfeitReviewQueue({
  decisions,
  submitting,
  onReview,
}: {
  decisions: AdminForfeit[];
  submitting: string | null;
  onReview: (decision: AdminForfeit, action: "CONFIRM" | "OVERTURN") => void;
}) {
  const pending = decisions.filter((decision) => decision.status === "PENDING_REVIEW");
  const reviewed = decisions.filter((decision) => decision.status !== "PENDING_REVIEW");

  return (
    <section className={`admin-card ${forfeitStyles.queue}`}>
      <header className={forfeitStyles.queueHeader}>
        <div>
          <span className="admin-eyebrow">Referee-awarded results</span>
          <h2>Provisional forfeit review</h2>
          <p>
            A stopped match receives a provisional 3–0 only when the assigned referee reports the responsible team.
            Confirm or overturn it after checking the evidence.
          </p>
        </div>
        <span className={pending.length > 0 ? forfeitStyles.pendingCount : forfeitStyles.clearCount}>
          {pending.length > 0 ? `${pending.length} pending` : "Queue clear"}
        </span>
      </header>

      {pending.length === 0 ? (
        <div className={forfeitStyles.emptyState}>
          <span><AdminIcon name="check" /></span>
          <div>
            <strong>No provisional forfeits need a decision</strong>
            <p>New referee-awarded 3–0 results will stay provisional until an admin reviews them here.</p>
          </div>
        </div>
      ) : (
        <div className={forfeitStyles.decisionList}>
          {pending.map((decision) => {
            const home = forfeitHomeClan(decision);
            const away = forfeitAwayClan(decision);
            return (
              <article className={forfeitStyles.decisionCard} key={decision.id}>
                <div className={forfeitStyles.decisionHeading}>
                  <div>
                    <span className={forfeitStyles.provisionalBadge}>Provisional result</span>
                    <h3>{home.name} <span>vs</span> {away.name}</h3>
                    <p>
                      {decision.matchDate ? formatAdminDate(decision.matchDate) : "Date unavailable"}
                      {decision.timeSlot ? ` · ${decision.timeSlot}` : ""}
                      {decision.venue ? ` · ${decision.venue}` : ""}
                    </p>
                  </div>
                  <div className={forfeitStyles.provisionalScore}>
                    <strong>{decision.provisionalHomeScore}–{decision.provisionalAwayScore}</strong>
                    <span>{decision.awardedClan.name} awarded win</span>
                  </div>
                </div>

                <div className={forfeitStyles.scoreComparison}>
                  <div>
                    <span>Score when stopped</span>
                    <strong>{formatPriorScore(decision)}</strong>
                  </div>
                  <AdminIcon name="arrow" />
                  <div>
                    <span>Provisional score</span>
                    <strong>{decision.provisionalHomeScore}–{decision.provisionalAwayScore}</strong>
                  </div>
                  <div className={forfeitStyles.ratingHold}>
                    <AdminIcon name="lock" /> Ratings held until review
                  </div>
                </div>

                <div className={forfeitStyles.evidenceGrid}>
                  <div>
                    <span>Team reported</span>
                    <strong>{decision.reportedClan.name}</strong>
                    <small>{decision.reportCategory ? humanize(decision.reportCategory) : "Team misconduct"}</small>
                  </div>
                  <div>
                    <span>Stopped by</span>
                    <strong>{decision.referee.name}</strong>
                    <small>
                      {decision.reasonCode ? humanize(decision.reasonCode) : "Reason not categorized"}
                      {decision.elapsedSeconds > 0 ? ` · ${formatReplayOffset(decision.elapsedSeconds)} elapsed` : ""}
                    </small>
                  </div>
                  <div>
                    <span>Replay evidence</span>
                    <strong>
                      {decision.replayOffsetSeconds === null
                        ? "No marker provided"
                        : formatReplayOffset(decision.replayOffsetSeconds)}
                    </strong>
                    <small>Recording timestamp supplied by referee</small>
                  </div>
                  <div>
                    <span>Submitted</span>
                    <strong>{relativeTime(decision.createdAt)}</strong>
                    <small>Report #{decision.reportId.slice(0, 8).toUpperCase()}</small>
                  </div>
                </div>

                <div className={forfeitStyles.statement}>
                  <span>Referee evidence</span>
                  <p>{decision.reportDetails || decision.reason || "No additional written evidence was provided."}</p>
                  {decision.reason && decision.reason !== decision.reportDetails ? (
                    <small>Stoppage note: {decision.reason}</small>
                  ) : null}
                </div>

                <div className={forfeitStyles.reviewActions}>
                  <p><AdminIcon name="audit" /> Your note and decision are permanently audited.</p>
                  <div>
                    <button
                      className="admin-secondary-button"
                      disabled={submitting !== null}
                      onClick={() => onReview(decision, "OVERTURN")}
                      type="button"
                    >
                      Overturn result
                    </button>
                    <button
                      className="admin-primary-button"
                      disabled={submitting !== null}
                      onClick={() => onReview(decision, "CONFIRM")}
                      type="button"
                    >
                      Confirm 3–0
                    </button>
                  </div>
                </div>
              </article>
            );
          })}
        </div>
      )}

      {reviewed.length > 0 ? (
        <details className={forfeitStyles.reviewHistory}>
          <summary>Recently reviewed forfeits <span>{reviewed.length}</span></summary>
          <div>
            {reviewed.slice(0, 12).map((decision) => {
              const home = forfeitHomeClan(decision);
              const away = forfeitAwayClan(decision);
              return (
                <article key={decision.id}>
                  <span className={decision.status === "CONFIRMED" ? forfeitStyles.confirmed : forfeitStyles.overturned}>
                    {humanize(decision.status)}
                  </span>
                  <div>
                    <strong>{home.tag ?? home.name} vs {away.tag ?? away.name}</strong>
                    <p>{decision.reviewNote ?? "No review note recorded."}</p>
                    <small>
                      {decision.reviewer?.name ?? "Field admin"} · {formatDateTime(decision.reviewedAt)}
                    </small>
                  </div>
                  <b>
                    {decision.status === "CONFIRMED"
                      ? `${decision.provisionalHomeScore}–${decision.provisionalAwayScore}`
                      : formatPriorScore(decision)}
                  </b>
                </article>
              );
            })}
          </div>
        </details>
      ) : null}
    </section>
  );
}

function GamesSection({
  accessToken,
  assignments,
  games,
  submitting,
  onAssignReferee,
  onCancel,
  onCreateSoloGame,
  onCreateReferee,
  onOverrideScore,
  onRemoveSoloGame,
}: {
  accessToken: string;
  assignments: RefereeAssignmentsResponse;
  games: RefereeFixture[];
  submitting: string | null;
  onAssignReferee: (fixture: RefereeFixture, refereeId: string) => Promise<boolean>;
  onCancel: (fixture: RefereeFixture) => void;
  onCreateSoloGame: () => void;
  onCreateReferee: (input: { displayName: string; email: string }) => Promise<boolean>;
  onOverrideScore: (fixture: RefereeFixture) => void;
  onRemoveSoloGame: (fixture: RefereeFixture) => void;
}) {
  const router = useRouter();
  const [query, setQuery] = useState("");
  const [view, setView] = useState<AdminGamesView>("SCHEDULED");
  const [display, setDisplay] = useState<AdminGamesDisplay>("LIST");
  const [calendarMonth, setCalendarMonth] = useState(() => {
    const now = new Date();
    return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
  });
  const [status, setStatus] = useState("ALL");
  const [kind, setKind] = useState("ALL");
  const [refereeFilter, setRefereeFilter] = useState("ALL");
  const [activeId, setActiveId] = useState<string | null>(null);
  const [broadcast, setBroadcast] = useState<BroadcastControlResponse | null>(null);
  const [broadcastLoading, setBroadcastLoading] = useState(false);
  const [broadcastError, setBroadcastError] = useState<string | null>(null);
  const [participants, setParticipants] = useState<AdminGameParticipants | null>(null);
  const [participantsLoading, setParticipantsLoading] = useState(false);
  const [participantsError, setParticipantsError] = useState<string | null>(null);
  const [newRefereeName, setNewRefereeName] = useState("");
  const [newRefereeEmail, setNewRefereeEmail] = useState("");

  useEffect(() => {
    const requestedGameId = new URLSearchParams(window.location.search).get("gameId");
    if (!requestedGameId) return;
    const requested = games.find((game) => game.id === requestedGameId);
    if (!requested) return;
    setView(isFinalAdminGame(requested) ? "FINAL" : "SCHEDULED");
    setStatus("ALL");
    setKind("ALL");
    setRefereeFilter("ALL");
    setQuery("");
    setActiveId(`${requested.matchKind}-${requested.id}`);
  }, [games]);

  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return games
      .filter((game) => {
        if (view === "SCHEDULED" ? !isScheduledAdminGame(game) : !isFinalAdminGame(game)) {
          return false;
        }
        if (status !== "ALL" && adminDisplayStatus(game) !== status) return false;
        if (kind !== "ALL" && game.matchKind !== kind) return false;
        const assignedId = assignedRefereeId(assignments, game);
        if (refereeFilter === "UNASSIGNED" && assignedId) return false;
        if (
          refereeFilter !== "ALL" &&
          refereeFilter !== "UNASSIGNED" &&
          assignedId !== refereeFilter
        ) return false;
        if (!needle) return true;
        return [
          game.homeClan.name,
          game.homeClan.tag,
          game.awayClan.name,
          game.awayClan.tag,
          game.venue,
          game.matchDate,
        ].some((value) => value.toLowerCase().includes(needle));
      })
      .sort(view === "SCHEDULED" ? sortScheduledAdminGames : sortFinalAdminGames);
  }, [assignments, games, kind, query, refereeFilter, status, view]);

  const scheduledCount = games.filter(isScheduledAdminGame).length;
  const finalCount = games.filter(isFinalAdminGame).length;

  const active = filtered.find((game) => `${game.matchKind}-${game.id}` === activeId) ??
    filtered[0] ??
    null;

  useEffect(() => {
    if (!active) return;
    const nextId = `${active.matchKind}-${active.id}`;
    if (activeId !== nextId) setActiveId(nextId);
  }, [active, activeId]);

  useEffect(() => {
    setBroadcast(null);
    setBroadcastError(null);
  }, [active?.id, active?.matchKind]);

  useEffect(() => {
    if (!active) {
      setParticipants(null);
      setParticipantsError(null);
      return;
    }
    let cancelled = false;
    setParticipants(null);
    setParticipantsError(null);
    setParticipantsLoading(true);
    const path = `/api/referee/admin/games/${active.matchKind.toLowerCase()}/${active.id}/players`;
    void fetchJson<{ participants: AdminGameParticipants }>(path, {
      headers: { authorization: `Bearer ${accessToken}` },
      cache: "no-store",
    }).then((payload) => {
      if (!cancelled) setParticipants(payload.participants);
    }).catch((loadError) => {
      if (!cancelled) {
        setParticipantsError(errorMessage(loadError, "Could not load signed-up players."));
      }
    }).finally(() => {
      if (!cancelled) setParticipantsLoading(false);
    });
    return () => {
      cancelled = true;
    };
  }, [accessToken, active?.id, active?.matchKind]);

  async function loadReplay() {
    if (!active) return;
    setBroadcastLoading(true);
    setBroadcastError(null);
    try {
      const path = active.matchKind === "SOLO"
        ? `/api/referee/open-queue-games/${active.id}/broadcast`
        : `/api/referee/fixtures/${active.id}/broadcast`;
      const payload = await fetchJson<BroadcastControlResponse>(path, {
        headers: { authorization: `Bearer ${accessToken}` },
        cache: "no-store",
      });
      setBroadcast(payload);
    } catch (loadError) {
      setBroadcastError(errorMessage(loadError, "Could not load replay status."));
    } finally {
      setBroadcastLoading(false);
    }
  }

  async function submitNewReferee(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const created = await onCreateReferee({
      displayName: newRefereeName.trim(),
      email: newRefereeEmail.trim().toLowerCase(),
    });
    if (created) {
      setNewRefereeName("");
      setNewRefereeEmail("");
    }
  }

  return (
    <div className="admin-games-layout">
      <section className="admin-card admin-games-browser">
        <div className="admin-games-browser-head">
          <div>
            <span className="admin-eyebrow">Match operations</span>
            <h2>Games</h2>
          </div>
          <div className="admin-games-head-actions">
            <a className="admin-secondary-button" href="/admin/schedules">Recurring schedules</a>
            <div className="admin-display-switch" aria-label="Games display" role="group">
              <button className={display === "LIST" ? "active" : ""} onClick={() => setDisplay("LIST")} type="button">List</button>
              <button className={display === "CALENDAR" ? "active" : ""} onClick={() => {
                setDisplay("CALENDAR");
                const closest = filtered[0]?.matchDate;
                if (closest) {
                  const [year, month] = closest.split("-").map(Number);
                  if (year && month) setCalendarMonth(new Date(Date.UTC(year, month - 1, 1)));
                }
              }} type="button">Calendar</button>
            </div>
            <button
              className="admin-primary-button"
              disabled={submitting !== null}
              onClick={onCreateSoloGame}
              type="button"
            >
              <span aria-hidden="true">＋</span> Create solo game
            </button>
          </div>
        </div>
        <GamePaymentSettingsPanel accessToken={accessToken} />
        <div className="admin-game-view-tabs" role="tablist" aria-label="Game timing">
          <button
            aria-selected={view === "SCHEDULED"}
            className={view === "SCHEDULED" ? "active" : ""}
            onClick={() => {
              setView("SCHEDULED");
              setStatus("ALL");
              setActiveId(null);
            }}
            role="tab"
            type="button"
          >
            <span>Scheduled <b>{scheduledCount}</b></span>
            <small>Upcoming and live</small>
          </button>
          <button
            aria-selected={view === "FINAL"}
            className={view === "FINAL" ? "active" : ""}
            onClick={() => {
              setView("FINAL");
              setStatus("ALL");
              setActiveId(null);
            }}
            role="tab"
            type="button"
          >
            <span>Final <b>{finalCount}</b></span>
            <small>Completed and cancelled</small>
          </button>
        </div>
        <div className="admin-table-toolbar">
          <label className="admin-search-field">
            <AdminIcon name="search" />
            <input
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Search team, venue or date"
              value={query}
            />
          </label>
          <select onChange={(event) => setKind(event.target.value)} value={kind}>
            <option value="ALL">All game types</option>
            <option value="CLAN">Clan</option>
            <option value="SOLO">Solo</option>
          </select>
          <select onChange={(event) => setStatus(event.target.value)} value={status}>
            <option value="ALL">All {view === "SCHEDULED" ? "scheduled" : "final"} statuses</option>
            <option value="NO_DATA">No data</option>
            <option value="UNDER_REVIEW">Under review</option>
            {view === "SCHEDULED" ? (
              <>
                <option value="LIVE">Live</option>
                <option value="SCHEDULED">Scheduled</option>
                <option value="FULL">Full</option>
                <option value="OPEN">Open</option>
              </>
            ) : (
              <>
                <option value="FINAL">Final</option>
                <option value="CANCELLED">Cancelled</option>
              </>
            )}
          </select>
          <select
            aria-label="Filter by referee"
            onChange={(event) => setRefereeFilter(event.target.value)}
            value={refereeFilter}
          >
            <option value="ALL">All referees</option>
            <option value="UNASSIGNED">Unassigned</option>
            {assignments.referees.map((referee) => (
              <option key={referee.profileId} value={referee.profileId}>
                {referee.displayName}
              </option>
            ))}
          </select>
        </div>
        <div className="admin-table-count">{filtered.length} games</div>
        {filtered.length === 0 ? (
          <AdminEmpty icon="games" title="No matching games" detail="Try a different status or search." />
        ) : display === "CALENDAR" ? (
          <AdminGamesCalendar
            assignments={assignments}
            games={filtered}
            month={calendarMonth}
            onMonth={setCalendarMonth}
            onOpen={(game) => router.push(`/admin/games/${game.matchKind.toLowerCase()}/${game.id}`)}
          />
        ) : (
          <div className="admin-game-table-wrap">
            <table className="admin-data-table admin-games-table">
              <thead>
                <tr>
                  <th>Match</th>
                  <th>Date & venue</th>
                  <th>Referee</th>
                  <th>Status</th>
                  <th>Score</th>
                  <th aria-label="Open" />
                </tr>
              </thead>
              <tbody>
                {filtered.map((game) => {
                  const key = `${game.matchKind}-${game.id}`;
                  return (
                    <tr
                      className={active && key === `${active.matchKind}-${active.id}` ? "active" : ""}
                      key={key}
                      onClick={() => router.push(`/admin/games/${game.matchKind.toLowerCase()}/${game.id}`)}
                      onKeyDown={(event) => {
                        if (event.key === "Enter" || event.key === " ") {
                          event.preventDefault();
                          router.push(`/admin/games/${game.matchKind.toLowerCase()}/${game.id}`);
                        }
                      }}
                      tabIndex={0}
                    >
                      <td>
                        <div className="admin-match-cell">
                          <span>{game.matchKind === "SOLO" ? "S" : game.homeClan.emblem}</span>
                          <div>
                            <strong>{game.homeClan.tag} vs {game.awayClan.tag}</strong>
                            <small>{game.matchKind === "SOLO" ? "Solo queue" : "Clan fixture"}</small>
                          </div>
                        </div>
                      </td>
                      <td>
                        <strong>{formatAdminDate(game.matchDate)}</strong>
                        <small>{game.timeSlot} · {game.venue}</small>
                      </td>
                      <td>{assignedRefereeName(assignments, game)}</td>
                      <td><StatusBadge status={adminDisplayStatus(game)} /></td>
                      <td className="admin-score-cell">{displayScore(game)}</td>
                      <td><AdminIcon name="arrow" /></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {active ? (
        <aside className="admin-card admin-game-detail">
          <div className="admin-game-detail-head">
            <div>
              <span className="admin-eyebrow">{active.matchKind === "SOLO" ? "Solo queue" : "Clan fixture"}</span>
              <h2>{active.homeClan.name} <span>vs</span> {active.awayClan.name}</h2>
            </div>
            <StatusBadge status={adminDisplayStatus(active)} />
          </div>
          <button
            className="admin-open-game-overview"
            onClick={() => router.push(`/admin/games/${active.matchKind.toLowerCase()}/${active.id}`)}
            type="button"
          >
            Open full game overview <AdminIcon name="arrow" />
          </button>
          <div className="admin-detail-score">
            <div><span>{active.homeClan.emblem}</span><strong>{active.homeClan.tag}</strong></div>
            <b>{displayScore(active)}</b>
            <div><span>{active.awayClan.emblem}</span><strong>{active.awayClan.tag}</strong></div>
          </div>
          <dl className="admin-detail-facts">
            <div><dt>Date</dt><dd>{formatAdminDate(active.matchDate)}</dd></div>
            <div><dt>Time</dt><dd>{active.timeSlot}</dd></div>
            <div><dt>Venue</dt><dd>{active.venue}</dd></div>
            <div><dt>Referee</dt><dd>{assignedRefereeName(assignments, active)}</dd></div>
          </dl>

          {isScheduledAdminGame(active) ? (
            <div className="admin-detail-section admin-referee-assignment">
              <div className="admin-detail-section-title">
                <div><AdminIcon name="referee" /><span>Referee assignment</span></div>
              </div>
              <label>
                <span>Assigned official</span>
                <select
                  disabled={submitting !== null || active.status === "LIVE"}
                  onChange={(event) => void onAssignReferee(active, event.target.value)}
                  value={assignedRefereeId(assignments, active)}
                >
                  <option value="">Unassigned</option>
                  {assignments.referees.map((referee) => (
                    <option key={referee.profileId} value={referee.profileId}>
                      {referee.displayName} · {referee.email ?? "Staff email setup required"}
                    </option>
                  ))}
                </select>
              </label>
              {active.status === "LIVE" ? (
                <p className="admin-detail-hint">Live assignments are locked to avoid an accidental handoff.</p>
              ) : null}
              <details className="admin-add-referee">
                <summary>+ Add referee access</summary>
                <form onSubmit={submitNewReferee}>
                  <input
                    placeholder="Full name"
                    maxLength={50}
                    required
                    value={newRefereeName}
                    onChange={(event) => setNewRefereeName(event.target.value)}
                  />
                  <input
                    type="email"
                    autoComplete="email"
                    placeholder="Dedicated staff email"
                    required
                    value={newRefereeEmail}
                    onChange={(event) => setNewRefereeEmail(event.target.value)}
                  />
                  <button
                    className="admin-secondary-button"
                    disabled={submitting !== null}
                    type="submit"
                  >
                    {submitting === "create-referee" ? "Adding access…" : "Add access and send login"}
                  </button>
                  <p className="admin-detail-hint">Creates a separate email-only staff account. Use an email that is not used by a player account.</p>
                </form>
              </details>
            </div>
          ) : null}

          <AdminGamePlayersPanel
            fixture={active}
            participants={participants}
            error={participantsError}
            loading={participantsLoading}
          />
          {active.status === "CANCELLED" ? (
            <div className="admin-cancellation-note">
              <AdminIcon name="alert" />
              <div>
                <strong>{active.cancellationCode ?? "Cancelled"}</strong>
                <p>{active.cancellationReason ?? "No reason was recorded."}</p>
              </div>
            </div>
          ) : null}

          <div className="admin-detail-section">
            <div className="admin-detail-section-title">
              <div><AdminIcon name="replay" /><span>Match recording</span></div>
              {!broadcast ? (
                <button disabled={broadcastLoading} onClick={() => void loadReplay()} type="button">
                  {broadcastLoading ? "Checking…" : "Check replay"}
                </button>
              ) : null}
            </div>
            {broadcastError ? <p className="admin-inline-error">{broadcastError}</p> : null}
            {broadcast?.broadcast?.replayHlsUrl ? (
              <div className="admin-replay-player">
                <video controls playsInline preload="metadata" src={broadcast.broadcast.replayHlsUrl} />
                <a href={broadcast.broadcast.replayHlsUrl} rel="noreferrer" target="_blank">
                  Open recording <AdminIcon name="external" />
                </a>
              </div>
            ) : broadcast ? (
              <div className="admin-replay-state">
                <span className={`admin-replay-status ${broadcast.broadcast?.status.toLowerCase() ?? "none"}`} />
                <div>
                  <strong>{broadcastStatusText(broadcast.broadcast?.status)}</strong>
                  <p>{broadcast.broadcast?.errorMessage ?? "No replay is available for this match yet."}</p>
                </div>
              </div>
            ) : (
              <p className="admin-detail-hint">View the saved stream or check its processing status.</p>
            )}
          </div>

          <div className="admin-detail-actions">
            <button
              className="admin-secondary-button"
              disabled={submitting !== null || active.status !== "FINAL"}
              onClick={() => onOverrideScore(active)}
              type="button"
            >
              <AdminIcon name="edit" /> Correct score
            </button>
            <button
              className="admin-danger-button"
              disabled={
                submitting !== null ||
                !["OPEN", "FULL", "SCHEDULED"].includes(active.status)
              }
              onClick={() => onCancel(active)}
              type="button"
            >
              <AdminIcon name="cancel" /> Cancel game
            </button>
          </div>
          {active.matchKind === "SOLO" && active.status === "OPEN" ? (
            <button
              className="admin-remove-empty-game"
              disabled={submitting !== null}
              onClick={() => onRemoveSoloGame(active)}
              type="button"
            >
              Remove empty game
            </button>
          ) : null}
          <p className="admin-audit-hint">
            <AdminIcon name="audit" /> Creation, removal, score corrections and cancellations are permanently audited.
          </p>
        </aside>
      ) : null}
    </div>
  );
}

function AdminGamesCalendar({
  assignments,
  games,
  month,
  onMonth,
  onOpen,
}: {
  assignments: RefereeAssignmentsResponse;
  games: RefereeFixture[];
  month: Date;
  onMonth: (month: Date) => void;
  onOpen: (game: RefereeFixture) => void;
}) {
  const year = month.getUTCFullYear();
  const monthIndex = month.getUTCMonth();
  const firstDay = new Date(Date.UTC(year, monthIndex, 1));
  const mondayOffset = (firstDay.getUTCDay() + 6) % 7;
  const gridStart = new Date(firstDay);
  gridStart.setUTCDate(firstDay.getUTCDate() - mondayOffset);
  const days = Array.from({ length: 42 }, (_, index) => {
    const date = new Date(gridStart);
    date.setUTCDate(gridStart.getUTCDate() + index);
    return date;
  });
  const gamesByDay = new Map<string, RefereeFixture[]>();
  for (const game of games) {
    const bucket = gamesByDay.get(game.matchDate) ?? [];
    bucket.push(game);
    gamesByDay.set(game.matchDate, bucket);
  }
  const monthLabel = new Intl.DateTimeFormat("en-BH", {
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  }).format(month);

  function shiftMonth(delta: number) {
    onMonth(new Date(Date.UTC(year, monthIndex + delta, 1)));
  }

  return (
    <div className="admin-calendar">
      <header>
        <button aria-label="Previous month" onClick={() => shiftMonth(-1)} type="button">←</button>
        <div><strong>{monthLabel}</strong><small>{games.length} filtered games</small></div>
        <button aria-label="Next month" onClick={() => shiftMonth(1)} type="button">→</button>
      </header>
      <div className="admin-calendar-weekdays">
        {['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map((day) => <span key={day}>{day}</span>)}
      </div>
      <div className="admin-calendar-grid">
        {days.map((date) => {
          const key = date.toISOString().slice(0, 10);
          const dayGames = gamesByDay.get(key) ?? [];
          const outside = date.getUTCMonth() !== monthIndex;
          return (
            <section className={outside ? "outside" : ""} key={key}>
              <time dateTime={key}>{date.getUTCDate()}</time>
              <div>
                {dayGames.map((game) => (
                  <button
                    className={`admin-calendar-game ${game.matchKind.toLowerCase()}`}
                    key={`${game.matchKind}-${game.id}`}
                    onClick={() => onOpen(game)}
                    title={`${game.homeClan.name} vs ${game.awayClan.name}`}
                    type="button"
                  >
                    <span>{game.timeSlot}</span>
                    <strong>{game.homeClan.tag} vs {game.awayClan.tag}</strong>
                    <small>{assignedRefereeName(assignments, game)}</small>
                  </button>
                ))}
              </div>
            </section>
          );
        })}
      </div>
    </div>
  );
}

function AdminGamePlayersPanel({
  fixture,
  participants,
  error,
  loading,
}: {
  fixture: RefereeFixture;
  participants: AdminGameParticipants | null;
  error: string | null;
  loading: boolean;
}) {
  const actualPlayers = participants?.actualPlayers ?? [];
  const usingClanActualFallback = participants?.matchKind === "CLAN" &&
    participants.plannedPlayers.length === 0 && actualPlayers.length > 0;
  const signedUpPlayers = participants?.matchKind === "SOLO"
    ? participants.registeredPlayers
    : usingClanActualFallback
      ? actualPlayers
      : participants?.plannedPlayers ?? [];
  const historyPlayers = participants?.matchKind === "SOLO"
    ? participants.withdrawnPlayers
    : participants?.removedPlayers ?? [];
  const groups = participantGroups(fixture, signedUpPlayers);
  const signedUpLabel = participants?.matchKind === "SOLO"
    ? `${participants.counts.registered} / ${participants.capacity} booked`
    : participants?.matchKind === "CLAN"
      ? usingClanActualFallback
        ? `${participants.counts.actual} recorded`
        : `${participants.counts.plannedHome} home · ${participants.counts.plannedAway} away`
      : "";

  return (
    <div className="admin-detail-section admin-game-players">
      <div className="admin-detail-section-title">
        <div><AdminIcon name="people" /><span>Signed-up players</span></div>
        {participants ? <b>{signedUpLabel}</b> : null}
      </div>
      {loading ? (
        <LoadingSkeleton label="Loading signed-up players" layout="rows" />
      ) : error ? (
        <p className="admin-inline-error">{error}</p>
      ) : !participants || signedUpPlayers.length === 0 ? (
        <div className="admin-player-empty">
          <AdminIcon name="people" />
          <span>
            <strong>No players confirmed yet</strong>
            <small>The roster will appear here as bookings or clan selections are confirmed.</small>
          </span>
        </div>
      ) : (
        <>
          <div className="admin-player-groups">
            {groups.map((group) => (
              <section key={group.key}>
                <header>
                  <span>{group.emblem}</span>
                  <strong>{group.label}</strong>
                  <b>{group.players.length}</b>
                </header>
                <div>
                  {group.players.map((player) => (
                    <AdminGamePlayerRow key={`${group.key}-${player.profileId}`} player={player} />
                  ))}
                </div>
              </section>
            ))}
          </div>
          {actualPlayers.length > 0 ? (
            <p className="admin-player-footnote">
              <AdminIcon name="check" /> {actualPlayers.length} players checked in or recorded as playing
            </p>
          ) : null}
          {historyPlayers.length > 0 ? (
            <details className="admin-player-history">
              <summary>{participants.matchKind === "SOLO" ? "Withdrawn bookings" : "Removed or replaced players"} · {historyPlayers.length}</summary>
              <div>
                {historyPlayers.map((player) => (
                  <AdminGamePlayerRow key={`history-${player.profileId}`} player={player} muted />
                ))}
              </div>
            </details>
          ) : null}
        </>
      )}
    </div>
  );
}

function AdminGamePlayerRow({
  player,
  muted = false,
}: {
  player: AdminGameParticipant;
  muted?: boolean;
}) {
  return (
    <div className={`admin-game-player-row ${muted ? "muted" : ""}`}>
      {player.avatarUrl ? (
        <img alt="" src={player.avatarUrl} />
      ) : (
        <span className="admin-game-player-avatar">{initials(player.displayName)}</span>
      )}
      <span>
        <strong>{player.displayName}</strong>
        <small>
          {player.username ? `@${player.username.replace(/^@/, "")} · ` : ""}
          {player.role ? humanize(player.role) : "Player"}
        </small>
      </span>
      <span className="admin-game-player-badges">
        {player.checkedInAt ? <b>Checked in</b> : null}
        {player.played ? <b>Played</b> : null}
        {player.ratingAtTeamAssignment !== null ? <em>{player.ratingAtTeamAssignment} SR</em> : null}
      </span>
    </div>
  );
}

function participantGroups(
  fixture: RefereeFixture,
  players: AdminGameParticipant[],
) {
  const definitions = fixture.matchKind === "SOLO"
    ? [
        { key: "WHITE", label: "White team", emblem: "⚪" },
        { key: "BLACK", label: "Black team", emblem: "⚫" },
        { key: "UNASSIGNED", label: "Team not assigned", emblem: "○" },
      ]
    : [
        { key: "HOME", label: fixture.homeClan.name, emblem: fixture.homeClan.emblem },
        { key: "AWAY", label: fixture.awayClan.name, emblem: fixture.awayClan.emblem },
        { key: "UNASSIGNED", label: "Side not recorded", emblem: "○" },
      ];
  return definitions.map((definition) => ({
    ...definition,
    players: players.filter((player) =>
      definition.key === "UNASSIGNED"
        ? player.side === null
        : player.side === definition.key
    ),
  })).filter((group) => group.players.length > 0);
}

function SupportSection({
  tickets,
  status,
  submitting,
  onStatus,
  onAction,
}: {
  tickets: AdminSupportTicket[];
  status: string;
  submitting: string | null;
  onStatus: (status: string) => void;
  onAction: (
    ticket: AdminSupportTicket,
    action: "START" | "RESOLVE" | "CLOSE" | "REOPEN" | "DUPLICATE",
  ) => void;
}) {
  const [activeId, setActiveId] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const needle = query.trim().toLowerCase();
  const filtered = tickets.filter((ticket) =>
    !needle ||
    [
      ticket.reference,
      ticket.requesterName,
      ticket.requesterUsername ?? "",
      ticket.category,
      ticket.subject,
      ticket.description,
    ].some((value) => value.toLowerCase().includes(needle))
  );
  const active =
    filtered.find((ticket) => ticket.id === activeId) ??
      filtered[0] ??
      null;

  useEffect(() => {
    if (active && active.id !== activeId) setActiveId(active.id);
  }, [active, activeId]);

  return (
    <div className="admin-reports-layout admin-support-layout">
      <section className="admin-card admin-report-inbox admin-support-inbox">
        <div className="admin-inbox-head">
          <div>
            <span className="admin-eyebrow">Private customer help</span>
            <h2>Support inbox</h2>
          </div>
          <span>{filtered.length}</span>
        </div>
        <div className="admin-report-filters">
          <label className="admin-search-field">
            <AdminIcon name="search" />
            <input
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Search tickets"
              value={query}
            />
          </label>
          <select
            onChange={(event) => onStatus(event.target.value)}
            value={status}
          >
            <option value="ACTIVE">Needs attention</option>
            <option value="OPEN">Open</option>
            <option value="IN_PROGRESS">In progress</option>
            <option value="RESOLVED">Resolved</option>
            <option value="CLOSED">Closed</option>
            <option value="DUPLICATE">Duplicates</option>
            <option value="ALL">All tickets</option>
          </select>
        </div>
        {filtered.length === 0 ? (
          <AdminEmpty
            detail={
              status === "ACTIVE"
                ? "New player requests will appear here."
                : "Try another status or search."
            }
            icon="support"
            title="No support tickets here"
          />
        ) : (
          <div className="admin-report-list admin-support-list">
            {filtered.map((ticket) => (
              <button
                className={active?.id === ticket.id ? "active" : ""}
                key={ticket.id}
                onClick={() => setActiveId(ticket.id)}
                type="button"
              >
                <div className="admin-report-list-top">
                  <PriorityBadge priority={ticket.priority} />
                  <time>{relativeTime(ticket.createdAt)}</time>
                </div>
                <strong>{ticket.requesterName}</strong>
                <p>{humanize(ticket.category)}</p>
                <small>{truncate(ticket.description, 110)}</small>
                <span className="admin-report-state">
                  {humanize(ticket.status)}
                </span>
              </button>
            ))}
          </div>
        )}
      </section>

      {active ? (
        <section className="admin-card admin-report-detail admin-support-detail">
          <div className="admin-report-detail-head">
            <div>
              <PriorityBadge priority={active.priority} />
              <StatusBadge status={active.status} />
            </div>
            <span>{active.reference}</span>
          </div>

          <div className="admin-reported-subject admin-support-requester">
            <div className="admin-subject-avatar">
              {initials(active.requesterName)}
            </div>
            <div>
              <span>Support request from</span>
              <h2>{active.requesterName}</h2>
              <p>
                {active.requesterUsername
                  ? `@${active.requesterUsername}`
                  : "Player account"}
              </p>
            </div>
            <b>{humanize(active.category)}</b>
          </div>

          <div className="admin-report-description">
            <span>What the player told us</span>
            <p>{active.description}</p>
          </div>

          <dl className="admin-report-facts">
            <div>
              <dt>Submitted</dt>
              <dd>{formatDateTime(active.createdAt)}</dd>
            </div>
            <div>
              <dt>Source</dt>
              <dd>{humanize(active.source)}</dd>
            </div>
            <div>
              <dt>Assigned to</dt>
              <dd>{active.assignedTo ?? "Unassigned"}</dd>
            </div>
            <div>
              <dt>Last updated</dt>
              <dd>{formatDateTime(active.updatedAt)}</dd>
            </div>
          </dl>

          {active.resolutionNote ? (
            <div className="admin-resolution-note">
              <strong>Player-facing response</strong>
              <p>{active.resolutionNote}</p>
            </div>
          ) : null}
          {active.adminNote ? (
            <div className="admin-support-internal-note">
              <strong>Private admin note</strong>
              <p>{active.adminNote}</p>
            </div>
          ) : null}

          <div className="admin-report-actions admin-support-actions">
            {active.status === "OPEN" ? (
              <button
                className="admin-primary-button"
                disabled={submitting !== null}
                onClick={() => onAction(active, "START")}
                type="button"
              >
                Start handling
              </button>
            ) : null}
            {["OPEN", "IN_PROGRESS"].includes(active.status) ? (
              <>
                <button
                  className={
                    active.status === "OPEN"
                      ? "admin-secondary-button"
                      : "admin-primary-button"
                  }
                  disabled={submitting !== null}
                  onClick={() => onAction(active, "RESOLVE")}
                  type="button"
                >
                  Resolve
                </button>
                <button
                  className="admin-text-danger"
                  disabled={submitting !== null}
                  onClick={() => onAction(active, "DUPLICATE")}
                  type="button"
                >
                  Duplicate
                </button>
              </>
            ) : active.status === "RESOLVED" ? (
              <>
                <button
                  className="admin-secondary-button"
                  disabled={submitting !== null}
                  onClick={() => onAction(active, "REOPEN")}
                  type="button"
                >
                  Reopen
                </button>
                <button
                  className="admin-primary-button"
                  disabled={submitting !== null}
                  onClick={() => onAction(active, "CLOSE")}
                  type="button"
                >
                  Close ticket
                </button>
              </>
            ) : (
              <button
                className="admin-secondary-button"
                disabled={submitting !== null}
                onClick={() => onAction(active, "REOPEN")}
                type="button"
              >
                Reopen ticket
              </button>
            )}
          </div>

          <p className="admin-privacy-note">
            <AdminIcon name="lock" /> Internal notes stay private. Resolution
            messages may be sent to the player.
          </p>
        </section>
      ) : null}
    </div>
  );
}

function WaitlistSection({
  applicants,
}: {
  applicants: AdminWaitlistApplicant[];
}) {
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState<WaitlistStatus | "ALL">("ALL");
  const [interest, setInterest] = useState<WaitlistInterest | "ALL">("ALL");
  const [position, setPosition] = useState<WaitlistPosition | "ALL">("ALL");

  const filtered = useMemo(
    () =>
      filterAdminWaitlist(applicants, {
        query,
        status,
        interest,
        position,
      }),
    [applicants, interest, position, query, status],
  );

  const waitingCount = applicants.filter(
    (applicant) => applicant.status === "WAITING",
  ).length;
  const selectedCount = applicants.filter(
    (applicant) => applicant.status === "SELECTED",
  ).length;
  const onboardedCount = applicants.filter(
    (applicant) => applicant.status === "ONBOARDED",
  ).length;
  const subscriberCount = applicants.filter(isLaunchUpdatesSubscriber).length;

  return (
    <section className="admin-card admin-waitlist-card">
      <div className="admin-waitlist-head">
        <div>
          <span className="admin-eyebrow">Fieldrush signups</span>
          <h2>Interest</h2>
          <p>
            Launch updates and player applications share one list. Contact
            details stay inside the admin workspace.
          </p>
        </div>
        <span className="admin-waitlist-total">
          <strong>{applicants.length}</strong>
          <small>Signups loaded</small>
        </span>
      </div>

      <div className="admin-waitlist-summary" aria-label="Interest summary">
        <div>
          <span>Launch updates</span>
          <strong>{subscriberCount}</strong>
        </div>
        <div>
          <span>Waiting</span>
          <strong>{waitingCount}</strong>
        </div>
        <div>
          <span>Selected</span>
          <strong>{selectedCount}</strong>
        </div>
        <div>
          <span>Onboarded</span>
          <strong>{onboardedCount}</strong>
        </div>
      </div>

      <div className="admin-waitlist-controls">
        <label className="admin-search-field">
          <AdminIcon name="search" />
          <input
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Search name, email or phone"
            type="search"
            value={query}
          />
        </label>
        <select
          aria-label="Filter interest by status"
          onChange={(event) =>
            setStatus(event.target.value as WaitlistStatus | "ALL")
          }
          value={status}
        >
          <option value="ALL">All statuses</option>
          {WAITLIST_STATUSES.map((value) => (
            <option key={value} value={value}>
              {humanize(value)}
            </option>
          ))}
        </select>
        <select
          aria-label="Filter by interest"
          onChange={(event) =>
            setInterest(event.target.value as WaitlistInterest | "ALL")
          }
          value={interest}
        >
          <option value="ALL">All interests</option>
          {WAITLIST_INTERESTS.map((value) => (
            <option key={value} value={value}>
              {waitlistInterestLabel(value)}
            </option>
          ))}
        </select>
        <select
          aria-label="Filter interest by position"
          onChange={(event) =>
            setPosition(event.target.value as WaitlistPosition | "ALL")
          }
          value={position}
        >
          <option value="ALL">All positions</option>
          {WAITLIST_POSITIONS.map((value) => (
            <option key={value} value={value}>
              {humanize(value)}
            </option>
          ))}
        </select>
      </div>

      <div className="admin-table-count">
        {filtered.length} of {applicants.length} loaded signups
      </div>

      {filtered.length === 0 ? (
        <AdminEmpty
          detail={
            applicants.length === 0
              ? "Launch updates and player applications will appear here."
              : "Try changing the search or filters."
          }
          icon="waitlist"
          title={
            applicants.length === 0
              ? "No signups yet"
              : "No matching signups"
          }
        />
      ) : (
        <div className="admin-waitlist-table-wrap">
          <table className="admin-data-table admin-waitlist-table">
            <thead>
              <tr>
                <th>Person</th>
                <th>Contact</th>
                <th>Player details</th>
                <th>Interested in</th>
                <th>Launch updates</th>
                <th>Status</th>
                <th>Signed up</th>
              </tr>
            </thead>
            <tbody>
              {filtered.map((applicant) => (
                <tr key={applicant.id}>
                  <td>
                    <div className="admin-person-cell">
                      <div className="admin-subject-avatar small">
                        {initials(applicant.fullName ?? applicant.email)}
                      </div>
                      <div>
                        <strong>{applicant.fullName ?? applicant.email}</strong>
                        <small>{waitlistSourceLabel(applicant.source)}</small>
                        {applicant.signupPlacement ? (
                          <small>{waitlistPlacementLabel(applicant.signupPlacement)}</small>
                        ) : null}
                      </div>
                    </div>
                  </td>
                  <td>
                    <a href={`mailto:${applicant.email}`}>
                      {applicant.email}
                    </a>
                    {applicant.phone ? (
                      <a href={`tel:${applicant.phone}`}>{applicant.phone}</a>
                    ) : applicant.interest !== "LAUNCH_UPDATES" ? (
                      <small>Phone not provided</small>
                    ) : null}
                  </td>
                  <td>
                    {applicant.interest === "LAUNCH_UPDATES" ? (
                      <small>Not requested for email signup</small>
                    ) : (
                      <>
                        <strong>
                          {applicant.age !== null
                            ? `Age ${applicant.age}`
                            : "Age not recorded"}
                        </strong>
                        <small>
                          {applicant.preferredPosition
                            ? humanize(applicant.preferredPosition)
                            : "No preferred position"}
                        </small>
                      </>
                    )}
                  </td>
                  <td>{waitlistInterestLabel(applicant.interest)}</td>
                  <td>
                    {isLaunchUpdatesSubscriber(applicant) ? (
                      <>
                        <strong>Subscribed</strong>
                        <small>{formatDateTime(applicant.launchUpdatesConsentedAt)}</small>
                        {applicant.launchUpdatesConsentVersion ? (
                          <small>Consent {applicant.launchUpdatesConsentVersion}</small>
                        ) : null}
                      </>
                    ) : (
                      <small>No signup recorded</small>
                    )}
                  </td>
                  <td>
                    <StatusBadge status={applicant.status} />
                  </td>
                  <td>
                    <strong>{formatDateTime(applicant.createdAt)}</strong>
                    <small>{relativeTime(applicant.createdAt)}</small>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <p className="admin-waitlist-privacy">
        <AdminIcon name="lock" />
        This table contains private contact details. Send launch updates only
        to people with a recorded subscription.
      </p>
    </section>
  );
}

function ReportsSection({
  forfeits,
  reports,
  status,
  submitting,
  onStatus,
  onAction,
  onModerate,
  onReviewForfeit,
}: {
  forfeits: AdminForfeit[];
  reports: AdminReport[];
  status: string;
  submitting: string | null;
  onStatus: (status: string) => void;
  onAction: (
    report: AdminReport,
    action: "TRIAGE" | "INVESTIGATE" | "RESOLVE" | "DISMISS",
  ) => void;
  onModerate: (report: AdminReport) => void;
  onReviewForfeit: (
    decision: AdminForfeit,
    action: "CONFIRM" | "OVERTURN",
  ) => void;
}) {
  const [activeId, setActiveId] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const filtered = reports.filter((report) => {
    const needle = query.trim().toLowerCase();
    if (!needle) return true;
    return [report.subjectName, report.reporterName, report.category, report.description]
      .some((value) => value.toLowerCase().includes(needle));
  });
  const active = filtered.find((report) => report.id === activeId) ?? filtered[0] ?? null;

  useEffect(() => {
    if (active && activeId !== active.id) setActiveId(active.id);
  }, [active, activeId]);

  return (
    <div className="admin-section-stack">
      <ForfeitReviewQueue
        decisions={forfeits}
        submitting={submitting}
        onReview={onReviewForfeit}
      />
      <div className="admin-reports-layout">
      <section className="admin-card admin-report-inbox">
        <div className="admin-inbox-head">
          <div>
            <span className="admin-eyebrow">Private moderation queue</span>
            <h2>Player reports</h2>
          </div>
          <span>{filtered.length}</span>
        </div>
        <div className="admin-report-filters">
          <label className="admin-search-field">
            <AdminIcon name="search" />
            <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search reports" />
          </label>
          <select onChange={(event) => onStatus(event.target.value)} value={status}>
            <option value="OPEN">Open</option>
            <option value="TRIAGED">Triaged</option>
            <option value="INVESTIGATING">Investigating</option>
            <option value="ACTIONED">Actioned</option>
            <option value="RESOLVED">Resolved</option>
            <option value="DISMISSED">Dismissed</option>
            <option value="DUPLICATE">Duplicate</option>
            <option value="ALL">All reports</option>
          </select>
        </div>
        {filtered.length === 0 ? (
          <AdminEmpty icon="reports" title="No reports in this queue" detail="Try another status." />
        ) : (
          <div className="admin-report-list">
            {filtered.map((report) => (
              <button
                className={active?.id === report.id ? "active" : ""}
                key={report.id}
                onClick={() => setActiveId(report.id)}
                type="button"
              >
                <div className="admin-report-list-top">
                  <PriorityBadge priority={report.priority} />
                  <time>{relativeTime(report.createdAt)}</time>
                </div>
                <strong>{report.subjectName}</strong>
                <p>{humanize(report.category)}</p>
                <small>{truncate(report.description, 110)}</small>
                <span className="admin-report-state">{humanize(report.status)}</span>
              </button>
            ))}
          </div>
        )}
      </section>

      {active ? (
        <section className="admin-card admin-report-detail">
          <div className="admin-report-detail-head">
            <div>
              <PriorityBadge priority={active.priority} />
              <StatusBadge status={active.status} />
            </div>
            <span>Report #{active.id.slice(0, 8).toUpperCase()}</span>
          </div>
          <div className="admin-reported-subject">
            <div className="admin-subject-avatar">{initials(active.subjectName)}</div>
            <div>
              <span>Reported {active.subjectType.toLowerCase()}</span>
              <h2>{active.subjectName}</h2>
              <p>{humanize(active.category)}</p>
            </div>
            {active.subjectType !== "MATCH" ? (
              <button onClick={() => onModerate(active)} type="button">Review history</button>
            ) : null}
          </div>
          <div className="admin-report-description">
            <span>Reporter statement</span>
            <p>{active.description || "No written details were provided."}</p>
          </div>
          <dl className="admin-report-facts">
            <div><dt>Reported by</dt><dd>{active.reporterName}</dd></div>
            <div><dt>Source</dt><dd>{humanize(active.reporterRole)}</dd></div>
            <div><dt>Submitted</dt><dd>{formatDateTime(active.createdAt)}</dd></div>
            <div><dt>Assigned to</dt><dd>{active.assignedTo ?? "Unassigned"}</dd></div>
            {active.matchLabel ? <div><dt>Match</dt><dd>{active.matchLabel}</dd></div> : null}
            {active.replayOffsetSeconds !== null ? (
              <div><dt>Replay moment</dt><dd>{formatReplayOffset(active.replayOffsetSeconds)}</dd></div>
            ) : null}
          </dl>
          {active.resolutionNote ? (
            <div className="admin-resolution-note">
              <strong>Resolution note</strong>
              <p>{active.resolutionNote}</p>
            </div>
          ) : null}
          {!["ACTIONED", "RESOLVED", "DISMISSED", "DUPLICATE"].includes(active.status) ? (
            <div className="admin-report-actions">
              {active.status === "OPEN" ? (
                <button
                  className="admin-secondary-button"
                  disabled={submitting !== null}
                  onClick={() => onAction(active, "TRIAGE")}
                  type="button"
                >
                  Triage
                </button>
              ) : null}
              {active.status !== "INVESTIGATING" ? (
                <button
                  className="admin-secondary-button"
                  disabled={submitting !== null}
                  onClick={() => onAction(active, "INVESTIGATE")}
                  type="button"
                >
                  Investigate
                </button>
              ) : null}
              <button
                className="admin-primary-button"
                disabled={submitting !== null}
                onClick={() => onAction(active, "RESOLVE")}
                type="button"
              >
                Resolve
              </button>
              <button
                className="admin-text-danger"
                disabled={submitting !== null}
                onClick={() => onAction(active, "DISMISS")}
                type="button"
              >
                Dismiss
              </button>
            </div>
          ) : null}
          <p className="admin-privacy-note">
            <AdminIcon name="lock" /> Reporter identities and internal notes are never shown to the reported person.
          </p>
        </section>
      ) : null}
      </div>
    </div>
  );
}

function StaffSection({
  staff,
  submitting,
  onCreate,
}: {
  staff: AdminStaffMember[];
  submitting: string | null;
  onCreate: (input: {
    displayName: string;
    email: string;
    role: "admin" | "referee";
    existingStaffProfileId?: string;
  }) => Promise<boolean>;
}) {
  const [displayName, setDisplayName] = useState("");
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<"admin" | "referee">("referee");
  const [existingStaffProfileId, setExistingStaffProfileId] = useState<string | null>(null);

  function resetForm() {
    setDisplayName("");
    setEmail("");
    setRole("referee");
    setExistingStaffProfileId(null);
  }

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const created = await onCreate({
      displayName: displayName.trim(),
      email: email.trim().toLowerCase(),
      role,
      ...(existingStaffProfileId ? { existingStaffProfileId } : {}),
    });
    if (created) {
      resetForm();
    }
  }

  return (
    <div className="admin-staff-layout">
      <section className="admin-card admin-staff-create">
        <span className="admin-eyebrow">Controlled access</span>
        <h2>{existingStaffProfileId ? "Set up staff email" : "Add an admin or referee"}</h2>
        <p>
          Staff use a separate email-only account and a six-digit login code.
          Choose a dedicated email that is not already used by a player account.
          {existingStaffProfileId ? " Existing assignments and staff records will stay with this staff member." : ""}
        </p>
        <form onSubmit={(event) => void submit(event)}>
          <label>
            <span>Staff display name</span>
            <input
              autoComplete="name"
              disabled={existingStaffProfileId !== null}
              maxLength={50}
              onChange={(event) => setDisplayName(event.target.value)}
              placeholder="Mohamed Ali"
              required
              value={displayName}
            />
          </label>
          <label>
            <span>Dedicated staff email</span>
            <input
              aria-label="Dedicated staff email"
              type="email"
              autoComplete="email"
              onChange={(event) => setEmail(event.target.value)}
              placeholder="referee@example.com"
              required
              value={email}
            />
            <small>A staff account cannot sign in to the player app. Phone and Google sign-in are not used for staff.</small>
          </label>
          <fieldset>
            <legend>Access level</legend>
            <button
              className={role === "referee" ? "active" : ""}
              disabled={existingStaffProfileId !== null}
              onClick={() => setRole("referee")}
              type="button"
            >
              <AdminIcon name="referee" />
              <span><strong>Referee</strong><small>Assigned games and matchday controls</small></span>
            </button>
            <button
              className={role === "admin" ? "active" : ""}
              disabled={existingStaffProfileId !== null}
              onClick={() => setRole("admin")}
              type="button"
            >
              <AdminIcon name="shield" />
              <span><strong>Admin</strong><small>Full operations and moderation access</small></span>
            </button>
          </fieldset>
          <div className="admin-staff-warning">
            <AdminIcon name="lock" />
            <span><strong>Admin access is sensitive.</strong> Only grant it to people who should see private reports and change official records.</span>
          </div>
          <button
            className="admin-primary-button"
            disabled={submitting !== null || displayName.trim().length < 2 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())}
            type="submit"
          >
            {submitting === "create-staff" ? "Setting up staff…" : existingStaffProfileId ? "Set up email and send code" : `Add ${role} access`}
          </button>
          {existingStaffProfileId ? <button className="admin-secondary-button" onClick={resetForm} type="button">Cancel setup</button> : null}
        </form>
      </section>

      <section className="admin-card admin-staff-directory">
        <header>
          <div><span className="admin-eyebrow">Access directory</span><h2>Registered staff</h2></div>
          <b>{staff.filter((member) => member.isActive).length} active</b>
        </header>
        {staff.length === 0 ? (
          <AdminEmpty icon="referee" title="No staff accounts found" detail="Create a dedicated email account for an administrator or referee." />
        ) : (
          <div className="admin-staff-list">
            {staff.map((member) => (
              <article key={member.profileId}>
                <span className="admin-subject-avatar small">{initials(member.displayName)}</span>
                <div>
                  <strong>{member.displayName}</strong>
                  <small>{member.email ?? "Dedicated staff email required"} · Added {member.createdAt ? formatAdminDate(member.createdAt) : "date unavailable"}</small>
                  {member.phone ? <small>Previous staff contact: {member.phone}</small> : null}
                  {member.isActive && (member.setupRequired ?? !member.email) ? <button className="admin-secondary-button" type="button" disabled={submitting !== null} onClick={() => {
                    setExistingStaffProfileId(member.profileId);
                    setDisplayName(member.displayName);
                    setEmail(member.email ?? "");
                    setRole(member.role);
                  }}>Set up staff email for {member.displayName}</button> : null}
                </div>
                <span className={`admin-staff-role ${member.role}`}>{member.role}</span>
                <span className={member.isActive ? "admin-clear-status" : "admin-action-status"}>
                  {!member.isActive ? "Inactive" : (member.setupRequired ?? !member.email) ? "Setup required" : <><i /> Active</>}
                </span>
              </article>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}

function PeopleSection({
  subjects,
  onModerate,
  onRevoke,
}: {
  subjects: FlaggedSubject[];
  onModerate: (subject: FlaggedSubject) => void;
  onRevoke: (subject: FlaggedSubject, action: ActiveModerationAction) => void;
}) {
  const router = useRouter();
  const [query, setQuery] = useState("");
  const [type, setType] = useState("ALL");
  const filtered = subjects.filter((subject) => {
    if (type !== "ALL" && subject.subjectType !== type) return false;
    const needle = query.trim().toLowerCase();
    if (!needle) return true;
    return [subject.name, subject.username ?? ""].some((value) => value.toLowerCase().includes(needle));
  });

  return (
    <section className="admin-card admin-people-card">
      <div className="admin-people-head">
        <div>
          <span className="admin-eyebrow">Risk signals, not verdicts</span>
          <h2>Players & clans</h2>
          <p>Flagged subjects rank first, and search covers the full directory. Reports alone never trigger a ban.</p>
        </div>
        <div className="admin-people-controls">
          <label className="admin-search-field">
            <AdminIcon name="search" />
            <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search a player or clan" />
          </label>
          <select value={type} onChange={(event) => setType(event.target.value)}>
            <option value="ALL">Players and clans</option>
            <option value="PLAYER">Players</option>
            <option value="CLAN">Clans</option>
            <option value="REFEREE">Referees</option>
          </select>
        </div>
      </div>
      {filtered.length === 0 ? (
        <AdminEmpty icon="people" title="No matching players or clans" detail="Try a different name or subject type." />
      ) : (
        <div className="admin-people-table-wrap">
          <table className="admin-data-table admin-people-table">
            <thead>
              <tr>
                <th>Player or clan</th>
                <th>Open</th>
                <th>Distinct reporters · 30d</th>
                <th>Actioned</th>
                <th>Rate</th>
                <th>Current status</th>
                <th aria-label="Actions" />
              </tr>
            </thead>
            <tbody>
              {filtered.map((subject, index) => (
                <tr
                  className="admin-clickable-row"
                  key={`${subject.subjectType}-${subject.subjectId}`}
                  onClick={() => router.push(`/admin/people/${subject.subjectType.toLowerCase()}/${subject.subjectId}`)}
                  onKeyDown={(event) => {
                    if (event.key === "Enter" || event.key === " ") {
                      event.preventDefault();
                      router.push(`/admin/people/${subject.subjectType.toLowerCase()}/${subject.subjectId}`);
                    }
                  }}
                  tabIndex={0}
                >
                  <td>
                    <div className="admin-person-cell">
                      <span className="admin-rank">#{index + 1}</span>
                      <div className="admin-subject-avatar small">{initials(subject.name)}</div>
                      <div>
                        <strong>{subject.name}</strong>
                        <small>{subject.username ? `@${subject.username.replace(/^@/, "")}` : humanize(subject.subjectType)}</small>
                      </div>
                    </div>
                  </td>
                  <td>
                    <span className={subject.highPriorityReports > 0 ? "admin-number-danger" : ""}>
                      {subject.openReports}
                    </span>
                  </td>
                  <td>{subject.distinctReporters30d}</td>
                  <td>{subject.actionedReports}</td>
                  <td>{subject.reportsPerTenAppearances === null ? "—" : `${subject.reportsPerTenAppearances.toFixed(1)} / 10`}</td>
                  <td>
                    {subject.activeAction ? (
                      <span className="admin-action-status">
                        {subject.activeActions.length > 1
                          ? `${subject.activeActions.length} active actions`
                          : humanize(subject.activeAction)}
                        {subject.activeActionEndsAt ? <small>until {formatAdminDate(subject.activeActionEndsAt)}</small> : null}
                      </span>
                    ) : (
                      <span className="admin-clear-status"><i /> Clear</span>
                    )}
                  </td>
                  <td>
                    <div className="admin-row-actions">
                      {subject.activeActions[0] ? (
                        <button
                          className="admin-row-revoke"
                          onClick={(event) => {
                            event.stopPropagation();
                            onRevoke(subject, subject.activeActions[0]);
                          }}
                          type="button"
                        >
                          Revoke
                        </button>
                      ) : null}
                      <button className="admin-row-action" onClick={(event) => {
                        event.stopPropagation();
                        router.push(`/admin/people/${subject.subjectType.toLowerCase()}/${subject.subjectId}`);
                      }} type="button">
                        Full record <AdminIcon name="arrow" />
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

function AuditSection({ audit }: { audit: AuditItem[] }) {
  return (
    <section className="admin-card admin-audit-card">
      <div className="admin-audit-head">
        <div>
          <span className="admin-eyebrow">Immutable operations trail</span>
          <h2>Admin activity</h2>
          <p>Score corrections, cancellations, report decisions, warnings, bans and reversals.</p>
        </div>
        <span><AdminIcon name="lock" /> Admin only</span>
      </div>
      {audit.length === 0 ? (
        <AdminEmpty icon="audit" title="No admin activity yet" detail="Sensitive actions will be recorded here." />
      ) : (
        <div className="admin-full-audit-list">
          {audit.map((item) => (
            <article key={item.id}>
              <div className="admin-audit-icon"><AdminIcon name={auditIcon(item.action)} /></div>
              <div>
                <strong>{humanize(item.action)}</strong>
                <p>{item.detail || `${item.actor} updated ${item.target}.`}</p>
                <span>{item.actor} · {item.target}</span>
              </div>
              <time>{formatDateTime(item.createdAt)}</time>
            </article>
          ))}
        </div>
      )}
    </section>
  );
}

function SoloGameManagementDialog({
  dialog,
  fields,
  draft,
  error,
  onAddField,
  submitting,
  onClose,
  onCreate,
  onRemove,
}: {
  dialog: NonNullable<SoloGameDialog>;
  fields: AdminField[];
  draft: SoloGameDraft | null;
  error: string | null;
  onAddField: (draft: SoloGameDraft) => void;
  submitting: boolean;
  onClose: () => void;
  onCreate: (input: {
    minimumPlayers: number;
    fieldId: string;
    matchDate: string;
    kickoffTime: string;
    durationMinutes: number;
    priceUsd: string;
    ageLabel: string;
    highestDivision: number;
    lowestDivision: number;
    goalkeepersPerSide: number;
    defendersPerSide: number;
    attackersPerSide: number;
  }) => void;
  onRemove: (fixture: RefereeFixture, reason: string) => void;
}) {
  const [fieldId, setFieldId] = useState(dialog.kind === "create" ? dialog.fieldId ?? "" : "");
  const selectedField = fields.find((field) => field.id === fieldId && field.isActive && field.marketActive);
  const [matchDate, setMatchDate] = useState(draft?.matchDate ?? nextSoloMatchDate());
  const [kickoffTime, setKickoffTime] = useState(draft?.kickoffTime ?? "20:30");
  const [durationMinutes, setDurationMinutes] = useState(draft?.durationMinutes ?? 60);
  const [minimumPlayers, setMinimumPlayers] = useState(draft?.minimumPlayers ?? 10);
  const [priceUsd, setPriceUsd] = useState(draft?.priceUsd ?? "13.00");
  const [ageLabel, setAgeLabel] = useState(draft?.ageLabel ?? "18+");
  const [highestDivision, setHighestDivision] = useState(draft?.highestDivision ?? 1);
  const [lowestDivision, setLowestDivision] = useState(draft?.lowestDivision ?? 5);
  const [formation, setFormation] = useState<SoloFormation>(draft ? {
    goalkeepersPerSide: draft.goalkeepersPerSide, defendersPerSide: draft.defendersPerSide, attackersPerSide: draft.attackersPerSide,
  } : DEFAULT_SOLO_FORMATION);
  let validFormation = false;
  try { parseSoloFormation(formation); validFormation = true; } catch { /* Form remains unsaveable until valid. */ }
  const [reason, setReason] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const creating = dialog.kind === "create";
  const priceFils = /^\d{1,3}(?:\.\d{1,2})?$/.test(priceUsd.trim())
    ? Math.round(Number(priceUsd.trim()) * 1000) : null;
  const validPrice = priceFils !== null && (priceFils === 0 || priceFils >= 500 && priceFils <= 100_000);
  const createReady =
    !!selectedField &&
    matchDate.length === 10 &&
    /^(?:[01]\d|2[0-3]):[0-5]\d$/.test(kickoffTime) &&
    Number.isInteger(durationMinutes) && durationMinutes >= 30 && durationMinutes <= 180 &&
    validPrice &&
    ageLabel.trim().length >= 2 &&
    Number.isInteger(highestDivision) && highestDivision >= 1 && highestDivision <= 5 &&
    Number.isInteger(lowestDivision) && lowestDivision >= 1 && lowestDivision <= 5 &&
    highestDivision <= lowestDivision && validFormation &&
    Number.isInteger(minimumPlayers) && minimumPlayers >= 2 && minimumPlayers <= 14;
  const removeReady =
    reason.trim().length >= 8 &&
    confirmation.trim().toUpperCase() === "REMOVE";

  return (
    <AdminModal onClose={onClose}>
      <div className={`admin-modal-icon ${creating ? "good" : "danger"}`}>
        <AdminIcon name={creating ? "games" : "cancel"} />
      </div>
      <span className="admin-eyebrow">
        {creating ? "Open Queue schedule" : "Permanent audit record"}
      </span>
      <h2>{creating ? "Create a solo game" : "Remove this empty game?"}</h2>
      {error ? <div role="alert" className="admin-banner danger">{error}</div> : null}
      {creating ? (
        <>
          <p className="admin-modal-lead">
            The game opens for player bookings as soon as it is created.
          </p>
          <div className="admin-modal-warning">
            Up to 7-a-side · Any day · The saved field determines the city and local time. Games at the same pitch cannot overlap. Prices are in USD.
          </div>
          <label className="admin-modal-field">
            <span>Field / pitch <span aria-hidden="true">*</span></span>
            <select required value={fieldId} onChange={(event) => setFieldId(event.target.value)}>
              <option value="">Select a saved field</option>
              {fields.filter((field) => field.isActive && field.marketActive).map((field) => (
                <option key={field.id} value={field.id}>{field.name} · {field.marketCityName}</option>
              ))}
            </select>
            <small>{selectedField ? `${selectedField.address}, ${selectedField.city}, ${selectedField.state}` : "Players will see this field’s address and map pin in the app."}</small>
          </label>
          <button className="admin-secondary-button" type="button" disabled={submitting} onClick={() => onAddField({ matchDate, kickoffTime, durationMinutes, minimumPlayers, priceUsd, ageLabel, highestDivision, lowestDivision, ...formation })}>+ Add a new field</button>
          <div className="admin-solo-game-fields">
            <label className="admin-modal-field">
              <span>Match date</span>
              <input
                onChange={(event) => setMatchDate(event.target.value)}
                type="date"
                value={matchDate}
              />
              <small>Choose any future date, including weekends.</small>
            </label>
            <label className="admin-modal-field">
              <span>Kickoff time</span>
              <input type="time" value={kickoffTime} onChange={(event) => setKickoffTime(event.target.value)} />
              <small>{selectedField ? `${selectedField.marketCityName} · ${selectedField.marketTimezone}` : "Choose a field to set the local timezone."}</small>
            </label>
            <label className="admin-modal-field">
              <span>Duration (minutes)</span>
              <input type="number" min={30} max={180} step={1} value={durationMinutes || ""} onChange={(event) => setDurationMinutes(Number(event.target.value))} />
              <small>30–180 minutes. Default: 60 minutes.</small>
            </label>
            <label className="admin-modal-field">
              <span>Price per player (USD)</span>
              <input
                type="number"
                min={0}
                max={100}
                step="0.01"
                inputMode="decimal"
                aria-invalid={!validPrice}
                onChange={(event) => setPriceUsd(event.target.value)}
                placeholder="13.00"
                value={priceUsd}
              />
              <small>Defaults to $13.00. Use $0 for free, or $0.50–$100 with up to 2 decimals.</small>
            </label>
            <label className="admin-modal-field">
              <span>Highest division</span>
              <select value={highestDivision} onChange={(event) => setHighestDivision(Number(event.target.value))}>
                {[1, 2, 3, 4, 5].map((division) => (
                  <option key={division} value={division}>Division {division}</option>
                ))}
              </select>
              <small>Division 1 is the highest competitive division.</small>
            </label>
            <label className="admin-modal-field">
              <span>Lowest division</span>
              <select value={lowestDivision} onChange={(event) => setLowestDivision(Number(event.target.value))}>
                {[1, 2, 3, 4, 5].map((division) => (
                  <option key={division} value={division}>Division {division}</option>
                ))}
              </select>
              <small>Placement players (fewer than 2 matches) can only book unrestricted Division 1–5 games.</small>
            </label>
          </div>
          <label className="admin-modal-field">
            <span>Age label</span>
            <input
              maxLength={40}
              onChange={(event) => setAgeLabel(event.target.value)}
              placeholder="18+"
              value={ageLabel}
            />
          </label>
          <SoloFormationFields value={formation} onChange={setFormation} disabled={submitting} />
          <label className="admin-modal-field">
            <span>Minimum players (both teams)</span>
            <input required type="number" min={2} max={14} step={1} value={minimumPlayers || ""} onChange={(event) => setMinimumPlayers(Number(event.target.value))} />
            <small>2–14 players total. 2 allows 1v1; odd counts allow uneven teams. Booking capacity stays 14. At kickoff and during play, at least this many actual players and one on each team are required.</small>
          </label>
          <p className="admin-detail-hint">Formation can be changed from the game overview until its first booking or payment attempt.</p>
        </>
      ) : (
        <>
          <p className="admin-modal-lead">
            {dialog.fixture.homeClan.tag} vs {dialog.fixture.awayClan.tag} ·{" "}
            {formatAdminDate(dialog.fixture.matchDate)}
          </p>
          <div className="admin-modal-warning danger">
            Removal is only allowed while this future game is open and has no booking or matchday history.
            If anyone has joined, cancel the game instead so refunds and player records are preserved.
          </div>
          <label className="admin-modal-field">
            <span>Reason for removal</span>
            <textarea
              maxLength={1000}
              onChange={(event) => setReason(event.target.value)}
              placeholder="Why was this empty game created by mistake?"
              rows={4}
              value={reason}
            />
            <small>{reason.trim().length}/8 minimum</small>
          </label>
          <label className="admin-modal-field">
            <span>Type REMOVE to confirm</span>
            <input
              onChange={(event) => setConfirmation(event.target.value)}
              placeholder="REMOVE"
              value={confirmation}
            />
          </label>
        </>
      )}
      <div className="admin-modal-actions">
        <button
          className="admin-secondary-button"
          disabled={submitting}
          onClick={onClose}
          type="button"
        >
          Go back
        </button>
        <button
          className={creating ? "admin-primary-button" : "admin-danger-solid"}
          disabled={submitting || (creating ? !createReady : !removeReady)}
          onClick={() => {
            if (creating) {
              onCreate({
                fieldId,
                matchDate,
                kickoffTime,
                durationMinutes,
                minimumPlayers,
                priceUsd: priceUsd.trim(),
                ageLabel: ageLabel.trim(),
                highestDivision,
                lowestDivision,
                ...formation,
              });
            } else {
              onRemove(dialog.fixture, reason.trim());
            }
          }}
          type="button"
        >
          {submitting
            ? "Saving…"
            : creating
              ? "Create and open game"
              : "Remove empty game"}
        </button>
      </div>
    </AdminModal>
  );
}

function GameActionDialog({
  dialog,
  submitting,
  onClose,
  onSubmit,
}: {
  dialog: NonNullable<GameDialog>;
  submitting: boolean;
  onClose: () => void;
  onSubmit: (body: JsonRecord, successMessage: string) => void;
}) {
  const [reason, setReason] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [homeScore, setHomeScore] = useState(String(dialog.fixture.homeScore ?? 0));
  const [awayScore, setAwayScore] = useState(String(dialog.fixture.awayScore ?? 0));
  const isCancel = dialog.kind === "cancel";
  const validScores = Number.isInteger(Number(homeScore)) && Number(homeScore) >= 0 &&
    Number.isInteger(Number(awayScore)) && Number(awayScore) >= 0;
  const canSubmit = reason.trim().length >= 8 &&
    (!isCancel || confirmation.trim().toUpperCase() === "CANCEL") &&
    (isCancel || validScores);

  return (
    <AdminModal onClose={onClose}>
      <div className={`admin-modal-icon ${isCancel ? "danger" : "warning"}`}>
        <AdminIcon name={isCancel ? "cancel" : "edit"} />
      </div>
      <span className="admin-eyebrow">Permanent audit record</span>
      <h2>{isCancel ? "Cancel this game?" : "Correct the final score"}</h2>
      <p className="admin-modal-lead">
        {dialog.fixture.homeClan.tag} vs {dialog.fixture.awayClan.tag} · {formatAdminDate(dialog.fixture.matchDate)}
      </p>
      {!isCancel && dialog.fixture.matchKind === "SOLO" && dialog.fixture.ratingPolicyId !== "field-sr-season0-v2" ? (
        <div className="admin-modal-warning">Legacy rating awards are fixed. Once SR has been awarded, a score correction must keep the same result and rating margin multiplier. Changing either requires a separately reviewed rating migration; it cannot silently retain the old SR. Use live “Undo goal” before finalizing a recording mistake.</div>
      ) : null}
      {isCancel ? (
        <div className="admin-modal-warning">
          Scheduled participants will be notified. Solo-game payments follow the admin cancellation refund policy.
        </div>
      ) : (
        <div className="admin-score-inputs">
          <label>
            <span>{dialog.fixture.homeClan.tag}</span>
            <input min="0" type="number" value={homeScore} onChange={(event) => setHomeScore(event.target.value)} />
          </label>
          <b>–</b>
          <label>
            <span>{dialog.fixture.awayClan.tag}</span>
            <input min="0" type="number" value={awayScore} onChange={(event) => setAwayScore(event.target.value)} />
          </label>
        </div>
      )}
      <label className="admin-modal-field">
        <span>Reason for this change</span>
        <textarea
          maxLength={1000}
          onChange={(event) => setReason(event.target.value)}
          placeholder={isCancel ? "Why is this game being cancelled?" : "What was incorrect about the recorded score?"}
          rows={4}
          value={reason}
        />
        <small>{reason.trim().length}/8 minimum</small>
      </label>
      {isCancel ? (
        <label className="admin-modal-field">
          <span>Type CANCEL to confirm</span>
          <input value={confirmation} onChange={(event) => setConfirmation(event.target.value)} placeholder="CANCEL" />
        </label>
      ) : null}
      <div className="admin-modal-actions">
        <button className="admin-secondary-button" disabled={submitting} onClick={onClose} type="button">Keep game</button>
        <button
          className={isCancel ? "admin-danger-solid" : "admin-primary-button"}
          disabled={submitting || !canSubmit}
          onClick={() =>
            onSubmit(
              isCancel
                ? { action: "cancel", reason: reason.trim() }
                : {
                    action: "override_score",
                    homeScore: Number(homeScore),
                    awayScore: Number(awayScore),
                    reason: reason.trim(),
                  },
              isCancel ? "Game cancelled and participants updated." : "Score corrected and audit record saved.",
            )
          }
          type="button"
        >
          {submitting ? "Saving…" : isCancel ? "Cancel game" : "Save corrected score"}
        </button>
      </div>
    </AdminModal>
  );
}

function ReportResolutionDialog({
  dialog,
  submitting,
  onClose,
  onSubmit,
}: {
  dialog: NonNullable<ReportDialog>;
  submitting: boolean;
  onClose: () => void;
  onSubmit: (note: string) => void;
}) {
  const [note, setNote] = useState("");
  const dismissing = dialog.action === "DISMISS";
  return (
    <AdminModal onClose={onClose}>
      <div className={`admin-modal-icon ${dismissing ? "neutral" : "good"}`}>
        <AdminIcon name={dismissing ? "dismiss" : "check"} />
      </div>
      <span className="admin-eyebrow">Report decision</span>
      <h2>{dismissing ? "Dismiss this report?" : "Resolve this report"}</h2>
      <p className="admin-modal-lead">{dialog.report.subjectName} · {humanize(dialog.report.category)}</p>
      <label className="admin-modal-field">
        <span>{dismissing ? "Why is it being dismissed?" : "Resolution note"}</span>
        <textarea
          maxLength={2000}
          onChange={(event) => setNote(event.target.value)}
          placeholder="Write a clear internal decision note…"
          rows={5}
          value={note}
        />
      </label>
      <div className="admin-modal-actions">
        <button className="admin-secondary-button" disabled={submitting} onClick={onClose} type="button">Go back</button>
        <button
          className={dismissing ? "admin-danger-button" : "admin-primary-button"}
          disabled={submitting || note.trim().length < 8}
          onClick={() => onSubmit(note.trim())}
          type="button"
        >
          {submitting ? "Saving…" : dismissing ? "Dismiss report" : "Resolve report"}
        </button>
      </div>
    </AdminModal>
  );
}

function SupportActionDialog({
  dialog,
  submitting,
  onClose,
  onSubmit,
}: {
  dialog: NonNullable<SupportDialog>;
  submitting: boolean;
  onClose: () => void;
  onSubmit: (input: {
    resolutionNote?: string;
    adminNote?: string;
  }) => void;
}) {
  const resolving = dialog.action === "RESOLVE";
  const closing = dialog.action === "CLOSE";
  const duplicate = dialog.action === "DUPLICATE";
  const [resolutionNote, setResolutionNote] = useState(
    duplicate
      ? "We closed this request because it duplicates another support ticket."
      : "",
  );
  const [adminNote, setAdminNote] = useState("");
  const canSubmit = resolving
    ? resolutionNote.trim().length >= 8
    : adminNote.trim().length >= 8;

  return (
    <AdminModal onClose={onClose}>
      <div
        className={`admin-modal-icon ${
          resolving ? "good" : duplicate ? "neutral" : "warning"
        }`}
      >
        <AdminIcon
          name={resolving ? "check" : duplicate ? "dismiss" : "support"}
        />
      </div>
      <span className="admin-eyebrow">
        {dialog.ticket.reference} · private support workflow
      </span>
      <h2>
        {resolving
          ? "Resolve this support ticket"
          : duplicate
            ? "Mark this as a duplicate?"
            : "Close this ticket?"}
      </h2>
      <p className="admin-modal-lead">
        {dialog.ticket.requesterName} · {humanize(dialog.ticket.category)}
      </p>

      {!closing ? (
        <label className="admin-modal-field">
          <span>Message for the player</span>
          <textarea
            maxLength={2000}
            onChange={(event) => setResolutionNote(event.target.value)}
            placeholder="Explain clearly what was done and what happens next…"
            rows={4}
            value={resolutionNote}
          />
          <small>
            {resolving
              ? "This may be delivered to the player's private notifications."
              : "The player will see why this request was closed."}
          </small>
        </label>
      ) : null}

      <label className="admin-modal-field">
        <span>
          {resolving ? "Private admin note · optional" : "Private admin note"}
        </span>
        <textarea
          maxLength={2000}
          onChange={(event) => setAdminNote(event.target.value)}
          placeholder={
            resolving
              ? "Add evidence or operational context that should stay internal…"
              : "Explain the closure or identify the original ticket…"
          }
          rows={4}
          value={adminNote}
        />
      </label>

      <div className="admin-modal-warning">
        The transition, admin identity, before/after state, and private note are
        permanently audited.
      </div>
      <div className="admin-modal-actions">
        <button
          className="admin-secondary-button"
          disabled={submitting}
          onClick={onClose}
          type="button"
        >
          Go back
        </button>
        <button
          className={
            resolving ? "admin-primary-button" : "admin-danger-button"
          }
          disabled={submitting || !canSubmit}
          onClick={() =>
            onSubmit({
              resolutionNote: resolutionNote.trim() || undefined,
              adminNote: adminNote.trim() || undefined,
            })
          }
          type="button"
        >
          {submitting
            ? "Saving…"
            : resolving
              ? "Resolve ticket"
              : duplicate
                ? "Mark duplicate"
                : "Close ticket"}
        </button>
      </div>
    </AdminModal>
  );
}

function ForfeitReviewConfirmationDialog({
  dialog,
  submitting,
  onClose,
  onSubmit,
}: {
  dialog: NonNullable<ForfeitReviewDialog>;
  submitting: boolean;
  onClose: () => void;
  onSubmit: (note: string) => void;
}) {
  const [note, setNote] = useState("");
  const confirming = dialog.action === "CONFIRM";
  const home = forfeitHomeClan(dialog.decision);
  const away = forfeitAwayClan(dialog.decision);
  const canSubmit = note.trim().length >= 10;

  return (
    <AdminModal onClose={onClose} wide>
      <div className={`admin-modal-icon ${confirming ? "good" : "warning"}`}>
        <AdminIcon name={confirming ? "check" : "dismiss"} />
      </div>
      <span className="admin-eyebrow">Forfeit review · permanent audit record</span>
      <h2>{confirming ? "Confirm the provisional 3–0?" : "Overturn the provisional 3–0?"}</h2>
      <p className="admin-modal-lead">
        {home.name} vs {away.name} · {dialog.decision.matchDate
          ? formatAdminDate(dialog.decision.matchDate)
          : "Date unavailable"}
      </p>

      <div className={forfeitStyles.modalScoreComparison}>
        <div>
          <span>Score when stopped</span>
          <strong>{formatPriorScore(dialog.decision)}</strong>
        </div>
        <AdminIcon name="arrow" />
        <div>
          <span>Provisional</span>
          <strong>{dialog.decision.provisionalHomeScore}–{dialog.decision.provisionalAwayScore}</strong>
        </div>
        <div>
          <span>Awarded to</span>
          <strong>{dialog.decision.awardedClan.name}</strong>
        </div>
      </div>

      <div className={`admin-modal-warning ${confirming ? "" : "danger"}`}>
        {confirming
          ? "This makes the 3–0 official and allows normal match finalization and rating updates. The source report remains available for separate moderation review."
          : `This removes the provisional forfeit and restores ${formatPriorScore(dialog.decision)} as the recorded score. No rating change will be applied from the overturned forfeit.`}
      </div>

      <label className="admin-modal-field">
        <span>{confirming ? "Why is the forfeit being upheld?" : "Why is the forfeit being overturned?"}</span>
        <textarea
          autoFocus
          maxLength={2000}
          onChange={(event) => setNote(event.target.value)}
          placeholder="Record the evidence reviewed and the reason for this decision…"
          rows={5}
          value={note}
        />
        <small>{note.trim().length}/10 minimum</small>
      </label>

      <div className="admin-modal-actions">
        <button className="admin-secondary-button" disabled={submitting} onClick={onClose} type="button">
          Keep reviewing
        </button>
        <button
          className={confirming ? "admin-primary-button" : "admin-danger-solid"}
          disabled={submitting || !canSubmit}
          onClick={() => onSubmit(note.trim())}
          type="button"
        >
          {submitting
            ? "Saving decision…"
            : confirming
              ? "Confirm official 3–0"
              : "Overturn and restore score"}
        </button>
      </div>
    </AdminModal>
  );
}

function ModerationDialog({
  subject,
  reports,
  submitting,
  onClose,
  onRevoke,
  onSubmit,
}: {
  subject: FlaggedSubject;
  reports: AdminReport[];
  submitting: boolean;
  onClose: () => void;
  onRevoke: (action: ActiveModerationAction) => void;
  onSubmit: (input: {
    subject: FlaggedSubject;
    actionType: ModerationActionType;
    reasonCode: string;
    note: string;
    endsAt: string | null;
    reportId: string | null;
  }) => void;
}) {
  const allowed = subject.subjectType === "CLAN"
    ? ["WARNING", "CLAN_SCHEDULING_FREEZE", "CLAN_DISQUALIFICATION"] as ModerationActionType[]
    : ["WARNING", "PLAY_SUSPENSION", "ACCOUNT_SUSPENSION", "PERMANENT_BAN"] as ModerationActionType[];
  const [actionType, setActionType] = useState<ModerationActionType>(allowed[0]);
  const [reasonCode, setReasonCode] = useState("CODE_OF_CONDUCT");
  const [note, setNote] = useState("");
  const [endsAt, setEndsAt] = useState("");
  const [reportId, setReportId] = useState("");
  const isPermanent = ["PERMANENT_BAN", "CLAN_DISQUALIFICATION"].includes(actionType);
  const needsEnd = ["PLAY_SUSPENSION", "ACCOUNT_SUSPENSION", "CLAN_SCHEDULING_FREEZE"].includes(actionType);
  const matchingReports = reports.filter(
    (report) => report.subjectId === subject.subjectId && report.subjectType === subject.subjectType,
  );
  const canSubmit = note.trim().length >= 10 && reasonCode.length > 0 && (!needsEnd || endsAt.length > 0);

  return (
    <AdminModal wide onClose={onClose}>
      <div className="admin-moderation-head">
        <div className="admin-subject-avatar">{initials(subject.name)}</div>
        <div>
          <span className="admin-eyebrow">Moderation review</span>
          <h2>{subject.name}</h2>
          <p>{subject.openReports} open · {subject.distinctReporters30d} distinct reporters in 30 days</p>
        </div>
      </div>
      <div className="admin-risk-summary">
        <div><strong>{subject.lifetimeReports}</strong><span>Lifetime reports</span></div>
        <div><strong>{subject.highPriorityReports}</strong><span>High priority</span></div>
        <div><strong>{subject.actionedReports}</strong><span>Actioned</span></div>
        <div><strong>{subject.activeAction ? humanize(subject.activeAction) : "Clear"}</strong><span>Current state</span></div>
      </div>
      {subject.activeActions.length > 0 ? (
        <section className="admin-active-restrictions">
          <div className="admin-active-restrictions-head">
            <div>
              <AdminIcon name="lock" />
              <span>Active moderation actions</span>
            </div>
            <small>{subject.activeActions.length} active</small>
          </div>
          <div className="admin-active-restriction-list">
            {subject.activeActions.map((action) => (
              <article key={action.id}>
                <div className="admin-active-restriction-icon">
                  <AdminIcon name="shield" />
                </div>
                <div>
                  <strong>{activeActionLabel(action)}</strong>
                  <p>{action.userMessage || humanize(action.reasonCode)}</p>
                  <span>
                    Started {formatDateTime(action.startsAt)}
                    {action.endsAt ? ` · Ends ${formatDateTime(action.endsAt)}` : " · No expiry"}
                    {action.issuedBy ? ` · By ${action.issuedBy}` : ""}
                  </span>
                </div>
                <button disabled={submitting} onClick={() => onRevoke(action)} type="button">
                  Revoke restriction
                </button>
              </article>
            ))}
          </div>
        </section>
      ) : (
        <div className="admin-no-active-restrictions">
          <AdminIcon name="check" /> No active suspensions, bans or scheduling freezes.
        </div>
      )}
      <div className="admin-moderation-grid">
        <label className="admin-modal-field">
          <span>Action</span>
          <select value={actionType} onChange={(event) => setActionType(event.target.value as ModerationActionType)}>
            {allowed.map((action) => <option key={action} value={action}>{moderationActionLabel(action)}</option>)}
          </select>
        </label>
        <label className="admin-modal-field">
          <span>Reason</span>
          <select value={reasonCode} onChange={(event) => setReasonCode(event.target.value)}>
            <option value="CODE_OF_CONDUCT">Code of conduct</option>
            <option value="ABUSIVE_BEHAVIOUR">Abusive behaviour</option>
            <option value="DANGEROUS_PLAY">Dangerous play</option>
            <option value="CHEATING_OR_FRAUD">Cheating or fraud</option>
            <option value="REPEATED_NO_SHOW">Repeated no-show</option>
            <option value="SAFETY">Safety concern</option>
            <option value="OTHER">Other</option>
          </select>
        </label>
        {needsEnd ? (
          <label className="admin-modal-field">
            <span>Ends at</span>
            <input type="datetime-local" value={endsAt} onChange={(event) => setEndsAt(event.target.value)} />
          </label>
        ) : null}
        <label className="admin-modal-field">
          <span>Related report</span>
          <select value={reportId} onChange={(event) => setReportId(event.target.value)}>
            <option value="">No single report</option>
            {matchingReports.map((report) => (
              <option key={report.id} value={report.id}>
                {humanize(report.category)} · {report.id.slice(0, 8)}
              </option>
            ))}
          </select>
        </label>
      </div>
      <label className="admin-modal-field">
        <span>Internal reason and evidence</span>
        <textarea value={note} onChange={(event) => setNote(event.target.value)} rows={5} maxLength={2000} placeholder="Explain why this action is proportionate…" />
      </label>
      {isPermanent ? (
        <div className="admin-modal-warning danger">
          This is a permanent action. It should be used only after evidence review and will be highlighted in the audit log.
        </div>
      ) : null}
      <div className="admin-modal-actions">
        <button className="admin-secondary-button" disabled={submitting} onClick={onClose} type="button">Cancel</button>
        <button
          className={isPermanent ? "admin-danger-solid" : "admin-primary-button"}
          disabled={submitting || !canSubmit}
          onClick={() => onSubmit({
            subject,
            actionType,
            reasonCode,
            note: note.trim(),
            endsAt: endsAt ? new Date(endsAt).toISOString() : null,
            reportId: reportId || null,
          })}
          type="button"
        >
          {submitting ? "Issuing…" : `Issue ${moderationActionLabel(actionType).toLowerCase()}`}
        </button>
      </div>
    </AdminModal>
  );
}

function RevokeRestrictionDialog({
  dialog,
  submitting,
  onClose,
  onSubmit,
}: {
  dialog: NonNullable<RevokeDialog>;
  submitting: boolean;
  onClose: () => void;
  onSubmit: (reason: string) => void;
}) {
  const [reason, setReason] = useState("");
  const action = dialog.action;
  return (
    <AdminModal onClose={onClose}>
      <div className="admin-modal-icon warning">
        <AdminIcon name="shield" />
      </div>
      <span className="admin-eyebrow">Reversible discipline</span>
      <h2>Revoke this restriction?</h2>
      <p className="admin-modal-lead">
        {activeActionLabel(action)} for {dialog.subject.name}
      </p>
      <div className="admin-revoke-summary">
        <div>
          <span>Reason</span>
          <strong>{humanize(action.reasonCode)}</strong>
        </div>
        <div>
          <span>Restriction</span>
          <strong>{action.restrictionScope ? humanize(action.restrictionScope) : "Account record"}</strong>
        </div>
        <p>{action.userMessage || "No public-facing message was recorded."}</p>
        <small>
          Issued by {action.issuedBy || "Admin"} · {formatDateTime(action.startsAt)}
          {action.endsAt ? ` · Ends ${formatDateTime(action.endsAt)}` : " · No expiry"}
        </small>
      </div>
      <div className="admin-modal-warning">
        Revoking takes effect immediately. The original action remains in the audit log together with this reason.
      </div>
      <label className="admin-modal-field">
        <span>Why is this restriction being revoked?</span>
        <textarea
          maxLength={1000}
          onChange={(event) => setReason(event.target.value)}
          placeholder="Explain what changed or why the action is no longer appropriate…"
          rows={4}
          value={reason}
        />
        <small>{reason.trim().length}/8 minimum</small>
      </label>
      <div className="admin-modal-actions">
        <button className="admin-secondary-button" disabled={submitting} onClick={onClose} type="button">
          Keep restriction
        </button>
        <button
          className="admin-danger-button"
          disabled={submitting || reason.trim().length < 8}
          onClick={() => onSubmit(reason.trim())}
          type="button"
        >
          {submitting ? "Revoking…" : "Revoke restriction"}
        </button>
      </div>
    </AdminModal>
  );
}

function AdminModal({
  children,
  onClose,
  wide = false,
}: {
  children: React.ReactNode;
  onClose: () => void;
  wide?: boolean;
}) {
  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onClose]);

  return (
    <div className="admin-modal-backdrop" onMouseDown={onClose} role="presentation">
      <section
        aria-modal="true"
        className={`admin-modal ${wide ? "wide" : ""}`}
        onMouseDown={(event) => event.stopPropagation()}
        role="dialog"
      >
        <button className="admin-modal-close" onClick={onClose} title="Close" type="button">
          <AdminIcon name="close" />
        </button>
        {children}
      </section>
    </div>
  );
}

function AdminCardHeader({
  eyebrow,
  title,
  actionLabel,
  onAction,
}: {
  eyebrow: string;
  title: string;
  actionLabel: string;
  onAction: () => void;
}) {
  return (
    <header className="admin-card-head">
      <div><span>{eyebrow}</span><h2>{title}</h2></div>
      <button onClick={onAction} type="button">{actionLabel} <AdminIcon name="arrow" /></button>
    </header>
  );
}

function AdminEmpty({
  icon,
  title,
  detail,
}: {
  icon: AdminIconName;
  title: string;
  detail: string;
}) {
  return (
    <div className="admin-empty-state">
      <span><AdminIcon name={icon} /></span>
      <strong>{title}</strong>
      <p>{detail}</p>
    </div>
  );
}

function StatusBadge({ status }: { status: string }) {
  return <span className={`admin-status-badge ${status.toLowerCase()}`}>{humanize(status)}</span>;
}

function PriorityBadge({ priority }: { priority: string }) {
  return <span className={`admin-priority-badge ${priority.toLowerCase()}`}>{humanize(priority)}</span>;
}

function CompactAuditList({ items }: { items: AuditItem[] }) {
  if (items.length === 0) {
    return <AdminEmpty icon="audit" title="No recent changes" detail="Admin actions will be shown here." />;
  }
  return (
    <div className="admin-compact-audit-list">
      {items.map((item) => (
        <article key={item.id}>
          <span><AdminIcon name={auditIcon(item.action)} /></span>
          <div><strong>{humanize(item.action)}</strong><p>{item.actor} · {item.target}</p></div>
          <time>{relativeTime(item.createdAt)}</time>
        </article>
      ))}
    </div>
  );
}

function AdminLoadingScreen({ label }: { label: string }) {
  return <main><LoadingSkeleton label={label} layout="dashboard" fullPage /></main>;
}

function AdminPageSkeleton() {
  return (
    <div className="admin-page-skeleton" role="status" aria-label="Loading admin overview">
      <div className="admin-skeleton-metrics" aria-hidden="true">{[1, 2, 3, 4].map((item) => <span key={item} />)}</div>
      <div className="admin-skeleton-panels" aria-hidden="true"><span /><span /></div>
    </div>
  );
}

type AdminIconName =
  | "overview" | "games" | "policy" | "support" | "reports" | "waitlist" | "people" | "audit" | "referee"
  | "logout" | "refresh" | "alert" | "check" | "arrow" | "search"
  | "replay" | "external" | "edit" | "cancel" | "lock" | "dismiss"
  | "close" | "live" | "shield" | "location";

function AdminIcon({ name }: { name: AdminIconName }) {
  const paths: Record<AdminIconName, React.ReactNode> = {
    location: <><path d="M20 10c0 6-8 12-8 12S4 16 4 10a8 8 0 1 1 16 0Z" /><circle cx="12" cy="10" r="3" /></>,
    overview: <><path d="M4 13h6V4H4v9Zm0 7h6v-4H4v4Zm10 0h6v-9h-6v9Zm0-16v4h6V4h-6Z" /></>,
    games: <><path d="M5 5h14v14H5z" /><path d="M8 3v4M16 3v4M5 10h14" /></>,
    policy: <><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10Z" /><path d="M8 9h8M8 13h5M8 17h3" /></>,
    support: <><path d="M4 13v-2a8 8 0 0 1 16 0v2" /><path d="M4 13H3a2 2 0 0 0-2 2v2a2 2 0 0 0 2 2h2v-6H4ZM20 13h1a2 2 0 0 1 2 2v2a2 2 0 0 1-2 2h-2v-6h1ZM19 19c0 2-2 3-5 3" /></>,
    reports: <><path d="M6 3h9l3 3v15H6z" /><path d="M14 3v4h4M9 11h6M9 15h6" /></>,
    waitlist: <><path d="M9 5h10v16H5V9" /><path d="M9 3v6H3M9 3 3 9M9 13h6M9 17h6" /></>,
    people: <><path d="M16 20v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2" /><circle cx="9" cy="7" r="4" /><path d="M22 20v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75" /></>,
    audit: <><path d="M12 22a10 10 0 1 0-10-10" /><path d="M2 4v6h6M12 6v6l4 2" /></>,
    referee: <><path d="M4 5h16v14H4z" /><path d="m8 9 3 3-3 3M13 15h3" /></>,
    logout: <><path d="M10 17l5-5-5-5M15 12H3" /><path d="M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4" /></>,
    refresh: <><path d="M20 6v6h-6" /><path d="M18.5 17a8 8 0 1 1 1.5-5" /></>,
    alert: <><path d="M10.3 2.8 1.8 17a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 2.8a2 2 0 0 0-3.4 0Z" /><path d="M12 9v4M12 17h.01" /></>,
    check: <><path d="m20 6-11 11-5-5" /></>,
    arrow: <><path d="m9 18 6-6-6-6" /></>,
    search: <><circle cx="11" cy="11" r="7" /><path d="m20 20-4-4" /></>,
    replay: <><path d="M3 12a9 9 0 1 0 3-6.7L3 8" /><path d="M3 3v5h5M10 9l5 3-5 3z" /></>,
    external: <><path d="M14 3h7v7M10 14 21 3" /><path d="M21 14v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5" /></>,
    edit: <><path d="M12 20h9" /><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L8 18l-4 1 1-4Z" /></>,
    cancel: <><circle cx="12" cy="12" r="9" /><path d="m8 8 8 8M16 8l-8 8" /></>,
    lock: <><rect x="5" y="10" width="14" height="11" rx="2" /><path d="M8 10V7a4 4 0 0 1 8 0v3" /></>,
    dismiss: <><path d="M5 5l14 14M19 5 5 19" /></>,
    close: <><path d="m6 6 12 12M18 6 6 18" /></>,
    live: <><circle cx="12" cy="12" r="3" /><path d="M5.6 5.6a9 9 0 0 0 0 12.8M18.4 5.6a9 9 0 0 1 0 12.8" /></>,
    shield: <><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10Z" /><path d="m9 12 2 2 4-4" /></>,
  };
  return (
    <svg aria-hidden="true" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" viewBox="0 0 24 24">
      {paths[name]}
    </svg>
  );
}

async function fetchJson<T = unknown>(input: RequestInfo | URL, init?: RequestInit): Promise<T> {
  const response = await fetch(input, init);
  const payload = (await response.json().catch(() => ({}))) as T & { error?: string };
  if (!response.ok) {
    throw new Error(payload && typeof payload === "object" && "error" in payload
      ? String(payload.error)
      : `Request failed (${response.status}).`);
  }
  return payload;
}

function normalizeOverview(
  payload: unknown,
  games: RefereeFixture[],
  reports: AdminReport[],
  subjects: FlaggedSubject[],
): NormalizedOverview {
  const root = record(payload);
  const metricRecord = record(root.metrics ?? root.summary ?? root.counts);
  const attention = arrayFrom(root.attention ?? root.attentionItems ?? root.items)
    .map((value, index) => normalizeAttention(record(value), index));
  const audit = arrayFrom(root.audit ?? root.auditLog ?? root.recentActivity)
    .map((value, index) => normalizeAudit(record(value), index));
  const openReports = numberFrom(metricRecord.openReports ?? metricRecord.open_reports) ??
    reports.filter((report) => ["OPEN", "TRIAGED", "INVESTIGATING"].includes(report.status)).length;
  const liveGames = numberFrom(metricRecord.liveGames ?? metricRecord.live_games) ??
    games.filter((game) => game.status === "LIVE").length;
  const gamesNeedingAttention = numberFrom(
    metricRecord.gamesNeedingAttention ?? metricRecord.games_needing_attention,
  ) ?? attention.filter((item) => item.kind.includes("GAME") || item.kind.includes("MATCH")).length;
  const activeRestrictions = numberFrom(
    metricRecord.activeRestrictions ?? metricRecord.active_restrictions ??
      metricRecord.activeSuspensions ?? metricRecord.active_suspensions,
  ) ?? subjects.filter((subject) => subject.activeAction).length;
  return {
    openReports,
    attention,
    audit,
    metrics: [
      {
        key: "attention",
        label: "Needs attention",
        value: gamesNeedingAttention + attention.filter((item) => item.severity === "CRITICAL").length,
        detail: "Operational items to review",
        tone: gamesNeedingAttention > 0 ? "warning" : "good",
      },
      {
        key: "reports",
        label: "Open reports",
        value: openReports,
        detail: `${reports.filter((report) => ["HIGH", "CRITICAL", "URGENT"].includes(report.priority)).length} high priority`,
        tone: openReports > 0 ? "danger" : "good",
      },
      {
        key: "live",
        label: "Live games",
        value: liveGames,
        detail: liveGames === 1 ? "Match in progress" : "Matches in progress",
        tone: liveGames > 0 ? "good" : "neutral",
      },
      {
        key: "restrictions",
        label: "Active restrictions",
        value: activeRestrictions,
        detail: "Suspensions, bans and freezes",
        tone: activeRestrictions > 0 ? "warning" : "neutral",
      },
    ],
  };
}

function normalizeAttention(row: JsonRecord, index: number): AttentionItem {
  const rawMatchKind = stringFrom(row.matchKind ?? row.match_kind)?.toUpperCase();
  return {
    id: stringFrom(row.id) ?? `attention-${index}`,
    title: stringFrom(row.title ?? row.label) ?? "Admin review needed",
    detail: stringFrom(row.detail ?? row.description ?? row.message) ?? "Open the related record for details.",
    severity: enumValue(row.severity ?? row.priority, ["LOW", "MEDIUM", "HIGH", "CRITICAL"], "MEDIUM"),
    kind: stringFrom(row.kind ?? row.type ?? row.category) ?? "OPERATIONS",
    createdAt: stringFrom(row.createdAt ?? row.created_at ?? row.occurredAt ?? row.occurred_at),
    matchKind: rawMatchKind === "SOLO" || rawMatchKind === "CLAN" ? rawMatchKind : null,
    gameId: stringFrom(row.gameId ?? row.game_id ?? row.fixtureId ?? row.fixture_id),
    resolution: stringFrom(row.resolution),
    dismissible: row.dismissible !== false,
    paymentRefundId: stringFrom(row.paymentRefundId),
  };
}

function normalizeAudit(row: JsonRecord, index: number): AuditItem {
  return {
    id: stringFrom(row.id) ?? `audit-${index}`,
    action: stringFrom(row.action ?? row.actionType ?? row.action_type) ?? "ADMIN_ACTION",
    actor: nestedName(row.actor) ?? stringFrom(row.actorName ?? row.actor_name) ?? "Admin",
    target: nestedName(row.target) ?? stringFrom(row.targetName ?? row.target_name ?? row.entityType ?? row.entity_type) ?? "Record",
    detail: stringFrom(row.detail ?? row.description ?? row.reason) ?? "",
    createdAt: stringFrom(row.createdAt ?? row.created_at),
  };
}

function normalizeReports(payload: unknown): AdminReport[] {
  const root = record(payload);
  return arrayFrom(Array.isArray(payload) ? payload : root.reports ?? root.items ?? root.data)
    .map((value, index) => {
      const row = record(value);
      const reporter = record(row.reporter);
      const subject = record(row.subject);
      const match = record(row.match);
      const subjectType = enumValue(
        row.subjectType ?? row.subject_type ?? subject.type,
        ["PLAYER", "CLAN", "MATCH", "REFEREE"],
        "PLAYER",
      );
      return {
        id: stringFrom(row.id) ?? `report-${index}`,
        status: upperString(row.status, "OPEN"),
        priority: upperString(row.priority ?? row.severity, "MEDIUM"),
        category: upperString(row.category ?? row.reasonCode ?? row.reason_code, "OTHER"),
        description: stringFrom(row.description ?? row.details ?? row.statement) ?? "",
        reporterName: nestedName(reporter) ?? stringFrom(row.reporterName ?? row.reporter_name) ?? "Player",
        reporterRole: stringFrom(row.reporterRole ?? row.reporter_role ?? reporter.role) ?? "PLAYER",
        subjectType,
        subjectId: stringFrom(row.subjectId ?? row.subject_id ?? subject.id) ?? "",
        subjectName: nestedName(subject) ?? stringFrom(row.subjectName ?? row.subject_name) ?? humanize(subjectType),
        matchLabel: stringFrom(row.matchLabel ?? row.match_label ?? match.label),
        matchKind: stringFrom(row.matchKind ?? row.match_kind ?? match.kind),
        matchId: stringFrom(row.matchId ?? row.match_id ?? row.fixtureId ?? row.fixture_id ?? row.openQueueGameId ?? row.open_queue_game_id ?? match.id),
        replayOffsetSeconds: numberFrom(row.replayOffsetSeconds ?? row.replay_offset_seconds),
        assignedTo: nestedName(row.assignee) ?? stringFrom(row.assignedTo ?? row.assigned_to),
        resolutionNote: stringFrom(row.resolutionNote ?? row.resolution_note),
        createdAt: stringFrom(row.createdAt ?? row.created_at),
        updatedAt: stringFrom(row.updatedAt ?? row.updated_at),
      } satisfies AdminReport;
    });
}

function normalizeSubjects(payload: unknown): FlaggedSubject[] {
  const root = record(payload);
  return arrayFrom(Array.isArray(payload) ? payload : root.subjects ?? root.items ?? root.data)
    .map((value, index) => {
      const row = record(value);
      const subject = record(row.subject);
      const subjectType = enumValue(
        row.subjectType ?? row.subject_type ?? row.targetType ?? row.target_type ?? subject.type,
        ["PLAYER", "CLAN", "REFEREE"],
        "PLAYER",
      );
      const appearances = numberFrom(row.appearances ?? row.matchesPlayed ?? row.matches_played) ?? 0;
      const lifetimeReports = numberFrom(row.lifetimeReports ?? row.lifetime_reports ?? row.totalReports ?? row.total_reports) ?? 0;
      const explicitRate = numberFrom(row.reportsPerTenAppearances ?? row.reports_per_ten_appearances);
      const activeActions = normalizeActiveActions(
        row.activeActions ?? row.active_actions ?? subject.activeActions ?? subject.active_actions,
      );
      const primaryAction = activeActions[0] ?? null;
      return {
        subjectType,
        subjectId: stringFrom(row.subjectId ?? row.subject_id ?? row.targetId ?? row.target_id ?? subject.id) ?? `subject-${index}`,
        name: nestedName(subject) ?? stringFrom(row.name ?? row.displayName ?? row.display_name ?? row.subjectName ?? row.subject_name) ?? "Unknown",
        username: stringFrom(row.username ?? subject.username),
        avatarUrl: stringFrom(row.avatarUrl ?? row.avatar_url ?? subject.avatarUrl ?? subject.avatar_url),
        openReports: numberFrom(row.openReports ?? row.open_reports) ?? 0,
        highPriorityReports: numberFrom(row.highPriorityReports ?? row.high_priority_reports) ?? 0,
        reports30d: numberFrom(row.reports30d ?? row.reports_30d) ?? 0,
        distinctReporters30d: numberFrom(row.distinctReporters30d ?? row.distinct_reporters_30d) ?? 0,
        lifetimeReports,
        actionedReports: numberFrom(row.actionedReports ?? row.actioned_reports ?? row.upheldReports ?? row.upheld_reports) ?? 0,
        appearances,
        reportsPerTenAppearances: explicitRate ?? (appearances > 0 ? lifetimeReports / appearances * 10 : null),
        activeAction: primaryAction?.actionType ??
          stringFrom(row.activeAction ?? row.active_action ?? row.currentAction ?? row.current_action),
        activeActionEndsAt: primaryAction?.endsAt ??
          stringFrom(row.activeActionEndsAt ?? row.active_action_ends_at),
        activeActions,
        lastReportedAt: stringFrom(row.lastReportedAt ?? row.last_reported_at),
      } satisfies FlaggedSubject;
    })
    .sort((left, right) =>
      right.highPriorityReports - left.highPriorityReports ||
      right.actionedReports - left.actionedReports ||
      right.distinctReporters30d - left.distinctReporters30d ||
      right.lifetimeReports - left.lifetimeReports,
    );
}

function subjectFromReport(report: AdminReport): FlaggedSubject {
  return {
    subjectType: report.subjectType === "MATCH" ? "PLAYER" : report.subjectType,
    subjectId: report.subjectId,
    name: report.subjectName,
    username: null,
    avatarUrl: null,
    openReports: 1,
    highPriorityReports: ["HIGH", "CRITICAL", "URGENT"].includes(report.priority) ? 1 : 0,
    reports30d: 1,
    distinctReporters30d: 1,
    lifetimeReports: 1,
    actionedReports: 0,
    appearances: 0,
    reportsPerTenAppearances: null,
    activeAction: null,
    activeActionEndsAt: null,
    activeActions: [],
    lastReportedAt: report.createdAt,
  };
}

function normalizeActiveActions(value: unknown): ActiveModerationAction[] {
  return arrayFrom(value).map((item, index) => {
    const row = record(item);
    return {
      id: stringFrom(row.id) ?? `active-action-${index}`,
      actionType: upperString(row.actionType ?? row.action_type, "RESTRICTION"),
      restrictionScope: stringFrom(row.restrictionScope ?? row.restriction_scope),
      reasonCode: upperString(row.reasonCode ?? row.reason_code, "OTHER"),
      userMessage: stringFrom(row.userMessage ?? row.user_message ?? row.message) ?? "",
      startsAt: stringFrom(row.startsAt ?? row.starts_at),
      endsAt: stringFrom(row.endsAt ?? row.ends_at),
      issuedBy: nestedName(row.issuedBy ?? row.issued_by) ??
        stringFrom(row.issuedBy ?? row.issued_by ?? row.issuedByName ?? row.issued_by_name) ??
        "Admin",
    } satisfies ActiveModerationAction;
  });
}

function record(value: unknown): JsonRecord {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as JsonRecord
    : {};
}

function arrayFrom(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function stringFrom(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function numberFrom(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() && Number.isFinite(Number(value))) return Number(value);
  return null;
}

function nestedName(value: unknown): string | null {
  const row = record(value);
  return stringFrom(row.name ?? row.displayName ?? row.display_name ?? row.label);
}

function enumValue<T extends string>(value: unknown, allowed: readonly T[], fallback: T): T {
  const normalized = String(value ?? "").toUpperCase() as T;
  return allowed.includes(normalized) ? normalized : fallback;
}

function upperString(value: unknown, fallback: string) {
  return stringFrom(value)?.toUpperCase() ?? fallback;
}

function sectionTitle(section: AdminSection) {
  return {
    overview: "Every game starts here.",
    games: "Games",
    schedules: "Game schedules",
    fields: "Fields & pitches",
    cities: "Competition cities",
    seasons: "Seasons & rewards",
    reliability: "Reliability policy",
    support: "Player support",
    reports: "Reports inbox",
    waitlist: "Interest",
    people: "Players & clans",
    staff: "Admins & referees",
    audit: "Audit log",
  }[section];
}

function sectionSubtitle(section: AdminSection) {
  return {
    overview: "Your Fieldrush matchdays, people and priorities in one place.",
    games: "Review, correct, cancel and watch every match.",
    schedules: "Choose when and where you play. Publish upcoming games automatically.",
    fields: "Save real locations once. Assign them to games. Help players find the pitch.",
    cities: "Choose where Fieldrush is available. Keep game discovery, timezones and rankings connected.",
    seasons: "Plan each season and publish city-by-city cash rewards for Outfield and Keeper ladders.",
    reliability: "Schedule fair attendance, refund, strike and SR rules without rewriting history.",
    support: "Handle account, booking, match and technical requests without mixing them into moderation.",
    reports: "Triage player reports privately and consistently.",
    waitlist: "Review launch update signups and player applications in one place.",
    people: "Understand patterns before taking proportionate action.",
    staff: "Set up dedicated staff email accounts and control who can operate Field.",
    audit: "A permanent trail of sensitive admin decisions.",
  }[section];
}

function metricIcon(key: string): AdminIconName {
  if (key.includes("report")) return "reports";
  if (key.includes("support")) return "support";
  if (key.includes("live")) return "live";
  if (key.includes("restriction")) return "shield";
  return "alert";
}

function auditIcon(action: string): AdminIconName {
  const value = action.toUpperCase();
  if (value.includes("SCORE")) return "edit";
  if (value.includes("CANCEL")) return "cancel";
  if (value.includes("REPORT")) return "reports";
  if (value.includes("SUPPORT")) return "support";
  if (value.includes("BAN") || value.includes("SUSPEND") || value.includes("WARN")) return "shield";
  return "audit";
}

function moderationActionLabel(action: ModerationActionType) {
  return {
    WARNING: "Warning",
    PLAY_SUSPENSION: "Play suspension",
    ACCOUNT_SUSPENSION: "Account suspension",
    PERMANENT_BAN: "Permanent ban",
    CLAN_SCHEDULING_FREEZE: "Scheduling freeze",
    CLAN_DISQUALIFICATION: "Clan disqualification",
  }[action];
}

function activeActionLabel(action: ActiveModerationAction) {
  const actionType = action.actionType.toUpperCase();
  const scope = action.restrictionScope?.toUpperCase() ?? "";
  if (actionType === "WARNING") return "Warning";
  if (actionType === "BAN") {
    return scope === "CLAN" ? "Clan disqualification" : "Permanent ban";
  }
  if (actionType === "SUSPENSION") {
    if (scope === "PLAY") return "Play suspension";
    if (scope === "SCHEDULING") return "Scheduling freeze";
    return "Account suspension";
  }
  return humanize(action.actionType);
}

function assignedRefereeName(
  assignments: RefereeAssignmentsResponse,
  fixture: RefereeFixture,
) {
  const refereeId = assignedRefereeId(assignments, fixture);
  if (!refereeId) return "Unassigned";
  return assignments.referees.find(
    (referee) => referee.profileId === refereeId,
  )?.displayName ?? "Assigned referee";
}

function assignedRefereeId(
  assignments: RefereeAssignmentsResponse,
  fixture: RefereeFixture,
) {
  const assignment = assignments.fixtures.find(
    (candidate) => candidate.id === fixture.id && candidate.matchKind === fixture.matchKind,
  );
  return assignment?.assignedRefereeId ?? "";
}

function displayScore(fixture: RefereeFixture) {
  if (fixture.operationalState === "NO_DATA") return "No data";
  if (fixture.operationalState === "UNDER_REVIEW") return "Under review";
  if (fixture.homeScore === null && fixture.awayScore === null) return "—";
  return `${fixture.homeScore ?? 0} – ${fixture.awayScore ?? 0}`;
}

function adminDisplayStatus(fixture: RefereeFixture) {
  const operationalState = fixture.operationalState?.toUpperCase();
  return operationalState === "NO_DATA" || operationalState === "UNDER_REVIEW"
    ? operationalState
    : fixture.status;
}

function isScheduledAdminGame(fixture: RefereeFixture) {
  if (["NO_DATA", "UNDER_REVIEW"].includes(adminDisplayStatus(fixture))) {
    return false;
  }
  return ["OPEN", "FULL", "SCHEDULED", "LIVE"].includes(fixture.status);
}

function isFinalAdminGame(fixture: RefereeFixture) {
  if (["NO_DATA", "UNDER_REVIEW"].includes(adminDisplayStatus(fixture))) {
    return true;
  }
  return ["FINAL", "CANCELLED"].includes(fixture.status);
}


function sortScheduledAdminGames(left: RefereeFixture, right: RefereeFixture) {
  if (left.status === "LIVE" && right.status !== "LIVE") return -1;
  if (right.status === "LIVE" && left.status !== "LIVE") return 1;

  const now = Date.now();
  const leftTime = adminGameStartTimestamp(left);
  const rightTime = adminGameStartTimestamp(right);
  const leftUpcoming = leftTime >= now;
  const rightUpcoming = rightTime >= now;
  if (leftUpcoming !== rightUpcoming) return leftUpcoming ? -1 : 1;
  return leftUpcoming ? leftTime - rightTime : rightTime - leftTime;
}

function sortFinalAdminGames(left: RefereeFixture, right: RefereeFixture) {
  return adminGameStartTimestamp(right) - adminGameStartTimestamp(left);
}

function forfeitHomeClan(decision: AdminForfeit) {
  if (decision.homeClanId === decision.awardedClan.id) return decision.awardedClan;
  if (decision.homeClanId === decision.reportedClan.id) return decision.reportedClan;
  return decision.reportedClan;
}

function forfeitAwayClan(decision: AdminForfeit) {
  if (decision.awayClanId === decision.awardedClan.id) return decision.awardedClan;
  if (decision.awayClanId === decision.reportedClan.id) return decision.reportedClan;
  return decision.awardedClan;
}

function formatPriorScore(decision: AdminForfeit) {
  if (decision.previousHomeScore === null && decision.previousAwayScore === null) {
    return "Not recorded";
  }
  return `${decision.previousHomeScore ?? 0}–${decision.previousAwayScore ?? 0}`;
}

function broadcastStatusText(status: string | undefined) {
  return {
    READY: "Broadcast ready",
    STARTING: "Camera connecting",
    LIVE: "Stream currently live",
    STOPPING: "Stream is stopping",
    PROCESSING: "Replay is processing",
    REPLAY_READY: "Replay ready",
    ERROR: "Replay needs attention",
    NOT_CONFIGURED: "No recording configured",
  }[status ?? "NOT_CONFIGURED"] ?? "No recording found";
}

function humanize(value: string) {
  return value
    .toLowerCase()
    .replace(/[_-]+/g, " ")
    .replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function waitlistInterestLabel(value: WaitlistInterest | null) {
  if (value === null) return "Not recorded";
  return {
    LAUNCH_UPDATES: "Launch updates",
    SOLO_PLAYER: "Solo player",
    CLAN_PLAYER: "Clan player",
    CLAN_LEADER: "Clan leader",
  }[value];
}

function waitlistSourceLabel(value: string) {
  if (value === "FIELDRUSH_GG") return "fieldrush.gg";
  if (value === "FIELD_BH") return "field.bh";
  return humanize(value);
}

function waitlistPlacementLabel(value: string) {
  const labels: Record<string, string> = {
    "desktop-hero": "Desktop hero",
    "desktop-footer": "Desktop footer",
    "mobile-hero": "Mobile hero",
    "mobile-footer": "Mobile footer",
  };
  return labels[value] ?? humanize(value);
}

function initials(value: string) {
  const letters = value.trim().split(/\s+/).slice(0, 2).map((part) => part[0]?.toUpperCase() ?? "").join("");
  return letters || "F";
}

function truncate(value: string, limit: number) {
  return value.length > limit ? `${value.slice(0, limit - 1)}…` : value;
}

function nextSoloMatchDate() {
  const now = new Date();
  const phoenixCalendar = new Date(now.getTime() - 7 * 60 * 60 * 1000);
  const candidate = new Date(Date.UTC(
    phoenixCalendar.getUTCFullYear(),
    phoenixCalendar.getUTCMonth(),
    phoenixCalendar.getUTCDate(),
  ));

  for (let offset = 0; offset < 14; offset += 1) {
    const value = [
      candidate.getUTCFullYear(),
      String(candidate.getUTCMonth() + 1).padStart(2, "0"),
      String(candidate.getUTCDate()).padStart(2, "0"),
    ].join("-");
    const kickoff = new Date(`${value}T20:30:00-07:00`);
    if (kickoff.getTime() > now.getTime()) {
      return value;
    }
    candidate.setUTCDate(candidate.getUTCDate() + 1);
  }

  return "";
}

function formatAdminDate(value: string) {
  const date = new Date(value.length === 10 ? `${value}T12:00:00` : value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("en", { month: "short", day: "numeric", year: "numeric" }).format(date);
}

function formatDateTime(value: string | null) {
  if (!value) return "Not recorded";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("en", {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(date);
}

function formatReplayOffset(value: number) {
  const seconds = Math.max(0, Math.round(value));
  const minutes = Math.floor(seconds / 60);
  return `${minutes}:${String(seconds % 60).padStart(2, "0")}`;
}

function relativeTime(value: string | null) {
  if (!value) return "Now";
  const timestamp = new Date(value).getTime();
  if (!Number.isFinite(timestamp)) return value;
  const seconds = Math.round((timestamp - Date.now()) / 1000);
  const formatter = new Intl.RelativeTimeFormat("en", { numeric: "auto" });
  if (Math.abs(seconds) < 60) return formatter.format(seconds, "second");
  const minutes = Math.round(seconds / 60);
  if (Math.abs(minutes) < 60) return formatter.format(minutes, "minute");
  const hours = Math.round(minutes / 60);
  if (Math.abs(hours) < 24) return formatter.format(hours, "hour");
  return formatter.format(Math.round(hours / 24), "day");
}

function errorMessage(error: unknown, fallback: string) {
  return error instanceof Error ? error.message : fallback;
}

"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { normalizePhoneNumber } from "@/lib/phone";
import { formatPlayerSr } from "@/lib/open-queue-ratings";
import { createSupabaseBrowserClient } from "@/lib/supabase-browser";
import type {
  AssignableFixture,
  BlueCard,
  BroadcastControlResponse,
  FixtureClock,
  FixtureEvent,
  Player,
  RefereeAssignmentsResponse,
  RefereeFixture,
  RefereeFixturesResponse,
  RefereeListItem,
} from "@/lib/types";

type Tab = "games" | "assign" | "admin";
type FixtureActionBody = Record<
  string,
  string | number | string[] | null | undefined
>;

type Me = RefereeFixturesResponse["me"];

const supabase = createSupabaseBrowserClient();
const MAX_MATCH_SECONDS = 3 * 60 * 60;

export default function RefereePage() {
  const [accessToken, setAccessToken] = useState<string | null>(null);
  const [me, setMe] = useState<Me | null>(null);
  const [tab, setTab] = useState<Tab>("games");
  const [phone, setPhone] = useState("");
  const [otp, setOtp] = useState("");
  const [otpSent, setOtpSent] = useState(false);
  const [fixtures, setFixtures] = useState<RefereeFixture[]>([]);
  const [adminFixtures, setAdminFixtures] = useState<RefereeFixture[]>([]);
  const [activeFixtureId, setActiveFixtureId] = useState<string | null>(null);
  const [assignments, setAssignments] = useState<RefereeAssignmentsResponse>({
    referees: [],
    fixtures: [],
  });
  const [error, setError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [isAdminLoading, setIsAdminLoading] = useState(false);
  const [submitting, setSubmitting] = useState<string | null>(null);
  const [goalClanId, setGoalClanId] = useState("");
  const [goalPlayerId, setGoalPlayerId] = useState("");
  const [assistPlayerId, setAssistPlayerId] = useState("");
  const [cardClanId, setCardClanId] = useState("");
  const [cardPlayerId, setCardPlayerId] = useState("");
  const [newRefName, setNewRefName] = useState("");
  const [newRefPhone, setNewRefPhone] = useState("");
  const loadedSession = useRef(false);

  const activeFixture =
    fixtures.find((fixture) => fixture.id === activeFixtureId) ??
    fixtures[0] ??
    null;

  const authHeaders = useCallback(() => {
    if (!accessToken) throw new Error("Sign in required.");
    return { authorization: `Bearer ${accessToken}` };
  }, [accessToken]);

  const loadGames = useCallback(async () => {
    if (!accessToken) return;
    setIsLoading(true);
    setError(null);

    try {
      const response = await fetch("/api/referee/fixtures", {
        headers: authHeaders(),
        cache: "no-store",
      });
      const payload = (await response.json()) as
        | RefereeFixturesResponse
        | { error: string };

      if (!response.ok || "error" in payload) {
        throw new Error(
          "error" in payload ? payload.error : "Could not load games.",
        );
      }

      setMe(payload.me);
      setFixtures(payload.fixtures);
      setActiveFixtureId((current) => {
        if (current && payload.fixtures.some((fixture) => fixture.id === current)) {
          return current;
        }
        return payload.fixtures[0]?.id ?? null;
      });
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : "Load failed.");
    } finally {
      setIsLoading(false);
    }
  }, [accessToken, authHeaders]);

  const loadAssignments = useCallback(async () => {
    if (!accessToken || me?.role !== "admin") return;

    try {
      const response = await fetch("/api/referee/assignments", {
        headers: authHeaders(),
        cache: "no-store",
      });
      const payload = (await response.json()) as
        | RefereeAssignmentsResponse
        | { error: string };

      if (!response.ok || "error" in payload) {
        throw new Error(
          "error" in payload ? payload.error : "Could not load assignments.",
        );
      }

      setAssignments(payload);
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : "Load failed.");
    }
  }, [accessToken, authHeaders, me?.role]);

  const loadAdminFixtures = useCallback(async () => {
    if (!accessToken || me?.role !== "admin") return;
    setIsAdminLoading(true);
    setError(null);

    try {
      const response = await fetch("/api/referee/fixtures?scope=admin", {
        headers: authHeaders(),
        cache: "no-store",
      });
      const payload = (await response.json()) as
        | RefereeFixturesResponse
        | { error: string };

      if (!response.ok || "error" in payload) {
        throw new Error(
          "error" in payload ? payload.error : "Could not load admin games.",
        );
      }

      setMe(payload.me);
      setAdminFixtures(payload.fixtures);
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : "Load failed.");
    } finally {
      setIsAdminLoading(false);
    }
  }, [accessToken, authHeaders, me?.role]);

  useEffect(() => {
    if (loadedSession.current) return;
    loadedSession.current = true;

    supabase.auth.getSession().then(({ data }) => {
      const token = data.session?.access_token ?? null;
      setAccessToken(token);
    });

    const { data: listener } = supabase.auth.onAuthStateChange(
      (_event, session) => {
        setAccessToken(session?.access_token ?? null);
      },
    );

    return () => listener.subscription.unsubscribe();
  }, []);

  useEffect(() => {
    if (accessToken) void loadGames();
  }, [accessToken, loadGames]);

  useEffect(() => {
    if (accessToken && me?.role === "admin") {
      void loadAssignments();
      void loadAdminFixtures();
    }
  }, [accessToken, loadAdminFixtures, loadAssignments, me?.role]);

  useEffect(() => {
    if (me?.role === "admin" && fixtures.length === 0 && tab === "games") {
      setTab("admin");
    }
  }, [fixtures.length, me?.role, tab]);

  useEffect(() => {
    if (!activeFixture) return;
    const defaultClanId = activeFixture.homeClan.id;
    const firstPlayer = playersForClan(activeFixture, defaultClanId)[0]?.id ?? "";

    setGoalClanId(defaultClanId);
    setCardClanId(defaultClanId);
    setGoalPlayerId(firstPlayer);
    setAssistPlayerId("");
    setCardPlayerId(firstPlayer);
  }, [activeFixture]);

  async function sendOtp(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setSubmitting("otp");

    try {
      const normalizedPhone = normalizePhoneNumber(phone);
      const { error: otpError } = await supabase.auth.signInWithOtp({
        phone: normalizedPhone,
      });
      if (otpError) throw otpError;
      setPhone(normalizedPhone);
      setOtpSent(true);
    } catch (otpError) {
      setError(otpError instanceof Error ? otpError.message : "Could not send OTP.");
    } finally {
      setSubmitting(null);
    }
  }

  async function verifyOtp(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setSubmitting("verify");

    try {
      const { data, error: verifyError } = await supabase.auth.verifyOtp({
        phone: normalizePhoneNumber(phone),
        token: otp.trim(),
        type: "sms",
      });
      if (verifyError) throw verifyError;
      setAccessToken(data.session?.access_token ?? null);
    } catch (verifyError) {
      setError(
        verifyError instanceof Error ? verifyError.message : "Could not verify OTP.",
      );
    } finally {
      setSubmitting(null);
    }
  }

  async function signOut() {
    await supabase.auth.signOut();
    setAccessToken(null);
    setMe(null);
    setFixtures([]);
    setAdminFixtures([]);
    setAssignments({ referees: [], fixtures: [] });
    setOtp("");
    setOtpSent(false);
  }

  async function runAction(
    body: FixtureActionBody,
  ) {
    if (!activeFixture) return;
    await runFixtureAction(
      activeFixture.id,
      activeFixture.matchKind,
      body,
      false,
    );
  }

  async function runAdminAction(
    fixtureId: string,
    body: FixtureActionBody,
  ) {
    const fixture = adminFixtures.find((candidate) => candidate.id === fixtureId);
    await runFixtureAction(fixtureId, fixture?.matchKind ?? "CLAN", body, true);
  }

  async function runFixtureAction(
    fixtureId: string,
    matchKind: RefereeFixture["matchKind"],
    body: FixtureActionBody,
    refreshAdmin: boolean,
  ) {
    const action = String(body.action ?? "action");
    setSubmitting(action);
    setError(null);

    try {
      const actionUrl = matchKind === "SOLO"
        ? `/api/referee/open-queue-games/${fixtureId}/action`
        : `/api/referee/fixtures/${fixtureId}/action`;
      const response = await fetch(actionUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...authHeaders(),
        },
        body: JSON.stringify(body),
      });
      const payload = (await response.json()) as { error?: string };
      if (!response.ok) throw new Error(payload.error ?? "Action failed.");
      await Promise.all([
        loadGames(),
        refreshAdmin ? loadAdminFixtures() : Promise.resolve(),
      ]);
    } catch (actionError) {
      setError(
        actionError instanceof Error ? actionError.message : "Action failed.",
      );
    } finally {
      setSubmitting(null);
    }
  }

  async function assignReferee(
    fixtureId: string,
    refereeId: string,
    matchKind: RefereeFixture["matchKind"],
  ) {
    setSubmitting(`assign-${fixtureId}`);
    setError(null);
    setAssignments((current) => ({
      ...current,
      fixtures: current.fixtures.map((fixture) =>
        fixture.id === fixtureId && fixture.matchKind === matchKind
          ? { ...fixture, assignedRefereeId: refereeId || null }
          : fixture,
      ),
    }));

    try {
      const response = await fetch("/api/referee/assignments", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...authHeaders(),
        },
        body: JSON.stringify({
          fixtureId,
          refereeId: refereeId || null,
          matchKind,
        }),
      });
      const payload = (await response.json()) as { error?: string };
      if (!response.ok) throw new Error(payload.error ?? "Assignment failed.");
      await Promise.all([loadAssignments(), loadGames(), loadAdminFixtures()]);
    } catch (assignError) {
      setError(
        assignError instanceof Error ? assignError.message : "Assignment failed.",
      );
      await loadAssignments();
    } finally {
      setSubmitting(null);
    }
  }

  async function createReferee(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSubmitting("create-referee");
    setError(null);

    try {
      const response = await fetch("/api/referee/referees", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...authHeaders(),
        },
        body: JSON.stringify({
          displayName: newRefName,
          phone: newRefPhone,
          role: "referee",
          sendOtp: true,
        }),
      });
      const payload = (await response.json()) as { error?: string };
      if (!response.ok) throw new Error(payload.error ?? "Could not create referee.");
      setNewRefName("");
      setNewRefPhone("");
      await loadAssignments();
    } catch (createError) {
      setError(
        createError instanceof Error
          ? createError.message
          : "Could not create referee.",
      );
    } finally {
      setSubmitting(null);
    }
  }

  const goalPlayers = activeFixture
    ? playersForClan(activeFixture, goalClanId || activeFixture.homeClan.id)
    : [];
  const cardPlayers = activeFixture
    ? playersForClan(activeFixture, cardClanId || activeFixture.homeClan.id)
    : [];

  if (!accessToken) {
    return (
      <main className="app-shell">
        <div className="content">
          <section className="code-card">
            <Header title="REFEREE" subtitle="PHONE LOGIN" />
            <div style={{ height: 20 }} />
            {!otpSent ? (
              <form className="form-grid" onSubmit={sendOtp}>
                <label>
                  <span className="field-label">Phone</span>
                  <input
                    className="input"
                    inputMode="tel"
                    value={phone}
                    onChange={(event) => setPhone(event.target.value)}
                    placeholder="+1 480 746 9696"
                  />
                </label>
                <button
                  className="primary-button"
                  disabled={submitting === "otp"}
                  type="submit"
                >
                  Send OTP
                </button>
              </form>
            ) : (
              <form className="form-grid" onSubmit={verifyOtp}>
                <label>
                  <span className="field-label">OTP</span>
                  <input
                    className="input"
                    inputMode="numeric"
                    value={otp}
                    onChange={(event) => setOtp(event.target.value)}
                    placeholder="000000"
                  />
                </label>
                <button
                  className="primary-button"
                  disabled={submitting === "verify"}
                  type="submit"
                >
                  Verify
                </button>
                <button
                  className="ghost-button"
                  onClick={() => setOtpSent(false)}
                  type="button"
                >
                  Change Phone
                </button>
              </form>
            )}
            {error ? <div className="error">{error}</div> : null}
          </section>
        </div>
      </main>
    );
  }

  return (
    <main className="app-shell">
      <div className="content">
        <header className="topbar">
          <Header
            title="REFEREE"
            subtitle={me ? `${me.displayName} · ${me.role}` : "LOADING"}
          />
          <button className="ghost-button" onClick={() => void signOut()} type="button">
            Logout
          </button>
        </header>

        {me?.role === "admin" ? (
          <div className="segmented top-tabs">
            <button
              className={`chip-button ${tab === "games" ? "active" : ""}`}
              onClick={() => setTab("games")}
              type="button"
            >
              My Games
            </button>
            <button
              className={`chip-button ${tab === "assign" ? "active" : ""}`}
              onClick={() => setTab("assign")}
              type="button"
            >
              Assign
            </button>
            <button
              className={`chip-button ${tab === "admin" ? "active" : ""}`}
              onClick={() => setTab("admin")}
              type="button"
            >
              Control
            </button>
          </div>
        ) : null}

        {error ? <div className="error">{error}</div> : null}

        {tab === "admin" && me?.role === "admin" ? (
          <AdminControlView
            assignments={assignments}
            fixtures={adminFixtures}
            isLoading={isAdminLoading}
            submitting={submitting}
            onRunAction={runAdminAction}
            onRefresh={() => void Promise.all([loadAdminFixtures(), loadAssignments()])}
          />
        ) : tab === "assign" && me?.role === "admin" ? (
          <AssignView
            assignments={assignments}
            newRefName={newRefName}
            newRefPhone={newRefPhone}
            submitting={submitting}
            onNameChange={setNewRefName}
            onPhoneChange={setNewRefPhone}
            onCreateReferee={createReferee}
            onAssign={assignReferee}
            onRefresh={() => void loadAssignments()}
          />
        ) : (
          <GamesView
            accessToken={accessToken}
            activeFixture={activeFixture}
            fixtures={fixtures}
            isLoading={isLoading}
            submitting={submitting}
            goalClanId={goalClanId}
            goalPlayerId={goalPlayerId}
            assistPlayerId={assistPlayerId}
            cardClanId={cardClanId}
            cardPlayerId={cardPlayerId}
            goalPlayers={goalPlayers}
            cardPlayers={cardPlayers}
            onSelectFixture={setActiveFixtureId}
            onGoalClan={setGoalClanId}
            onGoalPlayer={setGoalPlayerId}
            onAssistPlayer={setAssistPlayerId}
            onCardClan={setCardClanId}
            onCardPlayer={setCardPlayerId}
            onRunAction={runAction}
            onRefresh={() => void loadGames()}
          />
        )}
      </div>
    </main>
  );
}

function Header({ title, subtitle }: { title: string; subtitle: string }) {
  return (
    <div className="brand">
      <div className="rail" />
      <div>
        <h1 className="title">{title}</h1>
        <p className="subtitle">{subtitle}</p>
      </div>
    </div>
  );
}

function AssignView({
  assignments,
  newRefName,
  newRefPhone,
  submitting,
  onNameChange,
  onPhoneChange,
  onCreateReferee,
  onAssign,
  onRefresh,
}: {
  assignments: RefereeAssignmentsResponse;
  newRefName: string;
  newRefPhone: string;
  submitting: string | null;
  onNameChange: (value: string) => void;
  onPhoneChange: (value: string) => void;
  onCreateReferee: (event: React.FormEvent<HTMLFormElement>) => void;
  onAssign: (
    fixtureId: string,
    refereeId: string,
    matchKind: RefereeFixture["matchKind"],
  ) => void;
  onRefresh: () => void;
}) {
  return (
    <>
      <section className="panel">
        <div className="panel-heading">
          <h2 className="panel-title">Add Referee</h2>
        </div>
        <form className="form-grid" onSubmit={onCreateReferee}>
          <input
            className="input"
            value={newRefName}
            onChange={(event) => onNameChange(event.target.value)}
            placeholder="Name"
          />
          <input
            className="input"
            inputMode="tel"
            value={newRefPhone}
            onChange={(event) => onPhoneChange(event.target.value)}
            placeholder="Phone"
          />
          <button
            className="primary-button"
            disabled={submitting === "create-referee"}
            type="submit"
          >
            Create + Send OTP
          </button>
        </form>
      </section>

      <section className="panel">
        <div className="panel-heading">
          <h2 className="panel-title">Assign Games</h2>
          <button className="ghost-button" onClick={onRefresh} type="button">
            Refresh
          </button>
        </div>
        <div className="event-list">
          {assignments.fixtures.length === 0 ? (
            <div className="empty">No scheduled games to assign</div>
          ) : (
            assignments.fixtures.map((fixture) => (
              <AssignmentRow
                fixture={fixture}
                referees={assignments.referees}
                key={fixture.id}
                submitting={submitting === `assign-${fixture.id}`}
                onAssign={(refereeId) =>
                  onAssign(fixture.id, refereeId, fixture.matchKind)
                }
              />
            ))
          )}
        </div>
      </section>
    </>
  );
}

function AssignmentRow({
  fixture,
  referees,
  submitting,
  onAssign,
}: {
  fixture: AssignableFixture;
  referees: RefereeListItem[];
  submitting: boolean;
  onAssign: (refereeId: string) => void;
}) {
  return (
    <div className="event-card" style={{ display: "block" }}>
      <div className="utility-row">
        <div>
          <div className="event-title">
            {fixture.homeClan.tag} vs {fixture.awayClan.tag}
            {fixture.matchKind === "SOLO" ? " · SOLO" : ""}
          </div>
          <div className="event-subtitle">
            {fixture.matchDate} · {fixture.timeSlot}
          </div>
        </div>
        <span className="event-minute">{fixture.status}</span>
      </div>
      <div style={{ height: 10 }} />
      <select
        className="select"
        disabled={submitting}
        value={fixture.assignedRefereeId ?? ""}
        onChange={(event) => onAssign(event.target.value)}
      >
        <option value="">Unassigned</option>
        {referees.map((referee) => (
          <option key={referee.profileId} value={referee.profileId}>
            {referee.displayName}
          </option>
        ))}
      </select>
    </div>
  );
}

function AdminControlView({
  assignments,
  fixtures,
  isLoading,
  submitting,
  onRunAction,
  onRefresh,
}: {
  assignments: RefereeAssignmentsResponse;
  fixtures: RefereeFixture[];
  isLoading: boolean;
  submitting: string | null;
  onRunAction: (
    fixtureId: string,
    body: FixtureActionBody,
  ) => Promise<void>;
  onRefresh: () => void;
}) {
  const [statusFilter, setStatusFilter] = useState<"ALL" | RefereeFixture["status"]>(
    "FINAL",
  );
  const [refereeFilter, setRefereeFilter] = useState("ALL");
  const [dateFromFilter, setDateFromFilter] = useState("");
  const [dateToFilter, setDateToFilter] = useState("");
  const [teamFilter, setTeamFilter] = useState("");
  const [activeFixtureId, setActiveFixtureId] = useState<string | null>(null);
  const [goalClanId, setGoalClanId] = useState("");
  const [goalPlayerId, setGoalPlayerId] = useState("");
  const [assistPlayerId, setAssistPlayerId] = useState("");
  const [cardClanId, setCardClanId] = useState("");
  const [cardPlayerId, setCardPlayerId] = useState("");

  const filteredFixtures = useMemo(() => {
    const teamNeedle = teamFilter.trim().toLowerCase();

    return fixtures.filter((fixture) => {
      const assignedRefereeId = assignedRefereeFor(assignments, fixture.id);
      const teamText = [
        fixture.homeClan.name,
        fixture.homeClan.tag,
        fixture.awayClan.name,
        fixture.awayClan.tag,
      ]
        .join(" ")
        .toLowerCase();

      if (statusFilter !== "ALL" && fixture.status !== statusFilter) return false;
      if (dateFromFilter && fixture.matchDate < dateFromFilter) return false;
      if (dateToFilter && fixture.matchDate > dateToFilter) return false;
      if (teamNeedle && !teamText.includes(teamNeedle)) return false;
      if (refereeFilter === "UNASSIGNED" && assignedRefereeId) return false;
      if (
        refereeFilter !== "ALL" &&
        refereeFilter !== "UNASSIGNED" &&
        assignedRefereeId !== refereeFilter
      ) {
        return false;
      }

      return true;
    });
  }, [
    assignments,
    dateFromFilter,
    dateToFilter,
    fixtures,
    refereeFilter,
    statusFilter,
    teamFilter,
  ]);

  const activeFixture =
    filteredFixtures.find((fixture) => fixture.id === activeFixtureId) ??
    filteredFixtures[0] ??
    null;

  useEffect(() => {
    if (filteredFixtures.length === 0) {
      if (activeFixtureId !== null) setActiveFixtureId(null);
      return;
    }

    if (!activeFixtureId || !filteredFixtures.some((fixture) => fixture.id === activeFixtureId)) {
      setActiveFixtureId(filteredFixtures[0].id);
    }
  }, [activeFixtureId, filteredFixtures]);

  useEffect(() => {
    if (!activeFixture) return;
    const defaultClanId = activeFixture.homeClan.id;
    const firstPlayer = playersForClan(activeFixture, defaultClanId)[0]?.id ?? "";

    setGoalClanId(defaultClanId);
    setGoalPlayerId(firstPlayer);
    setAssistPlayerId("");
    setCardClanId(defaultClanId);
    setCardPlayerId(firstPlayer);
  }, [activeFixture]);

  const goalPlayers = activeFixture
    ? playersForClan(activeFixture, goalClanId || activeFixture.homeClan.id)
    : [];
  const cardPlayers = activeFixture
    ? playersForClan(activeFixture, cardClanId || activeFixture.homeClan.id)
    : [];
  const isFinal = activeFixture?.status === "FINAL";
  const canRecordLive = activeFixture?.status === "LIVE";

  return (
    <>
      <section className="panel">
        <div className="panel-heading">
          <div>
            <h2 className="panel-title">Admin Control</h2>
            <p className="small-text">
              Review historic games and manage live match records.
            </p>
          </div>
          <button
            className="ghost-button"
            disabled={isLoading}
            onClick={onRefresh}
            type="button"
          >
            Refresh
          </button>
        </div>

        <div className="admin-filters">
          <label>
            <span className="field-label">Status</span>
            <select
              className="select"
              value={statusFilter}
              onChange={(event) =>
                setStatusFilter(event.target.value as "ALL" | RefereeFixture["status"])
              }
            >
              <option value="ALL">All Statuses</option>
              <option value="FINAL">Final</option>
              <option value="SCHEDULED">Scheduled</option>
              <option value="FULL">Full solo games</option>
              <option value="LIVE">Live</option>
              <option value="OPEN">Open</option>
              <option value="CANCELLED">Cancelled</option>
            </select>
          </label>

          <label>
            <span className="field-label">Referee</span>
            <select
              className="select"
              value={refereeFilter}
              onChange={(event) => setRefereeFilter(event.target.value)}
            >
              <option value="ALL">All Referees</option>
              <option value="UNASSIGNED">Unassigned</option>
              {assignments.referees.map((referee) => (
                <option key={referee.profileId} value={referee.profileId}>
                  {referee.displayName}
                </option>
              ))}
            </select>
          </label>

          <label>
            <span className="field-label">From</span>
            <input
              className="input"
              type="date"
              value={dateFromFilter}
              onChange={(event) => setDateFromFilter(event.target.value)}
            />
          </label>

          <label>
            <span className="field-label">To</span>
            <input
              className="input"
              type="date"
              value={dateToFilter}
              onChange={(event) => setDateToFilter(event.target.value)}
            />
          </label>

          <label>
            <span className="field-label">Team</span>
            <input
              className="input"
              value={teamFilter}
              onChange={(event) => setTeamFilter(event.target.value)}
              placeholder="Clan name or tag"
            />
          </label>
        </div>
      </section>

      <section className="panel">
        <div className="panel-heading">
          <h2 className="panel-title">Games</h2>
          <span className="small-text">{filteredFixtures.length} shown</span>
        </div>

        {filteredFixtures.length === 0 ? (
          <div className="empty">No games match these filters</div>
        ) : (
          <div className="admin-game-list">
            {filteredFixtures.map((fixture) => (
              <button
                className={`admin-game-row ${
                  activeFixture?.id === fixture.id ? "active" : ""
                }`}
                key={fixture.id}
                onClick={() => setActiveFixtureId(fixture.id)}
                type="button"
              >
                <div>
                  <div className="event-title">
                    {fixture.homeClan.tag} vs {fixture.awayClan.tag}
                    {fixture.matchKind === "SOLO" ? " · SOLO" : ""}
                  </div>
                  <div className="event-subtitle">
                    {fixture.matchDate} · {fixture.timeSlot} ·{" "}
                    {assignedRefereeName(assignments, fixture.id)}
                  </div>
                  {fixture.status === "CANCELLED" && fixture.cancellationReason ? (
                    <div className="event-subtitle">{fixture.cancellationReason}</div>
                  ) : null}
                </div>
                <div className="event-minute">
                  {scoreFor(fixture, fixture.homeClan.id)}-
                  {scoreFor(fixture, fixture.awayClan.id)}
                </div>
              </button>
            ))}
          </div>
        )}
      </section>

      {activeFixture ? (
        <>
          {activeFixture.status === "CANCELLED" ? (
            <section className="panel">
              <div className="panel-heading">
                <h2 className="panel-title">Cancellation</h2>
                <span className="small-text">
                  {activeFixture.cancellationCode ?? "LEGACY_OTHER"}
                </span>
              </div>
              <p className="small-text">
                {activeFixture.cancellationReason ??
                  "No cancellation reason was recorded."}
              </p>
              {activeFixture.cancelledAt ? (
                <div className="event-subtitle">
                  Recorded {new Date(activeFixture.cancelledAt).toLocaleString()}
                </div>
              ) : null}
            </section>
          ) : (
            <TimerPanel
              key={activeFixture.id}
              fixture={activeFixture}
              submitting={submitting}
              onRunAction={(body) => onRunAction(activeFixture.id, body)}
            />
          )}

          {isFinal ? (
            <RatedResultLockedPanel />
          ) : (
            <ActionPanel
              title="Goal"
              fixture={activeFixture}
              selectedClanId={goalClanId || activeFixture.homeClan.id}
              selectedPlayerId={goalPlayerId}
              players={goalPlayers}
              submitting={submitting}
              disabled={!canRecordLive}
              onTeam={(clanId) => {
                setGoalClanId(clanId);
                setGoalPlayerId(playersForClan(activeFixture, clanId)[0]?.id ?? "");
                setAssistPlayerId("");
              }}
              onPlayer={setGoalPlayerId}
              extra={
                <PlayerSelect
                  label="Assist"
                  optional
                  value={assistPlayerId}
                  players={goalPlayers.filter((player) => player.id !== goalPlayerId)}
                  onChange={setAssistPlayerId}
                />
              }
              buttonLabel="Goal"
              onSubmit={() =>
                onRunAction(activeFixture.id, {
                  action: "goal",
                  clanId: goalClanId || activeFixture.homeClan.id,
                  profileId: goalPlayerId,
                  assistProfileId: assistPlayerId || null,
                })
              }
            />
          )}

          <ActionPanel
            title="Blue Card"
            fixture={activeFixture}
            selectedClanId={cardClanId || activeFixture.homeClan.id}
            selectedPlayerId={cardPlayerId}
            players={cardPlayers}
            submitting={submitting}
            disabled={activeFixture.status !== "LIVE"}
            onTeam={(clanId) => {
              setCardClanId(clanId);
              setCardPlayerId(playersForClan(activeFixture, clanId)[0]?.id ?? "");
            }}
            onPlayer={setCardPlayerId}
            buttonLabel="Start 2:00"
            dark
            onSubmit={() =>
              onRunAction(activeFixture.id, {
                action: "blue_card",
                clanId: cardClanId || activeFixture.homeClan.id,
                profileId: cardPlayerId,
              })
            }
          />

          <section className="panel">
            <div className="panel-heading">
              <h2 className="panel-title">Active Blue Cards</h2>
            </div>
            <ActiveBlueCards
              fixture={activeFixture}
              cards={activeFixture.blueCards}
              submitting={submitting}
              onReturn={(cardId) =>
                onRunAction(activeFixture.id, {
                  action: "expire_blue_card",
                  blueCardId: cardId,
                })
              }
            />
          </section>

          <section className="panel">
            <div className="panel-heading">
              <h2 className="panel-title">Timeline</h2>
              <button className="ghost-button" onClick={onRefresh} type="button">
                Refresh
              </button>
            </div>
            <EventList fixture={activeFixture} limit={30} />
          </section>
        </>
      ) : null}
    </>
  );
}

function GamesView({
  accessToken,
  activeFixture,
  fixtures,
  isLoading,
  submitting,
  goalClanId,
  goalPlayerId,
  assistPlayerId,
  cardClanId,
  cardPlayerId,
  goalPlayers,
  cardPlayers,
  onSelectFixture,
  onGoalClan,
  onGoalPlayer,
  onAssistPlayer,
  onCardClan,
  onCardPlayer,
  onRunAction,
  onRefresh,
}: {
  accessToken: string;
  activeFixture: RefereeFixture | null;
  fixtures: RefereeFixture[];
  isLoading: boolean;
  submitting: string | null;
  goalClanId: string;
  goalPlayerId: string;
  assistPlayerId: string;
  cardClanId: string;
  cardPlayerId: string;
  goalPlayers: Player[];
  cardPlayers: Player[];
  onSelectFixture: (fixtureId: string) => void;
  onGoalClan: (clanId: string) => void;
  onGoalPlayer: (playerId: string) => void;
  onAssistPlayer: (playerId: string) => void;
  onCardClan: (clanId: string) => void;
  onCardPlayer: (playerId: string) => void;
  onRunAction: (
    body: FixtureActionBody,
  ) => Promise<void>;
  onRefresh: () => void;
}) {
  if (fixtures.length === 0) {
    return (
      <section className="panel">
        <div className="utility-row">
          <div>
            <h2 className="panel-title">No Assigned Games</h2>
            <p className="small-text">Assigned matches will show here.</p>
          </div>
          <button
            className="ghost-button"
            disabled={isLoading}
            onClick={onRefresh}
            type="button"
          >
            Refresh
          </button>
        </div>
      </section>
    );
  }

  if (!activeFixture) return null;

  return (
    <>
      <div className="fixture-strip">
        {fixtures.map((fixture) => (
          <button
            className={`fixture-card ${
              fixture.id === activeFixture.id ? "active" : ""
            }`}
            key={fixture.id}
            onClick={() => onSelectFixture(fixture.id)}
            type="button"
          >
            <div className="fixture-meta">
              <span>
                {fixture.matchDate} · {fixture.matchKind === "SOLO" ? "SOLO" : "CLAN"}
              </span>
              <span>{fixture.status}</span>
            </div>
            <div className="versus">
              <TeamPill clan={fixture.homeClan} />
              <div className="vs-mark">VS</div>
              <TeamPill clan={fixture.awayClan} alignEnd />
            </div>
          </button>
        ))}
      </div>

      <BroadcastControl fixture={activeFixture} accessToken={accessToken} />

      <TimerPanel
        key={activeFixture.id}
        fixture={activeFixture}
        submitting={submitting}
        onRunAction={onRunAction}
      />

      {activeFixture.status === "FINAL" ? (
        <RatedResultLockedPanel />
      ) : (
        <ActionPanel
          title="Goal"
          fixture={activeFixture}
          selectedClanId={goalClanId || activeFixture.homeClan.id}
          selectedPlayerId={goalPlayerId}
          players={goalPlayers}
          submitting={submitting}
          onTeam={(clanId) => {
            onGoalClan(clanId);
            onGoalPlayer(playersForClan(activeFixture, clanId)[0]?.id ?? "");
            onAssistPlayer("");
          }}
          onPlayer={onGoalPlayer}
          extra={
            <PlayerSelect
              label="Assist"
              optional
              value={assistPlayerId}
              players={goalPlayers.filter((player) => player.id !== goalPlayerId)}
              onChange={onAssistPlayer}
            />
          }
          buttonLabel="Goal"
          onSubmit={() =>
            onRunAction({
              action: "goal",
              clanId: goalClanId || activeFixture.homeClan.id,
              profileId: goalPlayerId,
              assistProfileId: assistPlayerId || null,
            })
          }
        />
      )}

      <ActionPanel
        title="Blue Card"
        fixture={activeFixture}
        selectedClanId={cardClanId || activeFixture.homeClan.id}
        selectedPlayerId={cardPlayerId}
        players={cardPlayers}
        submitting={submitting}
        onTeam={(clanId) => {
          onCardClan(clanId);
          onCardPlayer(playersForClan(activeFixture, clanId)[0]?.id ?? "");
        }}
        onPlayer={onCardPlayer}
        buttonLabel="Start 2:00"
        dark
        onSubmit={() =>
          onRunAction({
            action: "blue_card",
            clanId: cardClanId || activeFixture.homeClan.id,
            profileId: cardPlayerId,
          })
        }
      />

      <section className="panel">
        <div className="panel-heading">
          <h2 className="panel-title">Active Blue Cards</h2>
        </div>
        <ActiveBlueCards
          fixture={activeFixture}
          cards={activeFixture.blueCards}
          submitting={submitting}
          onReturn={(cardId) =>
            onRunAction({
              action: "expire_blue_card",
              blueCardId: cardId,
            })
          }
        />
      </section>

      <section className="panel">
        <div className="panel-heading">
          <h2 className="panel-title">Log</h2>
          <button className="ghost-button" onClick={onRefresh} type="button">
            Refresh
          </button>
        </div>
        <EventList fixture={activeFixture} />
      </section>
    </>
  );
}

function BroadcastControl({
  fixture,
  accessToken,
}: {
  fixture: RefereeFixture;
  accessToken: string;
}) {
  const [state, setState] = useState<BroadcastControlResponse>({
    broadcast: null,
    device: null,
  });
  const [isLoading, setIsLoading] = useState(true);
  const [action, setAction] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async (quiet = false) => {
    if (!quiet) setIsLoading(true);
    try {
      const broadcastUrl = fixture.matchKind === "SOLO"
        ? `/api/referee/open-queue-games/${fixture.id}/broadcast`
        : `/api/referee/fixtures/${fixture.id}/broadcast`;
      const response = await fetch(
        broadcastUrl,
        {
          headers: { authorization: `Bearer ${accessToken}` },
          cache: "no-store",
        },
      );
      const payload = (await response.json()) as BroadcastControlResponse & {
        error?: string;
      };
      if (!response.ok) throw new Error(payload.error ?? "Could not load stream status.");
      setState(payload);
      setError(null);
    } catch (loadError) {
      if (!quiet) {
        setError(loadError instanceof Error ? loadError.message : "Stream status failed.");
      }
    } finally {
      if (!quiet) setIsLoading(false);
    }
  }, [accessToken, fixture.id, fixture.matchKind]);

  useEffect(() => {
    void load();
    const timer = window.setInterval(() => void load(true), 2_500);
    return () => window.clearInterval(timer);
  }, [load]);

  async function run(nextAction: "start" | "stop") {
    setAction(nextAction);
    setError(null);
    try {
      const broadcastUrl = fixture.matchKind === "SOLO"
        ? `/api/referee/open-queue-games/${fixture.id}/broadcast`
        : `/api/referee/fixtures/${fixture.id}/broadcast`;
      const response = await fetch(
        broadcastUrl,
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${accessToken}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ action: nextAction }),
        },
      );
      const payload = (await response.json()) as BroadcastControlResponse & {
        error?: string;
      };
      if (!response.ok) throw new Error(payload.error ?? "Stream action failed.");
      setState(payload);
    } catch (actionError) {
      setError(actionError instanceof Error ? actionError.message : "Stream action failed.");
    } finally {
      setAction(null);
    }
  }

  const status = state.broadcast?.status ?? "NOT_CONFIGURED";
  const deviceStreamingThisMatch = state.device?.obsStreaming === true &&
    (fixture.matchKind === "SOLO"
      ? state.device.currentOpenQueueGameId === fixture.id &&
        !state.device.currentFixtureId
      : state.device.currentFixtureId === fixture.id &&
        !state.device.currentOpenQueueGameId);
  const deviceBusy = state.device?.obsStreaming === true &&
    !deviceStreamingThisMatch;
  const deviceReady = state.device?.obsConnected === true &&
    state.device.status !== "OFFLINE" &&
    !deviceBusy;
  const streamActive = ["STARTING", "LIVE", "STOPPING"].includes(status);
  const canStart = deviceReady &&
    (fixture.matchKind === "SOLO"
      ? ["FULL", "LIVE"].includes(fixture.status)
      : ["SCHEDULED", "LIVE"].includes(fixture.status)) &&
    !streamActive &&
    status !== "PROCESSING";

  return (
    <section className="panel broadcast-control">
      <div className="broadcast-control-heading">
        <div>
          <div className="broadcast-eyebrow">Broadcast</div>
          <h2 className="panel-title">{broadcastStatusLabel(status)}</h2>
        </div>
        <span className={`broadcast-status-dot ${status.toLowerCase()}`} />
      </div>

      <div className="camera-readiness">
        <span className={`camera-dot ${deviceReady ? "ready" : ""}`} />
        <div>
          <strong>
            {deviceBusy
              ? "Camera in use"
              : deviceReady
              ? "Camera ready"
              : "Camera offline"}
          </strong>
          <span>
            {deviceBusy
              ? "Another match is currently streaming"
              : state.device?.displayName ??
                "Open the Field broadcaster on the camera laptop"}
          </span>
        </div>
      </div>

      {error || state.broadcast?.errorMessage ? (
        <div className="broadcast-error">{error ?? state.broadcast?.errorMessage}</div>
      ) : null}

      <div className="broadcast-actions">
        {streamActive ? (
          <button
            className="danger-button"
            disabled={deviceBusy || action !== null || status === "STOPPING"}
            onClick={() => void run("stop")}
            type="button"
          >
            {status === "STOPPING" ? "Stopping..." : "Stop Stream"}
          </button>
        ) : (
          <button
            className="primary-button"
            disabled={!canStart || action !== null || isLoading}
            onClick={() => void run("start")}
            type="button"
          >
            {action === "start" ? "Starting..." : "Start Stream"}
          </button>
        )}
      </div>
      <p className="broadcast-hint">
        Starting the stream keeps the match clock at 00:00. Use Start below at kickoff.
      </p>
    </section>
  );
}

function broadcastStatusLabel(status: string) {
  switch (status) {
    case "READY":
      return "Ready to stream";
    case "STARTING":
      return "Connecting camera";
    case "LIVE":
      return "Stream is live";
    case "STOPPING":
      return "Finishing broadcast";
    case "PROCESSING":
      return "Preparing replay";
    case "REPLAY_READY":
      return "Replay ready";
    case "ERROR":
      return "Stream needs attention";
    default:
      return "Not started";
  }
}

function TimerPanel({
  fixture,
  submitting,
  onRunAction,
}: {
  fixture: RefereeFixture;
  submitting: string | null;
  onRunAction: (
    body: FixtureActionBody,
  ) => Promise<void>;
}) {
  const status = fixture.clock?.status ?? "NOT_STARTED";
  const now = useNowMs(status === "RUNNING");
  const rawElapsedSeconds = elapsedFromClock(fixture.clock, now);
  const elapsedSeconds = Math.min(rawElapsedSeconds, MAX_MATCH_SECONDS);
  const duration = fixture.clock?.durationSeconds ?? 3600;
  const progress = Math.min(1, elapsedSeconds / duration);
  const isClosed = fixture.status === "FINAL" || status === "ENDED";
  const isBeforeStart = status === "NOT_STARTED" &&
    (fixture.matchKind === "SOLO"
      ? fixture.status === "FULL"
      : fixture.status === "SCHEDULED");
  const [selectedParticipantIds, setSelectedParticipantIds] = useState<string[]>(
    () => (isBeforeStart ? [] : fixture.participantIds),
  );
  const [correctedMinutes, setCorrectedMinutes] = useState(
    String(Math.floor(elapsedSeconds / 60)),
  );
  const [correctedSeconds, setCorrectedSeconds] = useState(
    String(elapsedSeconds % 60).padStart(2, "0"),
  );
  const autoStopFixtureId = useRef<string | null>(null);

  useEffect(() => {
    if (!isClosed) return;
    setCorrectedMinutes(String(Math.floor(elapsedSeconds / 60)));
    setCorrectedSeconds(String(elapsedSeconds % 60).padStart(2, "0"));
  }, [elapsedSeconds, fixture.id, isClosed]);

  useEffect(() => {
    if (
      status !== "RUNNING" ||
      rawElapsedSeconds < MAX_MATCH_SECONDS ||
      autoStopFixtureId.current === fixture.id
    ) {
      return;
    }

    autoStopFixtureId.current = fixture.id;
    void onRunAction({ action: "finish" });
  }, [fixture.id, onRunAction, rawElapsedSeconds, status]);

  const correctedMinuteValue = Number(correctedMinutes);
  const correctedSecondValue = Number(correctedSeconds);
  const correctedElapsedSeconds =
    correctedMinuteValue * 60 + correctedSecondValue;
  const hasValidCorrection =
    correctedMinutes.trim().length > 0 &&
    correctedSeconds.trim().length > 0 &&
    Number.isInteger(correctedMinuteValue) &&
    Number.isInteger(correctedSecondValue) &&
    correctedMinuteValue >= 0 &&
    correctedSecondValue >= 0 &&
    correctedSecondValue <= 59 &&
    correctedElapsedSeconds <= MAX_MATCH_SECONDS;
  const selectedHomeCount = selectedParticipantIds.filter((profileId) =>
    playersForClan(fixture, fixture.homeClan.id).some(
      (player) => player.id === profileId,
    )
  ).length;
  const selectedAwayCount = selectedParticipantIds.filter((profileId) =>
    playersForClan(fixture, fixture.awayClan.id).some(
      (player) => player.id === profileId,
    )
  ).length;
  const hasValidLineup = selectedHomeCount > 0 && selectedAwayCount > 0;

  function setPlayerSelected(profileId: string, selected: boolean) {
    setSelectedParticipantIds((current) =>
      selected
        ? [...new Set([...current, profileId])]
        : current.filter((id) => id !== profileId)
    );
  }

  function setClanSelected(clanId: string, selected: boolean) {
    const clanPlayerIds = playersForClan(fixture, clanId).map(
      (player) => player.id,
    );
    setSelectedParticipantIds((current) => {
      if (selected) return [...new Set([...current, ...clanPlayerIds])];
      const clanPlayerIdSet = new Set(clanPlayerIds);
      return current.filter((id) => !clanPlayerIdSet.has(id));
    });
  }

  return (
    <section className="timer-card">
      <div className="score-row">
        <ScoreTeam fixture={fixture} clanId={fixture.homeClan.id} />
        <div className="score-value">
          {scoreFor(fixture, fixture.homeClan.id)}
          <span style={{ color: "rgba(255,255,255,0.35)" }}>:</span>
          {scoreFor(fixture, fixture.awayClan.id)}
        </div>
        <ScoreTeam fixture={fixture} clanId={fixture.awayClan.id} alignEnd />
      </div>
      {fixture.matchKind === "SOLO" ? (
        <div className="solo-sr-summary">
          <span>
            <strong>{formatPlayerSr(fixture.matchAverageSr)}</strong>
            Match avg player SR
          </span>
          <span>
            <strong>{formatPlayerSr(fixture.teamSrSpread)}</strong>
            Team SR spread
          </span>
        </div>
      ) : null}
      <div className="clock">
        <div className="clock-time">{formatClock(elapsedSeconds)}</div>
        <div className="clock-state">{status}</div>
      </div>
      <div className="progress">
        <span style={{ width: `${progress * 100}%` }} />
      </div>
      <LineupPanel
        fixture={fixture}
        participantIds={
          isBeforeStart ? selectedParticipantIds : fixture.participantIds
        }
        editable={isBeforeStart}
        onPlayerSelected={setPlayerSelected}
        onClanSelected={setClanSelected}
      />
      <div className={status === "RUNNING" ? "control-grid" : "control-grid single"}>
        {isClosed ? (
          <button className="ghost-button" disabled type="button">
            Final
          </button>
        ) : status === "RUNNING" ? (
          <button
            className="ghost-button"
            disabled={submitting !== null}
            onClick={() => void onRunAction({ action: "pause" })}
            type="button"
          >
            Pause
          </button>
        ) : status === "PAUSED" ? (
          <button
            className="primary-button"
            disabled={submitting !== null}
            onClick={() => void onRunAction({ action: "resume" })}
            type="button"
          >
            Resume
          </button>
        ) : (
          <button
            className="primary-button"
            disabled={submitting !== null || !isBeforeStart || !hasValidLineup}
            onClick={() =>
              void onRunAction({
                action: "start",
                durationSeconds: 3600,
                participantIds: selectedParticipantIds,
              })
            }
            type="button"
          >
            {!isBeforeStart && fixture.matchKind === "SOLO"
              ? "Solo game must be full"
              : hasValidLineup
              ? "Start"
              : "Select players from both teams"}
          </button>
        )}
        {status === "RUNNING" || status === "PAUSED" ? (
          <button
            className="danger-button"
            disabled={submitting !== null}
            onClick={() => void onRunAction({ action: "finish" })}
            type="button"
          >
            Finish
          </button>
        ) : null}
      </div>
      {isClosed ? (
        <div className="clock-editor">
          <div className="clock-editor-title">Correct match time</div>
          <div className="clock-editor-controls">
            <label>
              <span className="clock-editor-label">Minutes</span>
              <input
                className="clock-input"
                inputMode="numeric"
                min="0"
                max="180"
                onChange={(event) => setCorrectedMinutes(event.target.value)}
                type="number"
                value={correctedMinutes}
              />
            </label>
            <span className="clock-editor-separator">:</span>
            <label>
              <span className="clock-editor-label">Seconds</span>
              <input
                className="clock-input"
                inputMode="numeric"
                min="0"
                max="59"
                onChange={(event) => setCorrectedSeconds(event.target.value)}
                type="number"
                value={correctedSeconds}
              />
            </label>
            <button
              className="primary-button clock-save-button"
              disabled={submitting !== null || !hasValidCorrection}
              onClick={() =>
                void onRunAction({
                  action: "set_time",
                  elapsedSeconds: correctedElapsedSeconds,
                })
              }
              type="button"
            >
              Save time
            </button>
          </div>
          <div className="clock-editor-hint">Maximum 180:00</div>
        </div>
      ) : null}
    </section>
  );
}

function LineupPanel({
  fixture,
  participantIds,
  editable,
  onPlayerSelected,
  onClanSelected,
}: {
  fixture: RefereeFixture;
  participantIds: string[];
  editable: boolean;
  onPlayerSelected: (profileId: string, selected: boolean) => void;
  onClanSelected: (clanId: string, selected: boolean) => void;
}) {
  const participantIdSet = new Set(participantIds);
  const clans = [fixture.homeClan, fixture.awayClan];

  return (
    <div className="lineup-panel">
      <div className="lineup-heading">
        <div>
          <div className="lineup-title">
            {editable ? "Confirm lineup" : "Match lineup"}
          </div>
          <div className="lineup-hint">
            {editable
              ? fixture.matchKind === "SOLO"
                ? "Selected solo players receive Player SR from this match."
                : "Only selected clan players receive Player SR from this match."
              : fixture.matchKind === "SOLO"
                ? `${participantIds.length} solo players confirmed for Player SR`
                : `${participantIds.length} clan players confirmed for Player SR`}
          </div>
        </div>
        {!editable ? <span className="lineup-saved">Saved</span> : null}
      </div>

      <div className="lineup-teams">
        {clans.map((clan) => {
          const roster = fixture.players.filter(
            (player) => player.clanId === clan.id,
          );
          const selectedPlayers = roster.filter((player) =>
            participantIdSet.has(player.id)
          );
          const shownPlayers = editable ? roster : selectedPlayers;

          return (
            <div className="lineup-team" key={clan.id}>
              <div className="lineup-team-heading">
                <div>
                  <strong>{clan.tag}</strong>
                  <span>{selectedPlayers.length} selected</span>
                </div>
                {editable && roster.length > 0 ? (
                  <button
                    className="lineup-toggle"
                    onClick={() =>
                      onClanSelected(
                        clan.id,
                        selectedPlayers.length !== roster.length,
                      )
                    }
                    type="button"
                  >
                    {selectedPlayers.length === roster.length
                      ? "Clear"
                      : "Select all"}
                  </button>
                ) : null}
              </div>

              <div className="lineup-list">
                {shownPlayers.length === 0 ? (
                  <div className="lineup-empty">
                    {editable ? "No active players" : "No players saved"}
                  </div>
                ) : (
                  shownPlayers.map((player) => {
                    const isSelected = participantIdSet.has(player.id);
                    return (
                      <label
                        className={`lineup-player ${
                          isSelected ? "selected" : ""
                        } ${editable ? "editable" : ""}`}
                        key={player.id}
                      >
                        {editable ? (
                          <input
                            checked={isSelected}
                            onChange={(event) =>
                              onPlayerSelected(player.id, event.target.checked)
                            }
                            type="checkbox"
                          />
                        ) : (
                          <span className="lineup-check" aria-hidden="true">
                            ✓
                          </span>
                        )}
                        <span>
                          <strong>{player.displayName}</strong>
                          <small>
                            {player.role}
                            {fixture.matchKind === "SOLO"
                              ? ` · ${formatPlayerSr(player.ratingAtTeamAssignment)} SR at assignment`
                              : ""}
                          </small>
                        </span>
                      </label>
                    );
                  })
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function ActionPanel({
  title,
  fixture,
  selectedClanId,
  selectedPlayerId,
  players,
  submitting,
  onTeam,
  onPlayer,
  onSubmit,
  buttonLabel,
  extra,
  dark = false,
  disabled = false,
}: {
  title: string;
  fixture: RefereeFixture;
  selectedClanId: string;
  selectedPlayerId: string;
  players: Player[];
  submitting: string | null;
  onTeam: (clanId: string) => void;
  onPlayer: (playerId: string) => void;
  onSubmit: () => Promise<void>;
  buttonLabel: string;
  extra?: React.ReactNode;
  dark?: boolean;
  disabled?: boolean;
}) {
  return (
    <section className="panel">
      <div className="panel-heading">
        <h2 className="panel-title">{title}</h2>
      </div>
      <TeamSegment
        fixture={fixture}
        selectedClanId={selectedClanId}
        onSelect={onTeam}
      />
      <div className="form-grid">
        <PlayerSelect
          label="Player"
          value={selectedPlayerId}
          players={players}
          onChange={onPlayer}
        />
        {extra}
        <button
          className={dark ? "dark-button" : "primary-button"}
          disabled={disabled || !selectedPlayerId || submitting !== null}
          onClick={() => void onSubmit()}
          type="button"
        >
          {buttonLabel}
        </button>
      </div>
    </section>
  );
}

function TeamSegment({
  fixture,
  selectedClanId,
  onSelect,
}: {
  fixture: RefereeFixture;
  selectedClanId: string;
  onSelect: (clanId: string) => void;
}) {
  return (
    <div className="segmented">
      {[fixture.homeClan, fixture.awayClan].map((clan) => (
        <button
          className={`chip-button ${selectedClanId === clan.id ? "active" : ""}`}
          key={clan.id}
          onClick={() => onSelect(clan.id)}
          type="button"
        >
          {clan.tag}
        </button>
      ))}
    </div>
  );
}

function PlayerSelect({
  label,
  value,
  players,
  onChange,
  optional = false,
}: {
  label: string;
  value: string;
  players: Player[];
  onChange: (value: string) => void;
  optional?: boolean;
}) {
  return (
    <label>
      <span className="field-label">{label}</span>
      <select
        className="select"
        value={value}
        onChange={(event) => onChange(event.target.value)}
      >
        {optional ? <option value="">None</option> : null}
        {players.map((player) => (
          <option key={player.id} value={player.id}>
            {player.displayName}
          </option>
        ))}
      </select>
    </label>
  );
}

function TeamPill({
  clan,
  alignEnd = false,
}: {
  clan: RefereeFixture["homeClan"];
  alignEnd?: boolean;
}) {
  return (
    <div className={`team-pill ${alignEnd ? "end" : ""}`}>
      <div className="emblem">{clan.emblem}</div>
      <div className="tag">{clan.tag}</div>
      <div className="name">{clan.name}</div>
    </div>
  );
}

function ScoreTeam({
  fixture,
  clanId,
  alignEnd = false,
}: {
  fixture: RefereeFixture;
  clanId: string;
  alignEnd?: boolean;
}) {
  const clan = fixture.homeClan.id === clanId ? fixture.homeClan : fixture.awayClan;

  return (
    <div className={`score-team ${alignEnd ? "end" : ""}`}>
      <div className="emblem">{clan.emblem}</div>
      <div className="tag" style={{ color: "#fff" }}>
        {clan.tag}
      </div>
      <div className="name" style={{ color: "rgba(255,255,255,0.62)" }}>
        {fixture.matchKind === "SOLO"
          ? `${formatPlayerSr(teamAverageSr(fixture, clan.id))} AVG PLAYER SR`
          : `${clan.skillRating} SR`}
      </div>
    </div>
  );
}

function ActiveBlueCards({
  cards,
  fixture,
  submitting,
  onReturn,
}: {
  cards: BlueCard[];
  fixture: RefereeFixture;
  submitting: string | null;
  onReturn: (cardId: string) => Promise<void>;
}) {
  const activeCards = cards.filter((card) => card.status === "ACTIVE");
  const now = useNowMs(activeCards.length > 0);
  const alertedCardIds = useRef(new Set<string>());

  useEffect(() => {
    const expiredCards = activeCards.filter(
      (card) =>
        new Date(card.expiresAt).getTime() <= now &&
        !alertedCardIds.current.has(card.id),
    );

    if (expiredCards.length === 0) return;

    window.navigator.vibrate?.([220, 120, 220]);
    for (const card of expiredCards) {
      alertedCardIds.current.add(card.id);
    }
  }, [activeCards, now]);

  if (activeCards.length === 0) return <div className="empty">None</div>;

  return (
    <div className="blue-list">
      {activeCards.map((card) => {
        const remaining = Math.max(
          0,
          Math.ceil((new Date(card.expiresAt).getTime() - now) / 1000),
        );
        return (
          <div className="blue-card-row" key={card.id}>
            <div>
              <div className="event-title">{playerName(fixture, card.profileId)}</div>
              <div className="event-subtitle">{clanTag(fixture, card.clanId)}</div>
            </div>
            <div className={`countdown ${remaining === 0 ? "expired" : ""}`}>
              {formatClock(remaining)}
            </div>
            {remaining === 0 ? (
              <button
                className="dark-button"
                disabled={submitting !== null}
                onClick={() => void onReturn(card.id)}
                type="button"
              >
                Returned
              </button>
            ) : null}
          </div>
        );
      })}
    </div>
  );
}

function RatedResultLockedPanel() {
  return (
    <section className="panel">
      <h2 className="panel-title">Rated result locked</h2>
      <p className="small-text">
        Goals cannot be added or removed after full time. The final score is now
        the audit record used for Player SR.
      </p>
    </section>
  );
}

function EventList({
  fixture,
  limit = 12,
}: {
  fixture: RefereeFixture;
  limit?: number;
}) {
  if (fixture.events.length === 0) return <div className="empty">No events</div>;

  return (
    <div className="event-list">
      {fixture.events.slice(0, limit).map((event) => (
        <div className="event-card" key={event.id}>
          <div>
            <div className="event-title">{eventTitle(fixture, event)}</div>
            <div className="event-subtitle">{eventSubtitle(fixture, event)}</div>
          </div>
          <div className="event-minute">
            {event.minute}:{event.second.toString().padStart(2, "0")}
          </div>
        </div>
      ))}
    </div>
  );
}

function eventTitle(fixture: RefereeFixture, event: FixtureEvent) {
  if (event.eventType === "GOAL") return `Goal · ${playerName(fixture, event.profileId)}`;
  if (event.eventType === "BLUE_CARD") {
    return `Blue card · ${playerName(fixture, event.profileId)}`;
  }
  if (event.eventType === "BLUE_CARD_EXPIRED") {
    return `Returned · ${playerName(fixture, event.profileId)}`;
  }
  if (event.eventType === "CORRECTION") return "Admin correction";
  return event.eventType.replaceAll("_", " ");
}

function eventSubtitle(fixture: RefereeFixture, event: FixtureEvent) {
  const team = event.clanId ? clanTag(fixture, event.clanId) : "Match";
  if (event.eventType === "CORRECTION" && event.note) {
    return `${team}, ${event.note}`;
  }
  if (event.eventType === "GOAL" && event.assistProfileId) {
    return `${team}, assist ${playerName(fixture, event.assistProfileId)}`;
  }
  return team;
}

function playersForClan(fixture: RefereeFixture, clanId: string) {
  const clanPlayers = fixture.players.filter((player) => player.clanId === clanId);
  if (
    !["LIVE", "FINAL"].includes(fixture.status) ||
    fixture.participantIds.length === 0
  ) {
    return clanPlayers;
  }

  const participantIdSet = new Set(fixture.participantIds);
  return clanPlayers.filter((player) => participantIdSet.has(player.id));
}

function teamAverageSr(fixture: RefereeFixture, clanId: string) {
  return fixture.homeClan.id === clanId
    ? fixture.whiteAverageSr
    : fixture.blackAverageSr;
}

function scoreFor(fixture: RefereeFixture, clanId: string) {
  if (fixture.goals.length > 0) {
    return fixture.goals.filter((goal) => goal.clanId === clanId).length;
  }
  if (fixture.homeClan.id === clanId) return fixture.homeScore ?? 0;
  if (fixture.awayClan.id === clanId) return fixture.awayScore ?? 0;
  return 0;
}

function playerName(fixture: RefereeFixture, profileId: string | null) {
  if (!profileId) return "Unknown";
  return fixture.players.find((player) => player.id === profileId)?.displayName ?? "Unknown";
}

function clanTag(fixture: RefereeFixture, clanId: string) {
  if (fixture.homeClan.id === clanId) return fixture.homeClan.tag;
  if (fixture.awayClan.id === clanId) return fixture.awayClan.tag;
  return "TEAM";
}

function assignedRefereeFor(
  assignments: RefereeAssignmentsResponse,
  fixtureId: string,
) {
  return (
    assignments.fixtures.find((fixture) => fixture.id === fixtureId)
      ?.assignedRefereeId ?? ""
  );
}

function assignedRefereeName(
  assignments: RefereeAssignmentsResponse,
  fixtureId: string,
) {
  const refereeId = assignedRefereeFor(assignments, fixtureId);
  if (!refereeId) return "Unassigned";
  return (
    assignments.referees.find((referee) => referee.profileId === refereeId)
      ?.displayName ?? "Assigned"
  );
}

function useNowMs(enabled: boolean) {
  const [now, setNow] = useState(Date.now());

  useEffect(() => {
    if (!enabled) return;
    const interval = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(interval);
  }, [enabled]);

  return now;
}

function elapsedFromClock(clock: FixtureClock | null, now: number) {
  if (!clock) return 0;
  if (clock.status !== "RUNNING" || !clock.startedAt) {
    return Math.max(0, clock.accumulatedSeconds);
  }
  const startedAt = new Date(clock.startedAt).getTime();
  return Math.max(
    0,
    clock.accumulatedSeconds + Math.floor((now - startedAt) / 1000),
  );
}

function formatClock(totalSeconds: number) {
  const safeSeconds = Math.max(0, Math.floor(totalSeconds));
  const minutes = Math.floor(safeSeconds / 60);
  const seconds = safeSeconds % 60;
  return `${minutes}:${seconds.toString().padStart(2, "0")}`;
}

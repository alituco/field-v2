"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { useCallback, useEffect, useRef, useState } from "react";
import { LoadingSkeleton } from "@/components/loading-skeleton";
import { SeasonZeroRatingReviewPanel } from "@/components/season-zero-rating-review-panel";
import { AdminUnassignedPlayersPanel } from "@/components/admin-unassigned-players-panel";
import { GameFormationPanel } from "../../../game-formation-panel";

import type {
  AdminGameDetail,
  AdminGameResolutionCase,
  AdminGameResolutionRefund,
} from "@/lib/admin-game-detail";
import type { AdminGameParticipant } from "@/lib/admin-game-participants";
import { formatGameMoney, type AdminGameCurrency } from "@/lib/admin-game-money";
import type { AdminGamePricing } from "@/lib/admin-game-pricing";
import type {
  AdminGameReserve,
  AdminReserveCandidate,
} from "@/lib/admin-game-reserves";
import {
  hasGuaranteedNoSrChange,
  playerSrConsequenceLabel,
} from "@/lib/admin-match-resolution-ui";
import type { MatchResolutionType } from "@/lib/match-action-input";
import { createSupabaseBrowserClient } from "@/lib/supabase-browser";
import { refundRetryNotice } from "@/lib/payment-refunds";
import { soloGameReadiness, soloMinimumHint } from "@/lib/solo-game-readiness";
import {
  canFillGameWithBots,
  isStagingGameBotsEnabled,
  validateStagingBotFillReply,
} from "@/lib/staging-game-bots";
import type {
  BroadcastControlResponse,
  FixtureEvent,
  RefereeAssignmentsResponse,
  RefereeFixture,
} from "@/lib/types";

import styles from "./game-detail.module.css";

const supabase = createSupabaseBrowserClient();

export default function AdminGameDetailPage() {
  const params = useParams<{ matchKind: string; gameId: string }>();
  const matchKind = String(params.matchKind ?? "").toUpperCase();
  const gameId = String(params.gameId ?? "");
  const [accessToken, setAccessToken] = useState<string | null>(null);
  const [sessionChecked, setSessionChecked] = useState(false);
  const [detail, setDetail] = useState<AdminGameDetail | null>(null);
  const [broadcast, setBroadcast] = useState<BroadcastControlResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [addingReserve, setAddingReserve] = useState(false);
  const [removeReserve, setRemoveReserve] = useState<AdminGameReserve | null>(null);
  const [playerAction, setPlayerAction] = useState<AdminGameParticipant | null>(null);
  const [clanActionId, setClanActionId] = useState<string | null>(null);
  const [assignReferee, setAssignReferee] = useState(false);
  const [cancelGame, setCancelGame] = useState(false);
  const [editingPrice, setEditingPrice] = useState(false);
  const [confirmLockTeams, setConfirmLockTeams] = useState(false);
  const [lockingTeams, setLockingTeams] = useState(false);
  const [confirmFillBots, setConfirmFillBots] = useState(false);
  const [fillingBots, setFillingBots] = useState(false);
  const [resolveCase, setResolveCase] = useState(false);
  const [kickoffEvidence, setKickoffEvidence] = useState<{ gameId: string; hasKickoff: boolean } | null>(null);
  const receiveKickoffEvidence = useCallback((evidenceGameId: string, hasKickoff: boolean | null) => {
    setKickoffEvidence(hasKickoff === null ? null : { gameId: evidenceGameId, hasKickoff });
  }, []);
  const [retryRefund, setRetryRefund] =
    useState<AdminGameResolutionRefund | null>(null);
  const mounted = useRef(true);
  const pageKey = `${matchKind}:${gameId}`;
  const pageIdentity = `${pageKey}:${accessToken ?? ""}`;
  const currentPageIdentity = useRef(pageIdentity);
  currentPageIdentity.current = pageIdentity;
  const botFillRequest = useRef<{ pageKey: string; requestId: string } | null>(null);

  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; };
  }, []);

  useEffect(() => {
    setConfirmFillBots(false);
    setFillingBots(false);
    if (botFillRequest.current?.pageKey !== pageKey) botFillRequest.current = null;
  }, [pageKey, accessToken]);

  const load = useCallback(async (quiet = false, expectedPageIdentity?: string) => {
    if (!accessToken || !gameId || !["SOLO", "CLAN"].includes(matchKind)) return;
    const canApply = () => mounted.current &&
      (expectedPageIdentity === undefined || currentPageIdentity.current === expectedPageIdentity);
    if (!canApply()) return;
    if (!quiet) setLoading(true);
    setError(null);
    try {
      const payload = await fetchJson<{ detail: AdminGameDetail }>(
        `/api/referee/admin/games/${matchKind.toLowerCase()}/${gameId}`,
        { headers: auth(accessToken), cache: "no-store" },
      );
      if (!canApply()) return;
      setDetail(payload.detail);
      return payload.detail;
    } catch (loadError) {
      if (canApply()) setError(message(loadError, "Could not load this game."));
    } finally {
      if (canApply()) setLoading(false);
    }
  }, [accessToken, gameId, matchKind]);

  useEffect(() => {
    void supabase.auth.getSession().then(({ data }) => {
      setAccessToken(data.session?.access_token ?? null);
      setSessionChecked(true);
    });
    const { data: listener } = supabase.auth.onAuthStateChange((_event, session) => {
      setAccessToken(session?.access_token ?? null);
      setSessionChecked(true);
    });
    return () => listener.subscription.unsubscribe();
  }, []);

  useEffect(() => {
    if (accessToken) void load();
    else if (sessionChecked) setLoading(false);
  }, [accessToken, load, sessionChecked]);

  async function loadRecording() {
    if (!accessToken || !detail) return;
    try {
      const path = detail.fixture.matchKind === "SOLO"
        ? `/api/referee/open-queue-games/${detail.fixture.id}/broadcast`
        : `/api/referee/fixtures/${detail.fixture.id}/broadcast`;
      setBroadcast(await fetchJson(path, {
        headers: auth(accessToken),
        cache: "no-store",
      }));
    } catch (recordingError) {
      setError(message(recordingError, "Could not load the match recording."));
    }
  }

  async function fillWithBots() {
    if (!accessToken || !detail || detail.fixture.id !== gameId ||
      detail.fixture.matchKind !== matchKind || fillingBots || lockingTeams ||
      !isStagingGameBotsEnabled() || !canFillGameWithBots(detail.fixture)) return;
    if (!confirmFillBots) {
      setConfirmLockTeams(false);
      setConfirmFillBots(true);
      return;
    }
    const expectedPage = currentPageIdentity.current;
    const targetGameId = detail.fixture.id;
    const request = botFillRequest.current?.pageKey === pageKey
      ? botFillRequest.current
      : { pageKey, requestId: crypto.randomUUID() };
    botFillRequest.current = request;
    const canApply = () => mounted.current && currentPageIdentity.current === expectedPage;
    setFillingBots(true);
    setError(null);
    try {
      const payload = await fetchJson<unknown>(
        `/api/referee/admin/games/solo/${targetGameId}/fill-bots`,
        {
          method: "POST",
          headers: { ...auth(accessToken), "Content-Type": "application/json" },
          body: JSON.stringify({ requestId: request.requestId, confirmation: "FILL_WITH_BOTS" }),
        },
      );
      const result = validateStagingBotFillReply(payload, { gameId: targetGameId, requestId: request.requestId });
      if (!canApply()) return;
      botFillRequest.current = null;
      setConfirmFillBots(false);
      setNotice(result.createdBots > 0
        ? `Added ${result.createdBots} staging bots. ${result.confirmedCount} / ${result.capacity} places are booked. Use Lock teams when you’re ready.`
        : "This game is already full. No bots were added.");
      await load(true, expectedPage);
    } catch (fillError) {
      if (canApply()) setError(message(fillError, "Could not fill this game with bots."));
    } finally {
      if (canApply()) setFillingBots(false);
    }
  }

  if (!sessionChecked || loading) return <GameDetailSkeleton />;
  if (!accessToken) {
    return (
      <main className={styles.statePage}>
        <span>FIELD ADMIN</span><h1>Sign in required</h1>
        <p>Use an active administrator account to open this game.</p>
        <Link href="/">Go to sign in</Link>
      </main>
    );
  }
  if (!detail) {
    return (
      <main className={styles.statePage}>
        <span>GAME OVERVIEW</span><h1>Game unavailable</h1>
        <p>{error ?? "This game could not be found."}</p>
        <button onClick={() => void load()} type="button">Try again</button>
        <Link href="/admin">Back to admin</Link>
      </main>
    );
  }

  const fixture = detail.fixture;
  const seasonZero = fixture.matchKind === "SOLO" && fixture.ratingPolicyId === "field-sr-season0-v2";
  const activeReserve = detail.reserves.active[0];
  const resolutionCase = detail.resolutionCase;
  const needsResolution = Boolean(
    resolutionCase &&
    ["NO_DATA", "UNDER_REVIEW"].includes(resolutionCase.state),
  );
  const unstartedSeasonZeroReview = seasonZero && needsResolution &&
    ["OPEN", "FULL"].includes(fixture.status) &&
    kickoffEvidence?.gameId === fixture.id && kickoffEvidence.hasKickoff === false;
  const canReviewCase = !seasonZero || unstartedSeasonZeroReview;
  const displayedStatus = resolutionDisplayStatus(detail);
  const rosterReadiness = soloGameReadiness(fixture,
    detail.participants.matchKind === "SOLO" ? detail.participants.counts.registered : 0);
  const canLockRoster = seasonZero ? rosterReadiness.minimumReached : fixture.status === "FULL";
  return (
    <main className={styles.page}>
      <header className={styles.topbar}>
        <Link className={styles.back} href="/admin?section=games">← <span>All games</span></Link>
        <div className={styles.brand}><i>F</i><span>FIELD ADMIN</span></div>
        <button onClick={() => void load(true)} type="button">Refresh</button>
      </header>

      {error ? <div className={styles.error} role="alert">{error}<button onClick={() => setError(null)}>×</button></div> : null}
      {notice ? <div className={styles.notice} role="status">{notice}<button onClick={() => setNotice(null)}>×</button></div> : null}

      {resolutionCase ? (
        <ResolutionCaseBanner
          caseData={resolutionCase}
          detail={detail}
          onResolve={canReviewCase ? () => setResolveCase(true) : undefined}
          onRetryRefund={setRetryRefund}
        />
      ) : null}

      <section className={styles.hero}>
        <div className={styles.heroMeta}>
          <span className={styles.kind}>{fixture.matchKind === "SOLO" ? "SOLO QUEUE" : "CLAN FIXTURE"}</span>
          <Status status={displayedStatus} />
        </div>
        <div className={styles.scoreboard}>
          <Team clan={fixture.homeClan} detail={detail} side="home" />
          <div className={styles.score}>
            <strong>{score(fixture)}</strong>
            <span>{displayedStatus === "NO_DATA" ? "NO DATA" : displayedStatus === "UNDER_REVIEW" ? "UNDER REVIEW" : fixture.status === "FINAL" ? "FINAL SCORE" : fixture.status === "LIVE" ? "LIVE" : "VS"}</span>
          </div>
          <Team clan={fixture.awayClan} detail={detail} side="away" align="right" />
        </div>
        <div className={styles.heroFacts}>
          <Fact label="Date" value={formatDate(fixture.matchDate)} />
          <Fact label="Kickoff" value={fixture.timeSlot} />
          <Fact label="Venue" value={fixture.venue} />
          <Fact label="Referee" value={detail.assignedReferee?.displayName ?? "Not assigned"} warning={!detail.assignedReferee} />
        </div>
      </section>

      <section className={styles.metrics}>
        <Metric label="Confirmed players" value={confirmedCount(detail)} detail={capacityLabel(detail)} />
        <Metric label="Checked in / played" value={String(detail.participants.actualPlayers.length)} detail="Official match record" />
        {!seasonZero ? <Metric label="Reserve player" value={`${detail.reserves.active.length} / 1`} detail="One game-wide standby" /> : <Metric label="Participation policy" value="Booked players only" detail="No substitutions or replacements" />}
        <Metric label="Reports" value={String(detail.reports.length)} detail={detail.reports.length ? "Needs awareness" : "No match reports"} tone={detail.reports.length ? "warning" : "good"} />
      </section>

      <div className={styles.grid}>
        <div className={styles.mainColumn}>
          {seasonZero ? <SeasonZeroRatingReviewPanel key={fixture.id} fixture={fixture} accessToken={accessToken} onEvidenceLoaded={receiveKickoffEvidence} onSaved={async () => { await load(true); }} /> : null}
          {!seasonZero ? <section className={styles.card}>
            <SectionHead eyebrow="MATCHDAY COVER" title="Reserve player" detail="Choose any eligible Field player as the single standby for this game. Assigning them does not charge them, place them in the playing squad, or change rating eligibility." />
            <div className={styles.reserveGrid}>
              <ReserveSlot
                reserve={activeReserve}
                locked={!canManageReserves(fixture.status)}
                onAdd={() => setAddingReserve(true)}
                onRemove={() => activeReserve && setRemoveReserve(activeReserve)}
              />
            </div>
            {detail.reserves.history.length ? (
              <details className={styles.history}>
                <summary>Previous reserve assignments · {detail.reserves.history.length}</summary>
                {detail.reserves.history.map((reserve) => (
                  <div key={reserve.id}>
                    <span>{reserve.displayName} · Game reserve</span>
                    <small>{reserve.removalReason} · {formatDateTime(reserve.removedAt)}</small>
                  </div>
                ))}
              </details>
            ) : null}
          </section> : null}

          {detail.pricing ? (
            <GamePricingPanel pricing={detail.pricing} onEdit={() => setEditingPrice(true)} />
          ) : null}
          {detail.formation ? <GameFormationPanel formation={detail.formation} accessToken={accessToken} gameId={fixture.id} onSaved={async () => {
            setNotice("Formation updated. Booking positions and party limits now use this game’s saved formation.");
            await load(true);
          }} /> : null}

          {seasonZero ? <AdminUnassignedPlayersPanel key={`unassigned:${fixture.id}`} fixture={fixture} accessToken={accessToken}
            busy={lockingTeams || fillingBots} onSaved={async () => {
              setNotice("Player assignments saved. Existing teams have been preserved.");
              await load(true);
            }} /> : null}

          <section className={styles.card}>
            <SectionHead eyebrow="OFFICIAL ROSTER" title="Players" detail="Confirmed, checked-in and historical participation for this game." />
            {fixture.matchKind === "SOLO" && ["OPEN", "FULL"].includes(fixture.status) ? <div>
              <p className={styles.actionHint}>Lock the booked roster into balanced White and Black teams, preserving parties and the saved formation. This releases team assignments and closes outstanding party invitations; it does not start the match or check players in.</p>
              {seasonZero ? <p className={styles.actionHint}>{rosterReadiness.minimumReached ? "Minimum reached" : `${rosterReadiness.minimumPlayers} confirmed players needed`} · {rosterReadiness.minimumPlayers} minimum / {rosterReadiness.capacity} maximum. {soloMinimumHint(fixture)}</p> : null}
              {confirmLockTeams ? <p>Assign and release both teams now?</p> : null}
              <button type="button" className={styles.primaryButton}
                disabled={lockingTeams || fillingBots || !canLockRoster || Boolean(fixture.teamsAssignedAt) || fixture.operationalState !== "NORMAL"}
                onClick={async () => {
                  setConfirmFillBots(false);
                  if (!confirmLockTeams) { setConfirmLockTeams(true); return; }
                  setLockingTeams(true);
                  setError(null);
                  try {
                    await fetchJson(`/api/referee/admin/games/solo/${fixture.id}/lock-teams`, {
                      method: "POST", headers: auth(accessToken),
                    });
                    setConfirmLockTeams(false);
                    setNotice("Teams locked. White and Black squads are ready; the match has not started.");
                    await load(true);
                  } catch (lockError) { setError(message(lockError, "Could not lock teams.")); }
                  finally { setLockingTeams(false); }
                }}>
                {lockingTeams ? "Locking teams…" : fixture.teamsAssignedAt ? "Teams locked" : confirmLockTeams ? "Confirm lock teams" : "Lock teams"}
              </button>
              {confirmLockTeams ? <button type="button" className={styles.cancelButton} disabled={lockingTeams} onClick={() => setConfirmLockTeams(false)}>Cancel</button> : null}
              {!canLockRoster ? <p className={styles.actionHint}>{seasonZero ? `Available once ${rosterReadiness.minimumPlayers} players are booked.` : "Available when all places are booked."}</p> : null}
            </div> : null}
            {fixture.id === gameId && fixture.matchKind === matchKind &&
              isStagingGameBotsEnabled() && canFillGameWithBots(fixture) ? (
              <div role="group" aria-label="Staging game tools">
                {confirmFillBots ? (
                  <p className={styles.actionHint}>Fill the remaining positions with clearly labeled staging bots? Existing players stay booked. No one is charged, checked in, or assigned to a team, and the match will not start.</p>
                ) : <p className={styles.actionHint}>Staging only · Add test players to the remaining positions.</p>}
                <button type="button" className={styles.cancelButton}
                  disabled={fillingBots || lockingTeams}
                  onClick={() => void fillWithBots()}>
                  {fillingBots ? "Adding bots…" : confirmFillBots ? "Confirm fill with bots" : "Fill game with bots"}
                </button>
                {confirmFillBots ? <button type="button" className={styles.cancelButton}
                  disabled={fillingBots} onClick={() => setConfirmFillBots(false)}>Cancel bot fill</button> : null}
              </div>
            ) : null}
            <ParticipantGroups detail={detail} onPlayerAction={setPlayerAction} />
          </section>

          <section className={styles.card}>
            <SectionHead eyebrow="MATCH RECORD" title="Timeline" detail="Match events, interventions and final-time actions." />
            <MatchTimeline fixture={fixture} />
          </section>
        </div>

        <aside className={styles.sideColumn}>
          <section className={styles.card}>
            <SectionHead eyebrow="OPERATIONS" title="Game state" />
            <dl className={styles.detailList}>
              <div><dt>Game ID</dt><dd>{fixture.id.slice(0, 8)}</dd></div>
              <div><dt>Clock</dt><dd>{fixture.clock ? humanize(fixture.clock.status) : "Not started"}</dd></div>
              {detail.ratingSummary.kind === "CLAN" ? (
                <>
                  <div><dt>{fixture.homeClan.tag} clan SR</dt><dd>{detail.ratingSummary.home.skillRating} · Bahrain #{detail.ratingSummary.home.bahrainRank ?? "—"}</dd></div>
                  <div><dt>{fixture.awayClan.tag} clan SR</dt><dd>{detail.ratingSummary.away.skillRating} · Bahrain #{detail.ratingSummary.away.bahrainRank ?? "—"}</dd></div>
                </>
              ) : (
                <>
                  <div><dt>White team average</dt><dd>{detail.ratingSummary.whiteAverageSr ?? "Not assigned"}</dd></div>
                  <div><dt>Black team average</dt><dd>{detail.ratingSummary.blackAverageSr ?? "Not assigned"}</dd></div>
                  <div><dt>Match average SR</dt><dd>{detail.ratingSummary.matchAverageSr ?? "Not available"}</dd></div>
                  <div><dt>Team spread</dt><dd>{detail.ratingSummary.teamSrSpread === null ? "Not available" : `${detail.ratingSummary.teamSrSpread} SR`}</dd></div>
                </>
              )}
              <div><dt>Referee phone</dt><dd>{detail.assignedReferee?.phone ?? "—"}</dd></div>
            </dl>
            {fixture.cancellationReason ? (
              <div className={styles.cancellation}><strong>{fixture.cancellationCode ?? "Cancelled"}</strong><p>{fixture.cancellationReason}</p></div>
            ) : null}
          </section>

          <section className={styles.card}>
            <SectionHead eyebrow="ADMIN CONTROLS" title="Resolve game issues" detail="Every action requires a reason and is permanently audited." />
            <div className={styles.adminActions}>
              {needsResolution && canReviewCase ? (
                <button
                  className={styles.primaryButton}
                  onClick={() => setResolveCase(true)}
                  type="button"
                >
                  {resolutionCase?.currentRevision
                    ? "Review or correct resolution"
                    : "Review & resolve no data"}
                </button>
              ) : null}
              <button
                className={styles.secondaryButton}
                disabled={!canAssignReferee(fixture.status)}
                onClick={() => setAssignReferee(true)}
                type="button"
              >
                {detail.assignedReferee ? "Change referee" : "Assign referee"}
              </button>
              {fixture.matchKind === "CLAN" ? (
                <div className={styles.clanActions}>
                  <button onClick={() => setClanActionId(fixture.homeClan.id)} type="button">
                    Report {fixture.homeClan.tag}
                  </button>
                  <button onClick={() => setClanActionId(fixture.awayClan.id)} type="button">
                    Report {fixture.awayClan.tag}
                  </button>
                </div>
              ) : null}
              <button
                className={styles.dangerButton}
                disabled={(needsResolution && !unstartedSeasonZeroReview) || !canCancelGame(fixture.status)}
                onClick={() => unstartedSeasonZeroReview ? setResolveCase(true) : setCancelGame(true)}
                type="button"
              >
                Cancel game
              </button>
            </div>
            <p className={styles.actionHint}>
              {unstartedSeasonZeroReview ? "No kickoff was recorded. Review cancellation to preview full refunds and close this unresolved game without adding a result or changing ratings."
                : seasonZero ? "Use Rating review for Season 0 outcomes and timeline corrections. Payment and refund controls remain separate."
                : needsResolution
                ? "Use the no-data review so attendance, refunds, SR and strikes are decided together."
                : "Admin cancellation gives every payer a full refund, including held reliability deposits. Card and digital wallet payments return to the original payment method."}
            </p>
          </section>

          <section className={styles.card}>
            <SectionHead eyebrow="VIDEO" title="Match recording" />
            {broadcast?.broadcast?.replayHlsUrl ? (
              <div className={styles.video}>
                <video controls playsInline preload="metadata" src={broadcast.broadcast.replayHlsUrl} />
                <a href={broadcast.broadcast.replayHlsUrl} target="_blank" rel="noreferrer">Open recording ↗</a>
              </div>
            ) : (
              <button className={styles.secondaryButton} onClick={() => void loadRecording()} type="button">
                {broadcast ? broadcast.broadcast?.status ?? "No recording" : "Check recording"}
              </button>
            )}
          </section>

          <section className={styles.card}>
            <SectionHead eyebrow="SAFETY" title="Reports & stoppages" />
            <SafetyList detail={detail} />
          </section>

          <section className={styles.card}>
            <SectionHead eyebrow="AUDIT" title="Admin history" />
            <AuditList detail={detail} />
          </section>
        </aside>
      </div>

      {editingPrice && detail.pricing ? (
        <EditGamePriceDialog
          accessToken={accessToken}
          gameId={fixture.id}
          pricing={detail.pricing}
          onClose={() => setEditingPrice(false)}
          onRefresh={async () => (await load(true))?.pricing ?? null}
          onSaved={async () => {
            setEditingPrice(false);
            setNotice("Game price updated for new bookings. Existing payments and refund amounts are unchanged.");
            await load(true);
          }}
        />
      ) : null}
      {addingReserve && !seasonZero ? (
        <AddReserveDialog
          accessToken={accessToken}
          detail={detail}
          onClose={() => setAddingReserve(false)}
          onSaved={async (savedNotice) => {
            setAddingReserve(false);
            setNotice(savedNotice);
            await load(true);
          }}
        />
      ) : null}
      {playerAction ? (
        <PlayerActionDialog
          accessToken={accessToken}
          detail={detail}
          player={playerAction}
          onClose={() => setPlayerAction(null)}
          onSaved={async (savedNotice) => {
            setPlayerAction(null);
            setNotice(savedNotice);
            await load(true);
          }}
        />
      ) : null}
      {assignReferee ? (
        <AssignRefereeDialog
          accessToken={accessToken}
          detail={detail}
          onClose={() => setAssignReferee(false)}
          onSaved={async (savedNotice) => {
            setAssignReferee(false);
            setNotice(savedNotice);
            await load(true);
          }}
        />
      ) : null}
      {clanActionId ? (
        <ClanActionDialog
          accessToken={accessToken}
          clan={clanActionId === fixture.homeClan.id ? fixture.homeClan : fixture.awayClan}
          detail={detail}
          onClose={() => setClanActionId(null)}
          onSaved={async (savedNotice) => {
            setClanActionId(null);
            setNotice(savedNotice);
            await load(true);
          }}
        />
      ) : null}
      {cancelGame ? (
        <CancelGameDialog
          accessToken={accessToken}
          detail={detail}
          onClose={() => setCancelGame(false)}
          onSaved={async () => {
            setCancelGame(false);
            setNotice("Game cancelled. Full refunds and deposit returns were recorded in the audit trail.");
            await load(true);
          }}
        />
      ) : null}
      {resolveCase && resolutionCase && canReviewCase ? (
        <ResolveMatchCaseDialog
          accessToken={accessToken}
          caseData={resolutionCase}
          detail={detail}
          cancellationOnly={unstartedSeasonZeroReview}
          onClose={() => setResolveCase(false)}
          onSaved={async (savedNotice) => {
            setResolveCase(false);
            setNotice(savedNotice);
            await load(true);
          }}
        />
      ) : null}
      {retryRefund && resolutionCase ? (
        <RetryResolutionRefundDialog
          accessToken={accessToken}
          caseData={resolutionCase}
          detail={detail}
          refund={retryRefund}
          onClose={() => setRetryRefund(null)}
          onSaved={async (savedNotice) => {
            setRetryRefund(null);
            setNotice(savedNotice);
            await load(true);
          }}
        />
      ) : null}
      {removeReserve && !seasonZero ? (
        <RemoveReserveDialog
          accessToken={accessToken}
          detail={detail}
          reserve={removeReserve}
          onClose={() => setRemoveReserve(null)}
          onSaved={async () => {
            setRemoveReserve(null);
            setNotice("Reserve assignment removed and added to the audit trail.");
            await load(true);
          }}
        />
      ) : null}
    </main>
  );
}

function GamePricingPanel({ pricing, onEdit }: {
  pricing: AdminGamePricing;
  onEdit: () => void;
}) {
  function recordedMoney(amount: number | null, currency: AdminGameCurrency) {
    return amount === null ? "Not recorded" : formatGameMoney(amount, currency);
  }
  return (
    <section className={styles.card} aria-labelledby="game-pricing-title">
      <header className={styles.pricingHeader}>
        <div className={styles.sectionHead}>
          <span>BOOKINGS & PAYMENTS</span>
          <h2 id="game-pricing-title">Game price</h2>
        </div>
        {pricing.canEdit ? (
          <button id="edit-game-price" className={styles.primaryButton} onClick={onEdit} type="button">Edit price</button>
        ) : null}
      </header>
      <div className={styles.currentPrice}>
        <span>Current price per player</span>
        <strong>{formatGameMoney(pricing.priceFils, pricing.currency)}</strong>
        <p>Price changes apply to new bookings only. Players who already paid keep their original price—no extra charge, refund, or adjustment.</p>
      </div>
      {!pricing.canEdit && pricing.lockedReason ? <p className={styles.actionHint}>{pricing.lockedReason}</p> : null}
      <h3 className={styles.paymentHistoryTitle}>Payment history <span>{pricing.bookings.length}</span></h3>
      <p className={styles.actionHint}>Each booking keeps its own recorded amounts, including cancelled bookings. Total paid is the original payment, before refunds. Refunded includes completed refunds only; unrecorded amounts are never estimated from today’s price.</p>
      {pricing.bookings.length ? (
        <div className={styles.paymentsScroll} tabIndex={0} role="region" aria-label="Booking payment history">
          <table className={styles.paymentsTable}>
            <thead><tr><th scope="col">Player / booking</th><th scope="col">Match fee</th><th scope="col">Deposit</th><th scope="col">Total paid</th><th scope="col">Refunded</th><th scope="col">Status</th></tr></thead>
            <tbody>{pricing.bookings.map((booking) => (
              <tr key={booking.bookingId}>
                <th scope="row">
                  <Link href={`/admin/people/player/${booking.profileId}`}>{booking.displayName}</Link>
                  <small>Booked {formatBookingDateTime(booking.bookedAt)}</small>
                  <small>#{booking.bookingId.slice(0, 8)}</small>
                </th>
                <td>{recordedMoney(booking.matchFeeFils, booking.currency)}</td>
                <td>{recordedMoney(booking.depositFils, booking.currency)}</td>
                <td><strong>{recordedMoney(booking.paidTotalFils, booking.currency)}</strong></td>
                <td>{recordedMoney(booking.refundedFils, booking.currency)}</td>
                <td><span>{humanize(booking.status)}</span><small>{humanize(booking.paymentStatus)}</small></td>
              </tr>
            ))}</tbody>
          </table>
        </div>
      ) : <div className={styles.emptyList}>No bookings have been recorded for this game.</div>}
    </section>
  );
}

function EditGamePriceDialog({ accessToken, gameId, pricing, onClose, onRefresh, onSaved }: {
  accessToken: string;
  gameId: string;
  pricing: AdminGamePricing;
  onClose: () => void;
  onRefresh: () => Promise<AdminGamePricing | null>;
  onSaved: () => Promise<void>;
}) {
  const [priceUsd, setPriceUsd] = useState((pricing.priceFils / 1000).toFixed(2));
  const [expectedPriceFils, setExpectedPriceFils] = useState(pricing.priceFils);
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [conflict, setConflict] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [refreshNotice, setRefreshNotice] = useState<string | null>(null);
  const dialogRef = useRef<HTMLElement>(null);
  const closeRef = useRef(onClose);
  closeRef.current = onClose;
  const busyRef = useRef(false);
  busyRef.current = saving || refreshing;
  const inputPrice = /^\d{1,3}(?:\.\d{1,2})?$/.test(priceUsd.trim())
    ? Math.round(Number(priceUsd.trim()) * 1000) : null;
  const validPrice = inputPrice !== null && (inputPrice === 0 || inputPrice >= 500 && inputPrice <= 100_000);
  const unchanged = inputPrice === expectedPriceFils;
  const reasonLength = reason.trim().length;

  useEffect(() => {
    const previousFocus = document.activeElement;
    const dialog = dialogRef.current;
    dialog?.querySelector<HTMLInputElement>("input")?.focus();
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape" && !busyRef.current) {
        event.preventDefault();
        closeRef.current();
      }
      if (event.key !== "Tab" || !dialog) return;
      const controls = [...dialog.querySelectorAll<HTMLElement>("button:not(:disabled), input:not(:disabled), textarea:not(:disabled)")];
      const first = controls[0];
      const last = controls.at(-1);
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
      if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
    }
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("keydown", onKeyDown);
      // Safari does not always focus buttons on mouse click, so retain the
      // explicit trigger as the return target rather than returning to <body>.
      const trigger = document.getElementById("edit-game-price");
      if (trigger instanceof HTMLElement) trigger.focus();
      else if (previousFocus instanceof HTMLElement && previousFocus.isConnected) previousFocus.focus();
    };
  }, []);

  async function refreshPrice() {
    setRefreshing(true);
    const refreshed = await onRefresh();
    setRefreshing(false);
    if (!refreshed) {
      setError("Could not refresh the current price. Your changes are still here. Try again.");
      return;
    }
    setExpectedPriceFils(refreshed.priceFils);
    setConflict(false);
    setError(null);
    setRefreshNotice(`Current price refreshed to ${formatGameMoney(refreshed.priceFils, refreshed.currency)}. Your draft is unchanged; review it before saving.`);
  }

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!validPrice || unchanged || reasonLength < 8 || reasonLength > 1000 || !pricing.canEdit || conflict || saving) return;
    setSaving(true); setError(null); setRefreshNotice(null);
    try {
      const response = await fetch(`/api/referee/admin/games/solo/${gameId}/price`, {
        method: "PATCH",
        headers: { ...auth(accessToken), "Content-Type": "application/json" },
        body: JSON.stringify({ priceUsd: priceUsd.trim(), expectedPriceFils, reason: reason.trim() }),
      });
      const payload = await response.json().catch(() => ({})) as { error?: string };
      if (!response.ok) {
        if (response.status === 409) setConflict(true);
        throw new Error(payload.error ?? "Could not update this game’s price.");
      }
      await onSaved();
    } catch (submitError) {
      setError(message(submitError, "Could not update this game’s price. Your changes are still here."));
      setSaving(false);
    }
  }

  return (
    <div className={styles.modalBackdrop} role="presentation">
      <section ref={dialogRef} aria-modal="true" aria-labelledby="edit-game-price-title" className={`${styles.modal} ${styles.smallModal}`} role="dialog">
        <header><div><span>THIS GAME ONLY</span><h2 id="edit-game-price-title">Edit game price</h2></div><button aria-label="Close price editor" disabled={saving || refreshing} onClick={onClose} type="button">×</button></header>
        <p className={styles.modalIntro}>Current price: <strong>{formatGameMoney(expectedPriceFils, pricing.currency)}</strong> per player.</p>
        <div className={styles.refundNotice}><strong>Existing payments stay exactly as they are</strong><p>No top-ups or automatic refunds. Cancellation refunds continue to use each booking’s original payment. Valid checkouts already in progress keep their quoted price until they expire. This changes only this game, not its recurring schedule or the default game price.</p></div>
        <form onSubmit={(event) => void submit(event)}>
          <label htmlFor="game-price-usd">New price per player (USD)</label>
          <input id="game-price-usd" className={styles.priceInput} type="text" inputMode="decimal" autoComplete="off" value={priceUsd} disabled={saving || refreshing} onChange={(event) => setPriceUsd(event.target.value)} aria-describedby="game-price-help" aria-invalid={!validPrice} />
          <p id="game-price-help" className={validPrice ? styles.actionHint : styles.priceError}>Enter $0 for free bookings, or $0.50–$100 with up to two decimal places. Card payments have a $0.50 minimum.</p>
          <label htmlFor="game-price-reason">Reason for the price change</label>
          <textarea id="game-price-reason" className={styles.priceInput} maxLength={1000} value={reason} disabled={saving || refreshing} onChange={(event) => setReason(event.target.value)} placeholder="For example, a discount for the remaining places." aria-describedby="game-price-reason-help" />
          <p id="game-price-reason-help" className={styles.actionHint}>At least 8 characters. Stored in the game’s admin history.</p>
          {!pricing.canEdit ? <p className={styles.modalError} role="alert">{pricing.lockedReason ?? "This game’s price can no longer be changed."}</p> : null}
          {error ? <p className={styles.modalError} role="alert">{error}</p> : null}
          {refreshNotice ? <p className={styles.refundNotice} role="status">{refreshNotice}</p> : null}
          {conflict ? <button className={styles.secondaryButton} disabled={saving || refreshing} onClick={() => void refreshPrice()} type="button">{refreshing ? "Refreshing…" : "Refresh current price"}</button> : null}
          <footer><button className={styles.cancelButton} disabled={saving || refreshing} onClick={onClose} type="button">Cancel</button><button className={styles.primaryButton} disabled={saving || refreshing || conflict || !pricing.canEdit || !validPrice || unchanged || reasonLength < 8 || reasonLength > 1000} type="submit">{saving ? "Saving…" : "Save new price"}</button></footer>
        </form>
      </section>
    </div>
  );
}

function formatBookingDateTime(value: string | null) {
  if (!value) return "Unknown time";
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? "Unknown time" : new Intl.DateTimeFormat("en-US", {
    dateStyle: "medium", timeStyle: "short", timeZone: "America/Phoenix",
  }).format(date) + " (Phoenix)";
}

function ResolutionCaseBanner({
  caseData,
  detail,
  onResolve,
  onRetryRefund,
}: {
  caseData: AdminGameResolutionCase;
  detail: AdminGameDetail;
  onResolve?: () => void;
  onRetryRefund: (refund: AdminGameResolutionRefund) => void;
}) {
  const open = ["NO_DATA", "UNDER_REVIEW"].includes(caseData.state);
  const highPriorityAt = new Date(caseData.highPriorityAt).getTime();
  const critical = open &&
    Number.isFinite(highPriorityAt) &&
    highPriorityAt <= Date.now();
  const openDisputes = caseData.disputes.filter((item) =>
    ["OPEN", "UNDER_REVIEW", "PENDING"].includes(item.status),
  );
  const failedRefunds = caseData.refunds.filter((item) =>
    ["FAILED", "REJECTED"].includes(item.status),
  );
  const pendingRefunds = caseData.refunds.filter((item) =>
    ["PENDING", "PROCESSING", "QUEUED"].includes(item.status),
  );
  const completedRefunds = caseData.refunds.filter((item) =>
    ["COMPLETED", "SUCCEEDED", "REFUNDED"].includes(item.status),
  );
  const latestRevision = caseData.revisions[0];
  const currentRevisionId = caseData.revisions.find(
    (revision) => revision.revision === caseData.currentRevision,
  )?.id;
  const retriableRefunds = failedRefunds.filter(
    (refund) =>
      refund.status === "FAILED" &&
      !refund.requiresManualReview &&
      refund.revisionId === currentRevisionId,
  );
  const manualRefunds = failedRefunds.filter((refund) => refund.requiresManualReview);

  return (
    <section
      className={`${styles.resolutionBanner} ${
        critical ? styles.resolutionCritical : open ? styles.resolutionOpen : styles.resolutionComplete
      }`}
      aria-label="Match data resolution"
    >
      <div className={styles.resolutionBannerMain}>
        <div>
          <span className={styles.resolutionEyebrow}>
            {critical ? "CRITICAL · ADMIN ACTION REQUIRED" : open ? "NEEDS ATTENTION" : "RESOLUTION HISTORY"}
          </span>
          <h2>
            {caseData.state === "NO_DATA"
              ? "No match data was received"
              : caseData.state === "UNDER_REVIEW"
                ? "This match resolution is under review"
                : "An admin resolution was recorded"}
          </h2>
          <p>
            {caseData.state === "NO_DATA"
              ? `The match passed its reporting window without an official result. Field has not assumed a no-show and no automatic attendance penalty was applied.`
              : caseData.state === "UNDER_REVIEW"
                ? "The recorded outcome and refund processing remain active while the dispute is reviewed. Any correction creates a new audited revision."
                : latestRevision
                  ? `${humanize(latestRevision.resolutionType)} was recorded. Previous decisions, corrections and refund attempts remain in the audit history.`
                  : "This case is closed and retained for audit."}
          </p>
        </div>
        {onResolve ? <button className={styles.resolutionButton} onClick={onResolve} type="button">
          {open
            ? caseData.currentRevision
              ? "Review or correct"
              : "Resolve match"
            : "Create correction"}
        </button> : null}
      </div>
      <dl className={styles.resolutionFacts}>
        <div><dt>Reason</dt><dd>{humanize(caseData.reasonCode)}</dd></div>
        <div><dt>Scheduled end</dt><dd>{formatDateTime(caseData.scheduledEndAt)}</dd></div>
        <div><dt>Detected</dt><dd>{formatDateTime(caseData.detectedAt)}</dd></div>
        <div><dt>Referee</dt><dd>{detail.assignedReferee?.displayName ?? "No referee assigned"}</dd></div>
        <div><dt>Revision</dt><dd>{caseData.currentRevision || "Unresolved"}</dd></div>
      </dl>
      {openDisputes.length || failedRefunds.length || pendingRefunds.length || completedRefunds.length ? (
        <div className={styles.resolutionFlags}>
          {openDisputes.length ? <span>{openDisputes.length} open dispute{openDisputes.length === 1 ? "" : "s"} · effects stay active</span> : null}
          {pendingRefunds.length ? <span>{pendingRefunds.length} refund{pendingRefunds.length === 1 ? "" : "s"} processing</span> : null}
          {completedRefunds.length ? <span>{completedRefunds.length} refund{completedRefunds.length === 1 ? "" : "s"} completed</span> : null}
          {retriableRefunds.length ? <span className={styles.failedFlag}>{retriableRefunds.length} refund{retriableRefunds.length === 1 ? "" : "s"} need retry</span> : null}
          {manualRefunds.length ? <span className={styles.failedFlag}>{manualRefunds.length} external refund{manualRefunds.length === 1 ? "" : "s"} require manual reconciliation · no retry</span> : null}
          {failedRefunds.length > retriableRefunds.length + manualRefunds.length ? <span>{failedRefunds.length - retriableRefunds.length - manualRefunds.length} historical refund failure(s) retained</span> : null}
        </div>
      ) : null}
      {failedRefunds.length ? (
        <div className={styles.failedRefundList}>
          {failedRefunds.map((refund) => (
            <article key={refund.id}>
              <div>
                <span>{refundSideLabel(refund, detail)} · {humanize(refund.status)}</span>
                <strong>{formatGameMoney(refund.amountFils, detail.currency)}</strong>
                <small>
                  {humanize(refund.destination)} · {refund.refundBps / 100}% refund
                  {refund.failureReason ? ` · ${refund.failureReason}` : " · No failure detail was recorded"}
                </small>
              </div>
              {refund.requiresManualReview ? (
                <em>Reconcile the Stripe Dashboard refund with the booking and payment ledger. Retry cannot release this hold.</em>
              ) : refund.status === "FAILED" && refund.revisionId === currentRevisionId ? (
                <button onClick={() => onRetryRefund(refund)} type="button">
                  Retry refund
                </button>
              ) : (
                <em>
                  {refund.revisionId !== currentRevisionId
                    ? "Superseded · audit only"
                    : "Manual review required"}
                </em>
              )}
            </article>
          ))}
        </div>
      ) : null}
    </section>
  );
}

function RetryResolutionRefundDialog({
  accessToken,
  caseData,
  detail,
  refund,
  onClose,
  onSaved,
}: {
  accessToken: string;
  caseData: AdminGameResolutionCase;
  detail: AdminGameDetail;
  refund: AdminGameResolutionRefund;
  onClose: () => void;
  onSaved: (notice: string) => Promise<void>;
}) {
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const trimmedReason = reason.trim();

  async function submit() {
    if (trimmedReason.length < 10 || trimmedReason.length > 2000) return;
    setSaving(true);
    setError(null);
    try {
      const result = await fetchJson<{
        result?: {
          status?: string;
          amount_fils?: number;
          already_settled?: boolean;
        };
      }>(
        `/api/referee/admin/games/${detail.fixture.matchKind.toLowerCase()}/${detail.fixture.id}/resolution/refunds/${refund.id}/retry`,
        {
          method: "POST",
          headers: { ...auth(accessToken), "Content-Type": "application/json" },
          body: JSON.stringify({ reason: trimmedReason }),
        },
      );
      const savedNotice = refundRetryNotice({
        status: result.result?.status,
        alreadySettled: result.result?.already_settled,
        destination: refund.destination,
      });
      await onSaved(savedNotice);
    } catch (retryError) {
      setError(message(retryError, "Could not retry this refund."));
      setSaving(false);
    }
  }

  return (
    <div
      className={styles.modalBackdrop}
      role="presentation"
      onMouseDown={(event) =>
        !saving && event.target === event.currentTarget && onClose()
      }
    >
      <section
        aria-labelledby="retry-refund-title"
        aria-modal="true"
        className={`${styles.modal} ${styles.smallModal}`}
        role="dialog"
      >
        <header>
          <div>
            <span>FAILED REFUND · REVISION {caseData.currentRevision}</span>
            <h2 id="retry-refund-title">Retry this refund?</h2>
          </div>
          <button aria-label="Close refund retry" disabled={saving} onClick={onClose}>×</button>
        </header>
        <p className={styles.modalIntro}>
          This retries the outstanding refund to the recorded destination.
          Completed refunds are retained, and the server prevents duplicate refunds.
        </p>
        <dl className={styles.refundRetryFacts}>
          <div><dt>Recipient</dt><dd>{refundSideLabel(refund, detail)}</dd></div>
          <div><dt>Amount due</dt><dd>{formatGameMoney(refund.amountFils, detail.currency)}</dd></div>
          <div><dt>Destination</dt><dd>{humanize(refund.destination)}</dd></div>
          <div><dt>Failed because</dt><dd>{refund.failureReason ?? "No failure detail was recorded."}</dd></div>
        </dl>
        <div className={styles.modalWarning}>
          <strong>This action is audited</strong>
          <p>
            The retry reason, admin, prior failure and processor or wallet
            result are permanently recorded against this match.
          </p>
        </div>
        <label>
          <span>Why are you retrying it?</span>
          <textarea
            autoFocus
            disabled={saving}
            maxLength={2000}
            placeholder="Example: The payment processor issue has been resolved and the refund can be retried."
            value={reason}
            onChange={(event) => setReason(event.target.value)}
          />
          <small>{trimmedReason.length} / 2000 · minimum 10 characters</small>
        </label>
        {error ? <p className={styles.modalError}>{error}</p> : null}
        <footer>
          <button className={styles.cancelButton} disabled={saving} onClick={onClose}>
            Keep failed
          </button>
          <button
            className={styles.primaryButton}
            disabled={saving || trimmedReason.length < 10 || trimmedReason.length > 2000}
            onClick={() => void submit()}
          >
            {saving ? "Retrying securely…" : "Confirm refund retry"}
          </button>
        </footer>
      </section>
    </div>
  );
}

function ResolveMatchCaseDialog({ accessToken, caseData, detail, cancellationOnly = false, onClose, onSaved }: {
  accessToken: string;
  caseData: AdminGameResolutionCase;
  detail: AdminGameDetail;
  cancellationOnly?: boolean;
  onClose: () => void;
  onSaved: (notice: string) => Promise<void>;
}) {
  const [step, setStep] = useState(1);
  const [resolutionType, setResolutionType] = useState<MatchResolutionType | "">("");
  const [homeScore, setHomeScore] = useState("");
  const [awayScore, setAwayScore] = useState("");
  const [effects, setEffects] = useState<ResolutionEffects>(emptyResolutionEffects());
  const [playerAttendance, setPlayerAttendance] =
    useState<Record<string, PlayerAttendanceState>>({});
  const [advanced, setAdvanced] = useState(false);
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);
  const [previewing, setPreviewing] = useState(false);
  const [preview, setPreview] = useState<AdminResolutionPreview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const fixture = detail.fixture;
  const homeLabel = fixture.matchKind === "SOLO" ? "White team" : fixture.homeClan.tag;
  const awayLabel = fixture.matchKind === "SOLO" ? "Black team" : fixture.awayClan.tag;
  const homeSideCode = fixture.matchKind === "SOLO" ? "WHITE" : "HOME";
  const awaySideCode = fixture.matchKind === "SOLO" ? "BLACK" : "AWAY";
  const minimumAtKickoff = nestedNumber(
    caseData.policySnapshot,
    "clan",
    "minimumAtKickoffWithoutForfeit",
  );
  const minimumOnTime = nestedNumber(
    caseData.policySnapshot,
    "clan",
    "minimumOnTimeWithoutClanStrike",
  );
  const attendanceCandidates = resolutionAttendanceCandidates(detail);
  const outcome = RESOLUTION_OUTCOMES.find((item) => item.type === resolutionType);
  const guaranteesNoSrChange = hasGuaranteedNoSrChange(resolutionType);

  function chooseOutcome(type: MatchResolutionType) {
    setResolutionType(type);
    setEffects(defaultResolutionEffects(type));
    setPlayerAttendance({});
    setPreview(null);
    setError(null);
  }

  function updateEffect(key: keyof ResolutionEffects, value: string) {
    setEffects((current) => ({ ...current, [key]: value }));
    setPreview(null);
  }

  async function next() {
    setError(null);
    if (step === 1) {
      if (!resolutionType) {
        setError("Choose what happened to this match.");
        return;
      }
      if (resolutionType === "RECORDED_RESULT") {
        const scoreError = validateWholeNumber(homeScore, 0, 99, `${homeLabel} score`) ??
          validateWholeNumber(awayScore, 0, 99, `${awayLabel} score`);
        if (scoreError) {
          setError(scoreError);
          return;
        }
      }
    }
    if (step === 2) {
      if (resolutionType === "RECORDED_RESULT") {
        const attendanceError = validateRecordedResultAttendance(
          detail,
          attendanceCandidates,
          playerAttendance,
          homeLabel,
          awayLabel,
        );
        if (attendanceError) {
          setError(attendanceError);
          return;
        }
      }
      const effectError = validateResolutionEffects(effects);
      if (effectError) {
        setError(effectError);
        return;
      }
      if (!resolutionType) return;
      setPreviewing(true);
      try {
        const payload = cancellationOnly ? {} : buildResolutionPayload(
          resolutionType,
          homeScore,
          awayScore,
          effects,
          playerAttendance,
        );
        const response = await fetchJson<{
          preview: AdminResolutionPreview;
        }>(
          `/api/referee/admin/games/${fixture.matchKind.toLowerCase()}/${fixture.id}/resolution/preview`,
          {
            method: "POST",
            headers: { ...auth(accessToken), "Content-Type": "application/json" },
            body: JSON.stringify({
              expectedRevision: caseData.currentRevision,
              resolutionType,
              reason: "Consequence preview before admin confirmation.",
              payload,
            }),
          },
        );
        setPreview(response.preview);
      } catch (previewError) {
        setError(message(previewError, "Could not calculate the exact consequences."));
        return;
      } finally {
        setPreviewing(false);
      }
    }
    setStep((current) => Math.min(3, current + 1));
  }

  async function submit() {
    if (!resolutionType) return;
    if (reason.trim().length < 10) {
      setError("Add at least 10 characters explaining the evidence and decision.");
      return;
    }
    setSaving(true);
    setError(null);
    try {
      const payload = cancellationOnly ? {} : buildResolutionPayload(
        resolutionType,
        homeScore,
        awayScore,
        effects,
        playerAttendance,
      );
      await fetchJson(
        `/api/referee/admin/games/${fixture.matchKind.toLowerCase()}/${fixture.id}/resolution`,
        {
          method: "POST",
          headers: { ...auth(accessToken), "Content-Type": "application/json" },
          body: JSON.stringify({
            expectedRevision: caseData.currentRevision,
            resolutionType,
            reason: reason.trim(),
            payload,
          }),
        },
      );
      await onSaved(
        caseData.currentRevision
          ? `Resolution corrected as ${humanize(resolutionType)}. Revision ${caseData.currentRevision + 1} preserves the earlier decision in the audit trail.`
          : `Match resolved as ${humanize(resolutionType)}. Refunds and consequences are now being processed.`,
      );
    } catch (submitError) {
      setError(message(submitError, "Could not resolve this match."));
      setSaving(false);
    }
  }

  return (
    <div className={styles.modalBackdrop} role="presentation">
      <section
        aria-modal="true"
        aria-labelledby="resolution-title"
        className={`${styles.modal} ${styles.resolutionModal}`}
        role="dialog"
      >
        <header>
          <div>
            <span>MATCH DATA REVIEW · STEP {step} OF 3</span>
            <h2 id="resolution-title">
              {caseData.currentRevision ? "Review or correct resolution" : "Resolve missing match data"}
            </h2>
          </div>
          <button aria-label="Close" disabled={saving} onClick={onClose}>×</button>
        </header>

        <ol className={styles.wizardSteps} aria-label="Resolution steps">
          <li className={step >= 1 ? styles.activeStep : ""}><b>1</b><span>Outcome</span></li>
          <li className={step >= 2 ? styles.activeStep : ""}><b>2</b><span>Consequences</span></li>
          <li className={step >= 3 ? styles.activeStep : ""}><b>3</b><span>Confirm</span></li>
        </ol>

        {caseData.currentRevision ? (
          <div className={styles.revisionNotice}>
            <strong>This creates revision {caseData.currentRevision + 1}</strong>
            <p>The previous resolution remains immutable. Corrections use new ledger and audit entries instead of deleting history.</p>
          </div>
        ) : null}

        {step === 1 ? (
          <>
            <p className={styles.modalIntro}>
              Choose only what the evidence supports. “No data” is not itself a no-show, so no attendance or reliability consequence is assumed.
            </p>
            <div className={styles.outcomeGrid}>
              {RESOLUTION_OUTCOMES.filter(item => !cancellationOnly || ["FIELD_OR_VENUE_CANCELLATION", "ADMINISTRATIVE_VOID"].includes(item.type)).map((item) => (
                <button
                  aria-pressed={resolutionType === item.type}
                  className={resolutionType === item.type ? styles.selectedOutcome : ""}
                  key={item.type}
                  onClick={() => chooseOutcome(item.type)}
                  type="button"
                >
                  <strong>{item.title}</strong>
                  <span>{item.description}</span>
                </button>
              ))}
            </div>
            {resolutionType === "RECORDED_RESULT" ? (
              <div className={styles.scoreInputs}>
                <label><span>{homeLabel} final score</span><input inputMode="numeric" min={0} max={99} type="number" value={homeScore} onChange={(event) => setHomeScore(event.target.value)} /></label>
                <b>–</b>
                <label><span>{awayLabel} final score</span><input inputMode="numeric" min={0} max={99} type="number" value={awayScore} onChange={(event) => setAwayScore(event.target.value)} /></label>
              </div>
            ) : null}
          </>
        ) : null}

        {step === 2 && resolutionType && outcome ? (
          <>
            <p className={styles.modalIntro}>{outcome.consequence}</p>
            <div className={styles.consequenceGrid}>
              <ConsequencePreview
                label={`${homeLabel} refund`}
                value={percentOrPolicy(effects.homeRefundPercent)}
              />
              <ConsequencePreview
                label={`${awayLabel} refund`}
                value={percentOrPolicy(effects.awayRefundPercent)}
              />
              {fixture.matchKind === "CLAN" ? (
                <>
                  <ConsequencePreview
                    label={`${homeLabel} SR`}
                    value={guaranteesNoSrChange ? "No change" : deltaOrPolicy(effects.homeSrDelta)}
                  />
                  <ConsequencePreview
                    label={`${awayLabel} SR`}
                    value={guaranteesNoSrChange ? "No change" : deltaOrPolicy(effects.awaySrDelta)}
                  />
                </>
              ) : (
                <ConsequencePreview
                  label="Player SR"
                  value={playerSrConsequenceLabel(resolutionType)}
                />
              )}
              <ConsequencePreview
                label={`${homeLabel} strikes`}
                value={numberOrPolicy(effects.homeStrikes)}
              />
              <ConsequencePreview
                label={`${awayLabel} strikes`}
                value={numberOrPolicy(effects.awayStrikes)}
              />
            </div>

            {resolutionType === "RECORDED_RESULT" ? (
              <PlayerAttendanceEditor
                awayLabel={awayLabel}
                candidates={attendanceCandidates}
                detail={detail}
                homeLabel={homeLabel}
                onChange={(profileId, state) => {
                  setPlayerAttendance((current) => {
                    const next = { ...current };
                    if (state) next[profileId] = state;
                    else delete next[profileId];
                    return next;
                  });
                  setPreview(null);
                }}
                values={playerAttendance}
              />
            ) : null}

            {!cancellationOnly ? <details
              className={styles.advancedResolution}
              open={advanced}
              onToggle={(event) => setAdvanced(event.currentTarget.open)}
            >
              <summary>Advanced overrides</summary>
              <p>Only override policy defaults when the evidence requires it. Every override is stored with this revision.</p>
              {fixture.matchKind === "CLAN" ? (
                <p>
                  {minimumAtKickoff === null || minimumOnTime === null
                    ? "This legacy match has no complete short-roster policy snapshot, so Field will not invent new reliability strikes."
                    : `Snapshotted policy: ${minimumAtKickoff} players at kickoff avoids a forfeit; ${minimumOnTime} on-time players avoids a clan strike.`}
                </p>
              ) : null}
              <div className={styles.formGrid}>
                <label><span>{homeLabel} refund %</span><input inputMode="decimal" min={0} max={100} type="number" value={effects.homeRefundPercent} onChange={(event) => updateEffect("homeRefundPercent", event.target.value)} placeholder="Policy default" /></label>
                <label><span>{awayLabel} refund %</span><input inputMode="decimal" min={0} max={100} type="number" value={effects.awayRefundPercent} onChange={(event) => updateEffect("awayRefundPercent", event.target.value)} placeholder="Policy default" /></label>
                {fixture.matchKind === "CLAN" ? (
                  <>
                    <label><span>{homeLabel} SR delta</span><input inputMode="numeric" type="number" value={effects.homeSrDelta} onChange={(event) => updateEffect("homeSrDelta", event.target.value)} placeholder="Policy default" /></label>
                    <label><span>{awayLabel} SR delta</span><input inputMode="numeric" type="number" value={effects.awaySrDelta} onChange={(event) => updateEffect("awaySrDelta", event.target.value)} placeholder="Policy default" /></label>
                  </>
                ) : null}
                <label><span>{homeLabel} strikes</span><input inputMode="numeric" min={0} max={20} type="number" value={effects.homeStrikes} onChange={(event) => updateEffect("homeStrikes", event.target.value)} placeholder="Policy default" /></label>
                <label><span>{awayLabel} strikes</span><input inputMode="numeric" min={0} max={20} type="number" value={effects.awayStrikes} onChange={(event) => updateEffect("awayStrikes", event.target.value)} placeholder="Policy default" /></label>
                <label>
                  <span>{homeLabel} attendance</span>
                  <select
                    value={effects.homeAttendanceState}
                    onChange={(event) => updateEffect("homeAttendanceState", event.target.value)}
                  >
                    <option value="">Use outcome / recorded attendance</option>
                    <option value="PRESENT">Present</option>
                    {fixture.matchKind === "CLAN" ? <option value="SHORT_ROSTER">Present with a short roster</option> : null}
                    <option value="NO_SHOW">No-show</option>
                    <option value="EXCUSED">Excused</option>
                    <option value="FORFEIT">Forfeit / at fault</option>
                  </select>
                </label>
                <label>
                  <span>{awayLabel} attendance</span>
                  <select
                    value={effects.awayAttendanceState}
                    onChange={(event) => updateEffect("awayAttendanceState", event.target.value)}
                  >
                    <option value="">Use outcome / recorded attendance</option>
                    <option value="PRESENT">Present</option>
                    {fixture.matchKind === "CLAN" ? <option value="SHORT_ROSTER">Present with a short roster</option> : null}
                    <option value="NO_SHOW">No-show</option>
                    <option value="EXCUSED">Excused</option>
                    <option value="FORFEIT">Forfeit / at fault</option>
                  </select>
                </label>
              </div>
              <p>
                Team choices are saved as {homeSideCode} and {awaySideCode}.
                Player attendance is selected by name above so the result and
                rating history cannot be attached to an unknown lineup.
              </p>
            </details> : <p className={styles.actionHint}>This game has no recorded kickoff. Cancellation returns all paid fees and held deposits to the original payers, with no SR change or new reliability penalty.</p>}
          </>
        ) : null}

        {step === 3 && resolutionType && outcome ? (
          <>
            <div className={styles.finalDecision}>
              <span>FINAL DECISION</span>
              <h3>{outcome.title}</h3>
              <p>{outcome.consequence}</p>
              {resolutionType === "RECORDED_RESULT" ? (
                <>
                  <strong>{homeLabel} {homeScore} – {awayScore} {awayLabel}</strong>
                  <p>
                    {recordedAttendanceSummary(
                      detail,
                      attendanceCandidates,
                      playerAttendance,
                      homeLabel,
                      awayLabel,
                    )}
                  </p>
                </>
              ) : null}
            </div>
            {preview ? (
              <>
                <div className={styles.finalEffects}>
                  <span>{homeLabel}: {previewConsequenceLine(preview, "home", fixture.matchKind === "SOLO")}</span>
                  <span>{awayLabel}: {previewConsequenceLine(preview, "away", fixture.matchKind === "SOLO")}</span>
                </div>
                <div className={styles.modalWarning}>
                  <strong>Exact server-calculated preview</strong>
                  <p>
                    {previewRefundLine(preview, "home", homeLabel, detail.currency)}{" · "}
                    {previewRefundLine(preview, "away", awayLabel, detail.currency)}
                  </p>
                </div>
              </>
            ) : null}
            <label>
              <span>Evidence and reason · required</span>
              <textarea
                autoFocus
                maxLength={2000}
                placeholder="State what was verified, the evidence used, and why this outcome is correct…"
                value={reason}
                onChange={(event) => setReason(event.target.value)}
              />
            </label>
            <div className={styles.modalWarning}>
              <strong>Resolution takes effect immediately</strong>
              <p>Refunds are queued independently. A later dispute marks the case under review but does not pause or reverse completed effects.</p>
            </div>
          </>
        ) : null}

        {error ? <p className={styles.modalError}>{error}</p> : null}
        <footer>
          {step > 1 ? <button className={styles.cancelButton} disabled={saving} onClick={() => { setError(null); setStep((current) => current - 1); }}>Back</button> : <button className={styles.cancelButton} disabled={saving} onClick={onClose}>Close</button>}
          {step < 3 ? (
            <button
              className={styles.primaryButton}
              disabled={previewing}
              onClick={() => void next()}
            >
              {previewing ? "Calculating…" : "Continue"}
            </button>
          ) : (
            <button className={styles.dangerButton} disabled={saving || reason.trim().length < 10} onClick={() => void submit()}>
              {saving ? "Applying resolution…" : caseData.currentRevision ? "Confirm corrected resolution" : "Confirm and resolve"}
            </button>
          )}
        </footer>
      </section>
    </div>
  );
}

function ConsequencePreview({ label, value }: { label: string; value: string }) {
  return <article><span>{label}</span><strong>{value}</strong></article>;
}

function PlayerAttendanceEditor({
  awayLabel,
  candidates,
  detail,
  homeLabel,
  onChange,
  values,
}: {
  awayLabel: string;
  candidates: AdminGameParticipant[];
  detail: AdminGameDetail;
  homeLabel: string;
  onChange: (profileId: string, state: PlayerAttendanceState | "") => void;
  values: Record<string, PlayerAttendanceState>;
}) {
  const sides = detail.fixture.matchKind === "SOLO"
    ? [
        { code: "WHITE", label: homeLabel },
        { code: "BLACK", label: awayLabel },
      ]
    : [
        { code: "HOME", label: homeLabel },
        { code: "AWAY", label: awayLabel },
      ];

  return (
    <section className={styles.attendanceEditor}>
      <header>
        <div>
          <span>OFFICIAL LINEUP · REQUIRED</span>
          <h3>Confirm every player who took part</h3>
          <p>
            This decides who receives a rated appearance. If referee check-ins
            are missing, mark at least one player from each side as played.
          </p>
        </div>
      </header>
      <div className={styles.attendanceTeams}>
        {sides.map((side) => {
          const players = candidates.filter((player) => player.side === side.code);
          const confirmed = players.filter((player) =>
            hasPlayedEvidence(player, values[player.profileId] ?? "")
          ).length;
          return (
            <section key={side.code}>
              <header>
                <strong>{side.label}</strong>
                <span className={confirmed ? styles.attendanceReady : styles.attendanceMissing}>
                  {confirmed
                    ? `${confirmed} ${confirmed === 1 ? "player" : "players"} confirmed`
                    : "Player confirmation needed"}
                </span>
              </header>
              {players.length ? (
                <div className={styles.attendancePlayers}>
                  {players.map((player) => {
                    const recorded = player.checkedInAt !== null;
                    return (
                      <label key={player.profileId}>
                        <Avatar name={player.displayName} url={player.avatarUrl} />
                        <span>
                          <strong>{player.displayName}</strong>
                          <small>
                            {player.role ? humanize(player.role) : "Player"}
                            {recorded ? " · Referee check-in on file" : ""}
                            {!player.planned && !player.played
                              ? " · Previously rostered"
                              : ""}
                          </small>
                        </span>
                        <select
                          aria-label={`${player.displayName} attendance`}
                          value={values[player.profileId] ?? ""}
                          onChange={(event) =>
                            onChange(
                              player.profileId,
                              event.target.value as PlayerAttendanceState | "",
                            )}
                        >
                          <option value="">
                            {recorded ? "Use referee check-in" : "Not confirmed"}
                          </option>
                          <option value="PRESENT">Played</option>
                          <option value="LATE">Played · arrived late</option>
                          <option value="EXCUSED">Did not play · excused</option>
                          <option value="NO_SHOW">Did not arrive</option>
                        </select>
                      </label>
                    );
                  })}
                </div>
              ) : (
                <p className={styles.attendanceEmpty}>
                  No rostered players are available for this side. The result
                  cannot be rated until its lineup is repaired.
                </p>
              )}
            </section>
          );
        })}
      </div>
      <p className={styles.attendanceHelp}>
        “Played” and “arrived late” count toward the rated lineup. A blank
        choice only counts when an official referee check-in already exists.
      </p>
    </section>
  );
}

function AssignRefereeDialog({ accessToken, detail, onClose, onSaved }: {
  accessToken: string;
  detail: AdminGameDetail;
  onClose: () => void;
  onSaved: (notice: string) => Promise<void>;
}) {
  const [referees, setReferees] = useState<RefereeAssignmentsResponse["referees"]>([]);
  const [selectedId, setSelectedId] = useState(detail.assignedReferee?.profileId ?? "");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    void fetchJson<RefereeAssignmentsResponse>("/api/referee/assignments", {
      headers: auth(accessToken),
      cache: "no-store",
    }).then((payload) => setReferees(payload.referees))
      .catch((loadError) => setError(message(loadError, "Could not load active referees.")))
      .finally(() => setLoading(false));
  }, [accessToken]);

  async function save() {
    setSaving(true); setError(null);
    try {
      await fetchJson("/api/referee/assignments", {
        method: "POST",
        headers: { ...auth(accessToken), "Content-Type": "application/json" },
        body: JSON.stringify({
          fixtureId: detail.fixture.id,
          matchKind: detail.fixture.matchKind,
          refereeId: selectedId || null,
        }),
      });
      const selected = referees.find((referee) => referee.profileId === selectedId);
      await onSaved(selected
        ? `${selected.displayName} is now assigned to this game.`
        : "The referee assignment was removed.");
    } catch (saveError) {
      setError(message(saveError, "Could not update the referee assignment."));
      setSaving(false);
    }
  }

  return (
    <div className={styles.modalBackdrop} role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <section aria-modal="true" className={`${styles.modal} ${styles.smallModal}`} role="dialog">
        <header><div><span>MATCH OFFICIAL</span><h2>Assign referee</h2></div><button onClick={onClose}>×</button></header>
        <p className={styles.modalIntro}>Choose the official for this game without leaving its operations page. Only active referee and admin accounts appear here.</p>
        {loading ? <LoadingSkeleton label="Loading available referees" layout="form" /> : <label>
          <span>Assigned official</span>
          <select autoFocus disabled={loading} onChange={(event) => setSelectedId(event.target.value)} value={selectedId}>
            <option value="">No referee assigned</option>
            {referees.map((referee) => (
              <option key={referee.profileId} value={referee.profileId}>
                {referee.displayName} · {referee.phone} · {humanize(referee.role)}
              </option>
            ))}
          </select>
        </label>}
        {error ? <p className={styles.modalError}>{error}</p> : null}
        <footer><button className={styles.cancelButton} disabled={saving} onClick={onClose}>Close</button><button className={styles.primaryButton} disabled={loading || saving || selectedId === (detail.assignedReferee?.profileId ?? "")} onClick={() => void save()}>{saving ? "Saving…" : "Save assignment"}</button></footer>
      </section>
    </div>
  );
}

function ClanActionDialog({ accessToken, clan, detail, onClose, onSaved }: {
  accessToken: string;
  clan: RefereeFixture["homeClan"];
  detail: AdminGameDetail;
  onClose: () => void;
  onSaved: (notice: string) => Promise<void>;
}) {
  const [category, setCategory] = useState("NO_SHOW_OR_MATCH_MANIPULATION");
  const [priority, setPriority] = useState("HIGH");
  const [strikeCount, setStrikeCount] = useState(0);
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit() {
    setSaving(true); setError(null);
    try {
      await fetchJson(`/api/referee/admin/games/clan/${detail.fixture.id}/clans/action`, {
        method: "POST",
        headers: { ...auth(accessToken), "Content-Type": "application/json" },
        body: JSON.stringify({ clanId: clan.id, category, priority, details: reason.trim(), strikeCount }),
      });
      await onSaved(strikeCount
        ? `${clan.name} was reported and received ${strikeCount} clan reliability strike${strikeCount === 1 ? "" : "s"}.`
        : `${clan.name} was reported for admin review.`);
    } catch (submitError) {
      setError(message(submitError, "Could not record this clan action."));
      setSaving(false);
    }
  }

  return (
    <div className={styles.modalBackdrop} role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <section aria-modal="true" className={styles.modal} role="dialog">
        <header><div><span>CLAN ACTION</span><h2>{clan.emblem} {clan.name}</h2></div><button onClick={onClose}>×</button></header>
        <p className={styles.modalIntro}>Create a permanent report against the whole clan. Clan strikes affect its reliability standing and can trigger the configured deposit or scheduling restrictions.</p>
        <div className={styles.formGrid}>
          <label><span>Report reason</span><select value={category} onChange={(event) => setCategory(event.target.value)}>{REPORT_CATEGORIES.map((item) => <option key={item} value={item}>{humanize(item)}</option>)}</select></label>
          <label><span>Priority</span><select value={priority} onChange={(event) => setPriority(event.target.value)}>{["NORMAL", "HIGH", "URGENT"].map((item) => <option key={item}>{humanize(item)}</option>)}</select></label>
        </div>
        <label><span>Clan reliability strikes</span><select value={strikeCount} onChange={(event) => setStrikeCount(Number(event.target.value))}><option value={0}>Report only · no strikes</option><option value={1}>1 clan strike</option><option value={2}>2 clan strikes</option><option value={3}>3 clan strikes</option></select></label>
        {strikeCount > 0 ? <div className={styles.modalWarning}><strong>This applies to the whole clan</strong><p>Clan leaders are notified, and configured reliability restrictions may activate immediately.</p></div> : null}
        <label><span>Evidence and reason</span><textarea autoFocus maxLength={2000} placeholder="Explain what happened and why the entire clan is accountable…" value={reason} onChange={(event) => setReason(event.target.value)} /></label>
        {error ? <p className={styles.modalError}>{error}</p> : null}
        <footer><button className={styles.cancelButton} disabled={saving} onClick={onClose}>Close</button><button className={strikeCount ? styles.dangerButton : styles.primaryButton} disabled={saving || reason.trim().length < 10} onClick={() => void submit()}>{saving ? "Recording…" : strikeCount ? `Report + issue ${strikeCount} strike${strikeCount === 1 ? "" : "s"}` : "Submit report"}</button></footer>
      </section>
    </div>
  );
}

function AddReserveDialog({ accessToken, detail, onClose, onSaved }: {
  accessToken: string;
  detail: AdminGameDetail;
  onClose: () => void;
  onSaved: (notice: string) => Promise<void>;
}) {
  const [query, setQuery] = useState("");
  const [candidates, setCandidates] = useState<AdminReserveCandidate[]>([]);
  const [selected, setSelected] = useState<AdminReserveCandidate | null>(null);
  const [note, setNote] = useState("Matchday standby cover");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const fixture = detail.fixture;

  useEffect(() => {
    const timer = window.setTimeout(() => {
      setLoading(true);
      setError(null);
      const params = new URLSearchParams({ query });
      void fetchJson<{ candidates: AdminReserveCandidate[] }>(
        `/api/referee/admin/games/${fixture.matchKind.toLowerCase()}/${fixture.id}/reserves?${params}`,
        { headers: auth(accessToken), cache: "no-store" },
      ).then((payload) => setCandidates(payload.candidates))
        .catch((loadError) => setError(message(loadError, "Could not search players.")))
        .finally(() => setLoading(false));
    }, 250);
    return () => window.clearTimeout(timer);
  }, [accessToken, fixture.id, fixture.matchKind, query]);

  async function submit() {
    if (!selected || note.trim().length < 3) return;
    setSaving(true); setError(null);
    try {
      await fetchJson(
        `/api/referee/admin/games/${fixture.matchKind.toLowerCase()}/${fixture.id}/reserves`,
        {
          method: "POST",
          headers: { ...auth(accessToken), "Content-Type": "application/json" },
          body: JSON.stringify({ profileId: selected.profileId, note }),
        },
      );
      await onSaved(`${selected.displayName} assigned as the game reserve.`);
    } catch (saveError) {
      setError(message(saveError, "Could not assign this reserve."));
      setSaving(false);
    }
  }

  return (
    <div className={styles.modalBackdrop} role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <section aria-modal="true" className={styles.modal} role="dialog">
        <header><div><span>ADD RESERVE</span><h2>Game-wide standby</h2></div><button onClick={onClose}>×</button></header>
        <p className={styles.modalIntro}>Search every player on Field. Confirmed participants are excluded because the reserve must remain outside the official roster.</p>
        <label className={styles.search}><span>Search players</span><input autoFocus placeholder="Name or username" value={query} onChange={(event) => setQuery(event.target.value)} /></label>
        <div className={styles.candidates}>
          {loading ? <LoadingSkeleton label="Searching players" layout="rows" /> : candidates.length === 0 ? <p>No matching players found.</p> : candidates.map((candidate) => (
            <button
              className={selected?.profileId === candidate.profileId ? styles.selectedCandidate : ""}
              disabled={!candidate.eligible}
              key={candidate.profileId}
              onClick={() => setSelected(candidate)}
              type="button"
            >
              <Avatar name={candidate.displayName} url={candidate.avatarUrl} />
              <span><strong>{candidate.displayName}</strong><small>{candidate.username ? `@${candidate.username.replace(/^@/, "")} · ` : ""}Outfield {candidate.outfieldRating} SR · Keeper {candidate.keeperRating} SR</small></span>
              <em>{candidate.unavailableReason ?? (selected?.profileId === candidate.profileId ? "Selected" : "Choose")}</em>
            </button>
          ))}
        </div>
        <label><span>Assignment note</span><textarea maxLength={500} value={note} onChange={(event) => setNote(event.target.value)} /></label>
        {error ? <p className={styles.modalError}>{error}</p> : null}
        <footer><button className={styles.cancelButton} onClick={onClose}>Cancel</button><button className={styles.primaryButton} disabled={!selected || note.trim().length < 3 || saving} onClick={() => void submit()}>{saving ? "Assigning…" : "Assign reserve"}</button></footer>
      </section>
    </div>
  );
}

function RemoveReserveDialog({ accessToken, detail, reserve, onClose, onSaved }: {
  accessToken: string;
  detail: AdminGameDetail;
  reserve: AdminGameReserve;
  onClose: () => void;
  onSaved: () => Promise<void>;
}) {
  const [reason, setReason] = useState("Reserve is no longer available");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function remove() {
    setSaving(true); setError(null);
    try {
      await fetchJson(`/api/referee/admin/games/${detail.fixture.matchKind.toLowerCase()}/${detail.fixture.id}/reserves`, {
        method: "DELETE",
        headers: { ...auth(accessToken), "Content-Type": "application/json" },
        body: JSON.stringify({ assignmentId: reserve.id, reason }),
      });
      await onSaved();
    } catch (removeError) {
      setError(message(removeError, "Could not remove this reserve."));
      setSaving(false);
    }
  }
  return (
    <div className={styles.modalBackdrop} role="presentation">
      <section aria-modal="true" className={`${styles.modal} ${styles.smallModal}`} role="dialog">
        <header><div><span>REMOVE RESERVE</span><h2>{reserve.displayName}</h2></div><button onClick={onClose}>×</button></header>
        <p className={styles.modalIntro}>This keeps the original assignment in the audit trail and opens the side’s reserve slot again.</p>
        <label><span>Reason</span><textarea maxLength={500} value={reason} onChange={(event) => setReason(event.target.value)} /></label>
        {error ? <p className={styles.modalError}>{error}</p> : null}
        <footer><button className={styles.cancelButton} onClick={onClose}>Keep reserve</button><button className={styles.dangerButton} disabled={reason.trim().length < 3 || saving} onClick={() => void remove()}>{saving ? "Removing…" : "Remove reserve"}</button></footer>
      </section>
    </div>
  );
}

function PlayerActionDialog({ accessToken, detail, player, onClose, onSaved }: {
  accessToken: string;
  detail: AdminGameDetail;
  player: AdminGameParticipant;
  onClose: () => void;
  onSaved: (notice: string) => Promise<void>;
}) {
  const [category, setCategory] = useState("DANGEROUS_PLAY");
  const [priority, setPriority] = useState("HIGH");
  const [strikeCount, setStrikeCount] = useState(0);
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function submit() {
    setSaving(true); setError(null);
    try {
      await fetchJson(
        `/api/referee/admin/games/${detail.fixture.matchKind.toLowerCase()}/${detail.fixture.id}/players/action`,
        {
          method: "POST",
          headers: { ...auth(accessToken), "Content-Type": "application/json" },
          body: JSON.stringify({
            profileId: player.profileId,
            category,
            priority,
            details: reason.trim(),
            strikeCount,
          }),
        },
      );
      await onSaved(strikeCount > 0
        ? `${player.displayName} was reported and received ${strikeCount} reliability strike${strikeCount === 1 ? "" : "s"}.`
        : `${player.displayName} was reported for admin review.`);
    } catch (submitError) {
      setError(message(submitError, "Could not record this player action."));
      setSaving(false);
    }
  }
  return (
    <div className={styles.modalBackdrop} role="presentation">
      <section aria-modal="true" className={styles.modal} role="dialog">
        <header><div><span>PLAYER ACTION</span><h2>{player.displayName}</h2></div><button onClick={onClose}>×</button></header>
        <p className={styles.modalIntro}>Create a permanent match-linked report. Reliability strikes affect the player’s active strike total and may immediately trigger configured restrictions.</p>
        <div className={styles.formGrid}>
          <label><span>Report reason</span><select value={category} onChange={(event) => setCategory(event.target.value)}>{REPORT_CATEGORIES.map((item) => <option key={item} value={item}>{humanize(item)}</option>)}</select></label>
          <label><span>Priority</span><select value={priority} onChange={(event) => setPriority(event.target.value)}>{["NORMAL", "HIGH", "URGENT"].map((item) => <option key={item}>{humanize(item)}</option>)}</select></label>
        </div>
        <label><span>Reliability strikes</span><select value={strikeCount} onChange={(event) => setStrikeCount(Number(event.target.value))}><option value={0}>Report only · no strikes</option><option value={1}>1 strike</option><option value={2}>2 strikes</option><option value={3}>3 strikes</option></select></label>
        {strikeCount > 0 ? <div className={styles.modalWarning}><strong>This has an immediate player consequence</strong><p>The player is notified. If this crosses a policy threshold, booking restrictions or suspensions are applied automatically.</p></div> : null}
        <label><span>What happened?</span><textarea autoFocus maxLength={2000} placeholder="Record the evidence and reason for this decision…" value={reason} onChange={(event) => setReason(event.target.value)} /></label>
        {error ? <p className={styles.modalError}>{error}</p> : null}
        <footer><button className={styles.cancelButton} disabled={saving} onClick={onClose}>Close</button><button className={strikeCount > 0 ? styles.dangerButton : styles.primaryButton} disabled={saving || reason.trim().length < 10} onClick={() => void submit()}>{saving ? "Recording…" : strikeCount > 0 ? `Report + issue ${strikeCount} strike${strikeCount === 1 ? "" : "s"}` : "Submit report"}</button></footer>
      </section>
    </div>
  );
}

function CancelGameDialog({ accessToken, detail, onClose, onSaved }: {
  accessToken: string;
  detail: AdminGameDetail;
  onClose: () => void;
  onSaved: () => Promise<void>;
}) {
  const [reasonCode, setReasonCode] = useState("ADMIN_DECISION");
  const [reason, setReason] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function submit() {
    setSaving(true); setError(null);
    const fixture = detail.fixture;
    const path = fixture.matchKind === "SOLO"
      ? `/api/referee/open-queue-games/${fixture.id}/action`
      : `/api/referee/fixtures/${fixture.id}/action`;
    try {
      await fetchJson(path, {
        method: "POST",
        headers: { ...auth(accessToken), "Content-Type": "application/json" },
        body: JSON.stringify({ action: "cancel", reasonCode, reason: reason.trim() }),
      });
      await onSaved();
    } catch (submitError) {
      setError(message(submitError, "Could not cancel this game."));
      setSaving(false);
    }
  }
  return (
    <div className={styles.modalBackdrop} role="presentation">
      <section aria-modal="true" className={`${styles.modal} ${styles.smallModal}`} role="dialog">
        <header><div><span>ADMIN CANCELLATION</span><h2>Cancel this game?</h2></div><button onClick={onClose}>×</button></header>
        <div className={styles.refundNotice}><strong>100% refund</strong><p>All paid match fees and held reliability deposits are returned to their original payers. Card and digital wallet payments are refunded to the original payment method; historical wallet payments keep their recorded destination.</p></div>
        <label><span>Cancellation category</span><select value={reasonCode} onChange={(event) => setReasonCode(event.target.value)}>{CANCELLATION_REASONS.map((item) => <option key={item} value={item}>{humanize(item)}</option>)}</select></label>
        <label><span>Reason</span><textarea maxLength={1000} placeholder="Why is Field cancelling this game?" value={reason} onChange={(event) => setReason(event.target.value)} /></label>
        <label><span>Type CANCEL to confirm</span><input value={confirmation} onChange={(event) => setConfirmation(event.target.value)} /></label>
        {error ? <p className={styles.modalError}>{error}</p> : null}
        <footer><button className={styles.cancelButton} disabled={saving} onClick={onClose}>Keep game</button><button className={styles.dangerButton} disabled={saving || reason.trim().length < 8 || confirmation.trim().toUpperCase() !== "CANCEL"} onClick={() => void submit()}>{saving ? "Cancelling…" : "Cancel and refund everyone"}</button></footer>
      </section>
    </div>
  );
}

function ReserveSlot({ reserve, locked, onAdd, onRemove }: {
  reserve?: AdminGameReserve;
  locked: boolean;
  onAdd: () => void;
  onRemove: () => void;
}) {
  return (
    <article className={`${styles.reserveSlot} ${reserve ? styles.filledReserve : ""}`}>
      <div className={styles.reserveLabel}><span>Game reserve</span><b>{reserve ? "ASSIGNED" : "OPEN SLOT"}</b></div>
      {reserve ? (
        <>
          <div className={styles.reservePlayer}><Avatar name={reserve.displayName} url={reserve.avatarUrl} /><span><strong>{reserve.displayName}</strong><small>{reserve.username ? `@${reserve.username.replace(/^@/, "")}` : "Player"}</small></span></div>
          <p>{reserve.note}</p>
          <small>Added by {reserve.addedByName} · {formatDateTime(reserve.addedAt)}</small>
          <button disabled={locked} onClick={onRemove} type="button">Remove reserve</button>
        </>
      ) : (
        <>
          <div className={styles.emptyReserve}>+</div>
          <strong>No reserve assigned</strong>
          <p>Add one standby player for last-minute cover.</p>
          <button disabled={locked} onClick={onAdd} type="button">Add reserve player</button>
        </>
      )}
      {locked ? <em>Reserve assignments are locked after kickoff.</em> : null}
    </article>
  );
}

function ParticipantGroups({ detail, onPlayerAction }: {
  detail: AdminGameDetail;
  onPlayerAction: (player: AdminGameParticipant) => void;
}) {
  const fixture = detail.fixture;
  const participants = detail.participants;
  const active = participants.matchKind === "SOLO"
    ? participants.registeredPlayers
    : participants.plannedPlayers.length
      ? participants.plannedPlayers
      : participants.actualPlayers;
  const definitions = fixture.matchKind === "SOLO"
    ? [{ side: "WHITE", name: "White team" }, { side: "BLACK", name: "Black team" }, { side: null, name: "Unassigned" }]
    : [{ side: "HOME", name: fixture.homeClan.name }, { side: "AWAY", name: fixture.awayClan.name }, { side: null, name: "Unassigned" }];
  return (
    <div className={styles.rosters}>
      {definitions.map((definition) => {
        const players = active.filter((player) => player.side === definition.side);
        if (!players.length) return null;
        return <section key={definition.name}><header><strong>{definition.name}</strong><span>{players.length}</span></header>{players.map((player) => <PlayerRow key={player.profileId} player={player} onAction={() => onPlayerAction(player)} />)}</section>;
      })}
      {!active.length ? <div className={styles.emptyList}>No confirmed players yet.</div> : null}
    </div>
  );
}

function PlayerRow({ player, onAction }: { player: AdminGameParticipant; onAction: () => void }) {
  return <div className={styles.playerRow}><Avatar name={player.displayName} url={player.avatarUrl} /><span><strong>{player.displayName}</strong><small>{player.username ? `@${player.username.replace(/^@/, "")} · ` : ""}{player.role ? humanize(player.role) : "Player"}</small></span><div>{player.checkedInAt ? <b>Checked in</b> : null}{player.ratingAtTeamAssignment !== null ? <em>{player.ratingAtTeamAssignment} SR</em> : null}<button className={styles.playerAction} onClick={onAction} type="button">Report / strikes</button></div></div>;
}

function MatchTimeline({ fixture }: { fixture: RefereeFixture }) {
  const events = [...fixture.events].sort((left, right) => left.minute - right.minute || left.second - right.second);
  if (!events.length) return <div className={styles.emptyList}>The official timeline will appear when match operations begin.</div>;
  return <div className={styles.timeline}>{events.map((event) => <EventRow event={event} key={event.id} />)}</div>;
}

function EventRow({ event }: { event: FixtureEvent }) {
  return <div><time>{event.minute}:{String(event.second).padStart(2, "0")}</time><i>{eventIcon(event)}</i><span><strong>{humanize(event.eventType)}</strong><small>{event.note || "Official match event"}</small></span></div>;
}

function SafetyList({ detail }: { detail: AdminGameDetail }) {
  const items = [
    ...detail.stoppages.map((item) => ({ id: item.id, title: humanize(item.reasonCode), meta: `${humanize(item.mode)} · ${humanize(item.state)}`, text: item.note })),
    ...detail.reports.map((item) => ({ id: item.id, title: humanize(item.category), meta: `${humanize(item.priority)} · ${humanize(item.status)}`, text: item.details })),
  ];
  if (!items.length) return <div className={styles.clearState}><span>✓</span><strong>No match issues recorded</strong></div>;
  return <div className={styles.compactList}>{items.map((item) => <article key={item.id}><strong>{item.title}</strong><small>{item.meta}</small>{item.text ? <p>{item.text}</p> : null}</article>)}</div>;
}

function AuditList({ detail }: { detail: AdminGameDetail }) {
  if (!detail.audit.length) return <div className={styles.emptyList}>No admin changes recorded.</div>;
  return <div className={styles.auditList}>{detail.audit.map((item) => <article key={item.id}><i /><span><strong>{humanize(item.action)}</strong><small>{item.actorName} · {formatDateTime(item.createdAt)}</small>{item.reason ? <p>{item.reason}</p> : null}</span></article>)}</div>;
}

function Team({ clan, detail, side, align }: {
  clan: RefereeFixture["homeClan"];
  detail: AdminGameDetail;
  side: "home" | "away";
  align?: "right";
}) {
  const summary = detail.ratingSummary;
  const meta = summary.kind === "CLAN"
    ? `${side === "home" ? summary.home.skillRating : summary.away.skillRating} CLAN SR · BAHRAIN #${side === "home" ? summary.home.bahrainRank ?? "—" : summary.away.bahrainRank ?? "—"}`
    : `${side === "home" ? summary.whiteAverageSr ?? "—" : summary.blackAverageSr ?? "—"} AVG PLAYER SR`;
  return <div className={`${styles.team} ${align ? styles.alignRight : ""}`}><span>{clan.emblem}</span><div><strong>{clan.name}</strong><small>{meta}</small></div></div>;
}

function Fact({ label, value, warning }: { label: string; value: string; warning?: boolean }) {
  return <div><span>{label}</span><strong className={warning ? styles.warningText : ""}>{value}</strong></div>;
}

function Metric({ label, value, detail, tone }: { label: string; value: string; detail: string; tone?: "good" | "warning" }) {
  return <article className={tone ? styles[tone] : ""}><span>{label}</span><strong>{value}</strong><small>{detail}</small></article>;
}

function SectionHead({ eyebrow, title, detail }: { eyebrow: string; title: string; detail?: string }) {
  return <header className={styles.sectionHead}><span>{eyebrow}</span><h2>{title}</h2>{detail ? <p>{detail}</p> : null}</header>;
}

function Status({ status }: { status: string }) { return <b className={`${styles.status} ${styles[status.toLowerCase()]}`}>{humanize(status)}</b>; }

function Avatar({ name, url }: { name: string; url: string | null }) {
  return url ? <img className={styles.avatar} alt="" src={url} /> : <span className={styles.avatar}>{initials(name)}</span>;
}

function GameDetailSkeleton() {
  return <main className={styles.skeleton} role="status" aria-label="Loading game overview"><header aria-hidden="true" /><section aria-hidden="true" /><div aria-hidden="true"><i /><i /><i /><i /></div></main>;
}

function canManageReserves(status: string) { return ["OPEN", "FULL", "SCHEDULED"].includes(status); }
function canAssignReferee(status: string) { return ["OPEN", "FULL", "SCHEDULED"].includes(status); }
function canCancelGame(status: string) { return !["FINAL", "CANCELLED"].includes(status); }

function confirmedCount(detail: AdminGameDetail) {
  return String(detail.participants.matchKind === "SOLO" ? detail.participants.counts.registered : detail.participants.counts.planned);
}

function capacityLabel(detail: AdminGameDetail) {
  if (detail.participants.matchKind !== "SOLO") return "Confirmed clan roster";
  const rules = soloGameReadiness(detail.fixture, detail.participants.counts.registered);
  return `${rules.minimumPlayers} minimum · ${detail.participants.capacity} maximum`;
}

function score(fixture: RefereeFixture) {
  return fixture.homeScore === null || fixture.awayScore === null ? "—  —" : `${fixture.homeScore} – ${fixture.awayScore}`;
}

function eventIcon(event: FixtureEvent) {
  if (event.eventType === "GOAL") return "⚽";
  if (event.eventType.includes("BLUE_CARD")) return "▣";
  if (event.eventType.includes("STOP") || event.eventType.includes("FORFEIT")) return "!";
  return "•";
}

function auth(token: string) { return { authorization: `Bearer ${token}` }; }

async function fetchJson<T = unknown>(input: RequestInfo | URL, init?: RequestInit): Promise<T> {
  const response = await fetch(input, init);
  const payload = await response.json().catch(() => ({})) as T & { error?: string };
  if (!response.ok) throw new Error(payload.error ?? `Request failed (${response.status}).`);
  return payload;
}

function humanize(value: string) { return value.toLowerCase().replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase()); }
function initials(value: string) { return value.split(/\s+/).slice(0, 2).map((part) => part[0]?.toUpperCase()).join("") || "P"; }
function formatDate(value: string) { const date = new Date(`${value}T12:00:00Z`); return Number.isNaN(date.getTime()) ? value : new Intl.DateTimeFormat("en-BH", { weekday: "short", day: "numeric", month: "short", year: "numeric", timeZone: "Asia/Bahrain" }).format(date); }
function formatDateTime(value: string | null) { if (!value) return "Unknown time"; const date = new Date(value); return Number.isNaN(date.getTime()) ? value : new Intl.DateTimeFormat("en-BH", { day: "numeric", month: "short", hour: "numeric", minute: "2-digit", timeZone: "Asia/Bahrain" }).format(date); }
function message(error: unknown, fallback: string) { return error instanceof Error && error.message ? error.message : fallback; }
function refundSideLabel(
  refund: AdminGameResolutionRefund,
  detail: AdminGameDetail,
) {
  const side = refund.side?.toUpperCase() ?? "";
  if (detail.fixture.matchKind === "CLAN") {
    const clan = side === "HOME"
      ? detail.fixture.homeClan
      : side === "AWAY"
        ? detail.fixture.awayClan
        : null;
    return clan ? `${clan.name} · original payer` : "Original clan payer";
  }
  const team = side === "WHITE"
    ? "White team"
    : side === "BLACK"
      ? "Black team"
      : "Solo player";
  const profile = refund.recipientProfileId?.slice(0, 8);
  return `${team} payer${profile ? ` · ${profile}` : ""}`;
}

type ResolutionEffects = {
  homeRefundPercent: string;
  awayRefundPercent: string;
  homeSrDelta: string;
  awaySrDelta: string;
  homeStrikes: string;
  awayStrikes: string;
  homeAttendanceState: string;
  awayAttendanceState: string;
};

type PlayerAttendanceState = "PRESENT" | "LATE" | "EXCUSED" | "NO_SHOW";

type AdminResolutionPreview = {
  preview: boolean;
  case_id: string;
  current_revision: number;
  next_revision: number;
  is_correction: boolean;
  resolution_type: string;
  would_set_case_state: string;
  consequences: Record<string, unknown>;
  refunds: Array<{
    side: string | null;
    amount_fils: number;
    target_amount_fils: number;
    previously_refunded_fils: number;
    refund_bps: number;
    destination: string | null;
    status: string | null;
    failure_reason: string | null;
  }>;
};

const RESOLUTION_OUTCOMES: ReadonlyArray<{
  type: MatchResolutionType;
  title: string;
  description: string;
  consequence: string;
}> = [
  {
    type: "RECORDED_RESULT",
    title: "Recorded result",
    description: "A reliable final score is available.",
    consequence: "Record the verified score and use the normal match settlement policy.",
  },
  {
    type: "HOME_NO_SHOW",
    title: "Home / white no-show",
    description: "The home or white side did not appear; the other side did.",
    consequence: "The present away or black side receives a full refund. The absent side uses the configured no-show SR and strike policy.",
  },
  {
    type: "AWAY_NO_SHOW",
    title: "Away / black no-show",
    description: "The away or black side did not appear; the other side did.",
    consequence: "The present home or white side receives a full refund. The absent side uses the configured no-show SR and strike policy.",
  },
  {
    type: "BOTH_NO_SHOW",
    title: "Both sides no-show",
    description: "Neither side appeared for the match.",
    consequence: "Neither side receives a refund. Both sides use the configured no-show SR loss and strike policy.",
  },
  {
    type: "FIELD_OR_VENUE_CANCELLATION",
    title: "Field / venue cancellation",
    description: "Field, venue, weather or operations prevented play.",
    consequence: "Both sides receive full refunds with no SR loss or strikes.",
  },
  {
    type: "MUTUAL_CANCELLATION",
    title: "Mutual cancellation",
    description: "Both sides agreed not to play and neither is at fault.",
    consequence: "Both sides receive full refunds with no SR loss or strikes.",
  },
  {
    type: "BOTH_AT_FAULT",
    title: "Both sides at fault",
    description: "Both sides caused the match not to be played.",
    consequence: "Neither side receives a refund. Both sides use the configured SR and strike consequences.",
  },
  {
    type: "ADMINISTRATIVE_VOID",
    title: "Administrative void",
    description: "Field is voiding the match without blaming either side.",
    consequence: "Both sides receive full refunds with no SR loss or strikes.",
  },
];

function resolutionDisplayStatus(detail: AdminGameDetail) {
  if (
    detail.resolutionCase &&
    ["NO_DATA", "UNDER_REVIEW"].includes(detail.resolutionCase.state)
  ) {
    return detail.resolutionCase.state;
  }
  if (["NO_DATA", "UNDER_REVIEW"].includes(detail.fixture.operationalState ?? "")) {
    return detail.fixture.operationalState as string;
  }
  return detail.fixture.status;
}

function resolutionAttendanceCandidates(detail: AdminGameDetail) {
  const source = detail.participants.matchKind === "SOLO"
    ? [
        ...detail.participants.registeredPlayers,
        ...detail.participants.actualPlayers,
      ]
    : [
        ...detail.participants.plannedPlayers,
        ...detail.participants.removedPlayers,
        ...detail.participants.actualPlayers,
      ];
  const byProfile = new Map<string, AdminGameParticipant>();
  for (const player of source) {
    const existing = byProfile.get(player.profileId);
    byProfile.set(player.profileId, existing
      ? {
          ...existing,
          ...player,
          side: player.side ?? existing.side,
          role: player.role ?? existing.role,
          clanId: player.clanId ?? existing.clanId,
          checkedInAt: player.checkedInAt ?? existing.checkedInAt,
          attendanceOutcome:
            player.attendanceOutcome ?? existing.attendanceOutcome,
          planned: player.planned || existing.planned,
          played: player.played || existing.played,
        }
      : player);
  }
  const validSides = detail.fixture.matchKind === "SOLO"
    ? new Set(["WHITE", "BLACK"])
    : new Set(["HOME", "AWAY"]);
  return [...byProfile.values()]
    .filter((player) => player.side !== null && validSides.has(player.side))
    .sort((left, right) =>
      left.displayName.localeCompare(right.displayName) ||
      left.profileId.localeCompare(right.profileId)
    );
}

function hasPlayedEvidence(
  player: AdminGameParticipant,
  selectedState: PlayerAttendanceState | "",
) {
  if (selectedState) {
    return selectedState === "PRESENT" || selectedState === "LATE";
  }
  return player.checkedInAt !== null;
}

function recordedAttendanceCounts(
  detail: AdminGameDetail,
  candidates: AdminGameParticipant[],
  values: Record<string, PlayerAttendanceState>,
) {
  const homeCode = detail.fixture.matchKind === "SOLO" ? "WHITE" : "HOME";
  const awayCode = detail.fixture.matchKind === "SOLO" ? "BLACK" : "AWAY";
  const confirmed = (side: string) => candidates.filter(
    (player) =>
      player.side === side &&
      hasPlayedEvidence(player, values[player.profileId] ?? ""),
  ).length;
  return { home: confirmed(homeCode), away: confirmed(awayCode) };
}

function validateRecordedResultAttendance(
  detail: AdminGameDetail,
  candidates: AdminGameParticipant[],
  values: Record<string, PlayerAttendanceState>,
  homeLabel: string,
  awayLabel: string,
) {
  const counts = recordedAttendanceCounts(detail, candidates, values);
  const missing = [
    counts.home < 1 ? homeLabel : null,
    counts.away < 1 ? awayLabel : null,
  ].filter((label): label is string => label !== null);
  if (!missing.length) return null;
  return `Confirm at least one player who took part for ${
    missing.join(" and ")
  }. Select “Played” or “Played · arrived late” next to the player’s name.`;
}

function recordedAttendanceSummary(
  detail: AdminGameDetail,
  candidates: AdminGameParticipant[],
  values: Record<string, PlayerAttendanceState>,
  homeLabel: string,
  awayLabel: string,
) {
  const counts = recordedAttendanceCounts(detail, candidates, values);
  return `Rated lineup: ${homeLabel} ${counts.home} · ${awayLabel} ${counts.away}.`;
}

function emptyResolutionEffects(): ResolutionEffects {
  return {
    homeRefundPercent: "",
    awayRefundPercent: "",
    homeSrDelta: "",
    awaySrDelta: "",
    homeStrikes: "",
    awayStrikes: "",
    homeAttendanceState: "",
    awayAttendanceState: "",
  };
}

function defaultResolutionEffects(type: MatchResolutionType): ResolutionEffects {
  const draft = emptyResolutionEffects();
  if (type === "RECORDED_RESULT") return draft;
  if (type === "HOME_NO_SHOW") {
    return {
      ...draft,
      homeRefundPercent: "0",
      awayRefundPercent: "100",
    };
  }
  if (type === "AWAY_NO_SHOW") {
    return {
      ...draft,
      homeRefundPercent: "100",
      awayRefundPercent: "0",
    };
  }
  if (type === "BOTH_NO_SHOW" || type === "BOTH_AT_FAULT") {
    return {
      ...draft,
      homeRefundPercent: "0",
      awayRefundPercent: "0",
    };
  }
  return {
    ...draft,
    homeRefundPercent: "100",
    awayRefundPercent: "100",
    homeSrDelta: "0",
    awaySrDelta: "0",
    homeStrikes: "0",
    awayStrikes: "0",
  };
}

function validateResolutionEffects(effects: ResolutionEffects) {
  const checks = [
    validateOptionalNumber(effects.homeRefundPercent, 0, 100, "Home / white refund percentage", false),
    validateOptionalNumber(effects.awayRefundPercent, 0, 100, "Away / black refund percentage", false),
    validateOptionalNumber(effects.homeSrDelta, -10_000, 10_000, "Home / white SR delta", true),
    validateOptionalNumber(effects.awaySrDelta, -10_000, 10_000, "Away / black SR delta", true),
    validateOptionalNumber(effects.homeStrikes, 0, 20, "Home / white strikes", true),
    validateOptionalNumber(effects.awayStrikes, 0, 20, "Away / black strikes", true),
  ];
  const invalid = checks.find(Boolean);
  if (invalid) return invalid;
  return null;
}

function validateWholeNumber(value: string, min: number, max: number, label: string) {
  if (!value.trim()) return `${label} is required.`;
  return validateOptionalNumber(value, min, max, label, true);
}

function validateOptionalNumber(
  value: string,
  min: number,
  max: number,
  label: string,
  whole: boolean,
) {
  if (!value.trim()) return null;
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < min || parsed > max || (whole && !Number.isInteger(parsed))) {
    return `${label} must be ${whole ? "a whole number " : ""}between ${min.toLocaleString()} and ${max.toLocaleString()}.`;
  }
  return null;
}

function buildResolutionPayload(
  type: MatchResolutionType,
  homeScore: string,
  awayScore: string,
  effects: ResolutionEffects,
  playerAttendance: Record<string, PlayerAttendanceState>,
) {
  const payload: Record<string, unknown> = {};
  if (type === "RECORDED_RESULT") {
    payload.home_score = Number(homeScore);
    payload.away_score = Number(awayScore);
  }
  if (effects.homeRefundPercent.trim()) payload.home_refund_bps = Math.round(Number(effects.homeRefundPercent) * 100);
  if (effects.awayRefundPercent.trim()) payload.away_refund_bps = Math.round(Number(effects.awayRefundPercent) * 100);
  if (effects.homeSrDelta.trim()) payload.home_sr_delta = Number(effects.homeSrDelta);
  if (effects.awaySrDelta.trim()) payload.away_sr_delta = Number(effects.awaySrDelta);
  if (effects.homeStrikes.trim()) payload.home_strikes = Number(effects.homeStrikes);
  if (effects.awayStrikes.trim()) payload.away_strikes = Number(effects.awayStrikes);
  const hasSideAttendance =
    effects.homeAttendanceState.trim() ||
    effects.awayAttendanceState.trim();
  const playerEntries = Object.entries(playerAttendance);
  if (playerEntries.length || hasSideAttendance) {
    const attendance: Record<string, unknown> = {};
    if (playerEntries.length) {
      attendance.players = playerEntries.map(([profileId, state]) => ({
        profile_id: profileId,
        state,
      }));
    }
    if (effects.homeAttendanceState.trim()) {
      attendance.HOME = effects.homeAttendanceState.trim();
      attendance.WHITE = effects.homeAttendanceState.trim();
    }
    if (effects.awayAttendanceState.trim()) {
      attendance.AWAY = effects.awayAttendanceState.trim();
      attendance.BLACK = effects.awayAttendanceState.trim();
    }
    payload.attendance = attendance;
  }
  return payload;
}

function percentOrPolicy(value: string) {
  return value.trim() ? `${Number(value).toLocaleString()}%` : "Policy default";
}

function deltaOrPolicy(value: string) {
  if (!value.trim()) return "Policy default";
  const parsed = Number(value);
  if (parsed === 0) return "No change";
  return parsed > 0 ? `+${parsed}` : String(parsed);
}

function numberOrPolicy(value: string) {
  return value.trim() ? Number(value).toLocaleString() : "Policy default";
}

function previewConsequenceLine(
  preview: AdminResolutionPreview,
  side: "home" | "away",
  playerSrIsIndividual: boolean,
) {
  const consequences = preview.consequences;
  const refundBps = numericValue(consequences[`${side}_refund_bps`]);
  const srDelta = numericValue(
    consequences[`${side}_sr_delta_applied`] ??
      consequences[`${side}_sr_delta`],
  );
  const strikes = numericValue(consequences[`${side}_strikes`]);
  const srLabel = playerSrIsIndividual
    ? "player SR calculated individually"
    : srDelta === 0
      ? "no SR change"
      : `${srDelta > 0 ? "+" : ""}${srDelta} SR`;
  return `${refundBps / 100}% refund · ${srLabel} · ${strikes} ${
    strikes === 1 ? "strike" : "strikes"
  }`;
}

function previewRefundLine(
  preview: AdminResolutionPreview,
  side: "home" | "away",
  label: string,
  currency: AdminGameCurrency,
) {
  const acceptedSides = side === "home"
    ? new Set(["HOME", "WHITE"])
    : new Set(["AWAY", "BLACK"]);
  const refunds = preview.refunds.filter((refund) =>
    acceptedSides.has(refund.side?.toUpperCase() ?? "")
  );
  if (refunds.length === 0) return `${label}: no paid refund due`;

  const targetFils = refunds.reduce(
    (sum, refund) => sum + numericValue(refund.target_amount_fils),
    0,
  );
  const statuses = [...new Set(
    refunds.map((refund) => refund.status?.toUpperCase()).filter(Boolean),
  )];
  return `${label}: ${formatGameMoney(targetFils, currency)} total · ${
    statuses.length ? statuses.map((status) => humanize(status!)).join(", ") : "Calculated"
  }`;
}

function numericValue(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return 0;
}

function nestedNumber(
  source: Record<string, unknown>,
  ...path: string[]
) {
  let value: unknown = source;
  for (const key of path) {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return null;
    }
    value = (value as Record<string, unknown>)[key];
  }
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
}

const REPORT_CATEGORIES = [
  "HARASSMENT", "THREATS_OR_VIOLENCE", "DISCRIMINATION", "DANGEROUS_PLAY",
  "CHEATING", "NO_SHOW_OR_MATCH_MANIPULATION", "INAPPROPRIATE_CONTENT",
  "SAFETY_OR_VENUE", "SCORE_OR_RESULT", "REFEREE_ABUSE", "OTHER",
] as const;

const CANCELLATION_REASONS = [
  "WEATHER_OR_VENUE", "SAFETY", "NO_REFEREE", "INSUFFICIENT_PLAYERS",
  "TECHNICAL", "ADMIN_DECISION", "OTHER",
] as const;

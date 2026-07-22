"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { useCallback, useEffect, useState } from "react";

import type { AdminGameDetail } from "@/lib/admin-game-detail";
import type { AdminGameParticipant } from "@/lib/admin-game-participants";
import type {
  AdminGameReserve,
  AdminReserveCandidate,
} from "@/lib/admin-game-reserves";
import { createSupabaseBrowserClient } from "@/lib/supabase-browser";
import type { BroadcastControlResponse, FixtureEvent, RefereeFixture } from "@/lib/types";

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
  const [cancelGame, setCancelGame] = useState(false);

  const load = useCallback(async (quiet = false) => {
    if (!accessToken || !gameId || !["SOLO", "CLAN"].includes(matchKind)) return;
    if (!quiet) setLoading(true);
    setError(null);
    try {
      const payload = await fetchJson<{ detail: AdminGameDetail }>(
        `/api/referee/admin/games/${matchKind.toLowerCase()}/${gameId}`,
        { headers: auth(accessToken), cache: "no-store" },
      );
      setDetail(payload.detail);
    } catch (loadError) {
      setError(message(loadError, "Could not load this game."));
    } finally {
      setLoading(false);
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
  const activeReserve = detail.reserves.active[0];
  return (
    <main className={styles.page}>
      <header className={styles.topbar}>
        <Link className={styles.back} href="/admin?section=games">← <span>All games</span></Link>
        <div className={styles.brand}><i>F</i><span>FIELD ADMIN</span></div>
        <button onClick={() => void load(true)} type="button">Refresh</button>
      </header>

      {error ? <div className={styles.error} role="alert">{error}<button onClick={() => setError(null)}>×</button></div> : null}
      {notice ? <div className={styles.notice} role="status">{notice}<button onClick={() => setNotice(null)}>×</button></div> : null}

      <section className={styles.hero}>
        <div className={styles.heroMeta}>
          <span className={styles.kind}>{fixture.matchKind === "SOLO" ? "SOLO QUEUE" : "CLAN FIXTURE"}</span>
          <Status status={fixture.status} />
        </div>
        <div className={styles.scoreboard}>
          <Team clan={fixture.homeClan} />
          <div className={styles.score}>
            <strong>{score(fixture)}</strong>
            <span>{fixture.status === "FINAL" ? "FINAL SCORE" : fixture.status === "LIVE" ? "LIVE" : "VS"}</span>
          </div>
          <Team clan={fixture.awayClan} align="right" />
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
        <Metric label="Reserve player" value={`${detail.reserves.active.length} / 1`} detail="One game-wide standby" />
        <Metric label="Reports" value={String(detail.reports.length)} detail={detail.reports.length ? "Needs awareness" : "No match reports"} tone={detail.reports.length ? "warning" : "good"} />
      </section>

      <div className={styles.grid}>
        <div className={styles.mainColumn}>
          <section className={styles.card}>
            <SectionHead eyebrow="MATCHDAY COVER" title="Reserve player" detail="Choose any eligible Field player as the single standby for this game. Assigning them does not charge them, place them in the official six, or change rating eligibility." />
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
          </section>

          <section className={styles.card}>
            <SectionHead eyebrow="OFFICIAL ROSTER" title="Players" detail="Confirmed, checked-in and historical participation for this game." />
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
              <div><dt>Average SR</dt><dd>{fixture.matchAverageSr ?? "Not available"}</dd></div>
              <div><dt>Team spread</dt><dd>{fixture.teamSrSpread === null ? "Not available" : `${fixture.teamSrSpread} SR`}</dd></div>
              <div><dt>Referee phone</dt><dd>{detail.assignedReferee?.phone ?? "—"}</dd></div>
            </dl>
            {fixture.cancellationReason ? (
              <div className={styles.cancellation}><strong>{fixture.cancellationCode ?? "Cancelled"}</strong><p>{fixture.cancellationReason}</p></div>
            ) : null}
          </section>

          <section className={styles.card}>
            <SectionHead eyebrow="ADMIN CONTROLS" title="Resolve game issues" detail="Every action requires a reason and is permanently audited." />
            <div className={styles.adminActions}>
              <Link className={styles.secondaryButton} href={`/admin?section=games&gameId=${fixture.id}`}>
                {detail.assignedReferee ? "Change referee" : "Assign referee"}
              </Link>
              <button
                className={styles.dangerButton}
                disabled={!canCancelGame(fixture.status)}
                onClick={() => setCancelGame(true)}
                type="button"
              >
                Cancel game
              </button>
            </div>
            <p className={styles.actionHint}>Admin cancellation gives every payer a 100% Field Wallet refund, including held reliability deposits.</p>
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

      {addingReserve ? (
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
      {removeReserve ? (
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
          {loading ? <p>Searching players…</p> : candidates.length === 0 ? <p>No matching players found.</p> : candidates.map((candidate) => (
            <button
              className={selected?.profileId === candidate.profileId ? styles.selectedCandidate : ""}
              disabled={!candidate.eligible}
              key={candidate.profileId}
              onClick={() => setSelected(candidate)}
              type="button"
            >
              <Avatar name={candidate.displayName} url={candidate.avatarUrl} />
              <span><strong>{candidate.displayName}</strong><small>{candidate.username ? `@${candidate.username.replace(/^@/, "")} · ` : ""}{candidate.skillRating} SR</small></span>
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
        <div className={styles.refundNotice}><strong>100% refund</strong><p>All paid match fees and held reliability deposits are returned to their original payers through Field Wallet.</p></div>
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

function Team({ clan, align }: { clan: RefereeFixture["homeClan"]; align?: "right" }) {
  return <div className={`${styles.team} ${align ? styles.alignRight : ""}`}><span>{clan.emblem}</span><div><strong>{clan.name}</strong><small>{clan.tag} · {clan.skillRating} SR</small></div></div>;
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
  return <main className={styles.skeleton}><header /><section /><div><i /><i /><i /><i /></div></main>;
}

function canManageReserves(status: string) { return ["OPEN", "FULL", "SCHEDULED"].includes(status); }
function canCancelGame(status: string) { return !["FINAL", "CANCELLED"].includes(status); }

function confirmedCount(detail: AdminGameDetail) {
  return String(detail.participants.matchKind === "SOLO" ? detail.participants.counts.registered : detail.participants.counts.planned);
}

function capacityLabel(detail: AdminGameDetail) {
  return detail.participants.matchKind === "SOLO" ? `${detail.participants.capacity} game places` : "Confirmed clan roster";
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

const REPORT_CATEGORIES = [
  "HARASSMENT", "THREATS_OR_VIOLENCE", "DISCRIMINATION", "DANGEROUS_PLAY",
  "CHEATING", "NO_SHOW_OR_MATCH_MANIPULATION", "INAPPROPRIATE_CONTENT",
  "SAFETY_OR_VENUE", "SCORE_OR_RESULT", "REFEREE_ABUSE", "OTHER",
] as const;

const CANCELLATION_REASONS = [
  "WEATHER_OR_VENUE", "SAFETY", "NO_REFEREE", "INSUFFICIENT_PLAYERS",
  "TECHNICAL", "ADMIN_DECISION", "OTHER",
] as const;

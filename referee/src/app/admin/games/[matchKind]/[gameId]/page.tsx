"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { useCallback, useEffect, useMemo, useState } from "react";

import type { AdminGameDetail } from "@/lib/admin-game-detail";
import type { AdminGameParticipant } from "@/lib/admin-game-participants";
import type {
  AdminGameReserve,
  AdminGameReserveSide,
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
  const [reserveSide, setReserveSide] = useState<AdminGameReserveSide | null>(null);
  const [removeReserve, setRemoveReserve] = useState<AdminGameReserve | null>(null);

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
  const sides = reserveSides(fixture);
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
        <Metric label="Reserves assigned" value={`${detail.reserves.active.length} / 2`} detail="One standby per side" />
        <Metric label="Reports" value={String(detail.reports.length)} detail={detail.reports.length ? "Needs awareness" : "No match reports"} tone={detail.reports.length ? "warning" : "good"} />
      </section>

      <div className={styles.grid}>
        <div className={styles.mainColumn}>
          <section className={styles.card}>
            <SectionHead eyebrow="MATCHDAY COVER" title="Reserve players" detail="A reserve is standby-only. Assigning one does not charge them, place them in the official six, or change rating eligibility." />
            <div className={styles.reserveGrid}>
              {sides.map((side) => {
                const reserve = detail.reserves.active.find((item) => item.side === side.id);
                return (
                  <ReserveSlot
                    key={side.id}
                    label={side.label}
                    reserve={reserve}
                    locked={!canManageReserves(fixture.status)}
                    onAdd={() => setReserveSide(side.id)}
                    onRemove={() => reserve && setRemoveReserve(reserve)}
                  />
                );
              })}
            </div>
            {detail.reserves.history.length ? (
              <details className={styles.history}>
                <summary>Previous reserve assignments · {detail.reserves.history.length}</summary>
                {detail.reserves.history.map((reserve) => (
                  <div key={reserve.id}>
                    <span>{reserve.displayName} · {sideLabel(fixture, reserve.side)}</span>
                    <small>{reserve.removalReason} · {formatDateTime(reserve.removedAt)}</small>
                  </div>
                ))}
              </details>
            ) : null}
          </section>

          <section className={styles.card}>
            <SectionHead eyebrow="OFFICIAL ROSTER" title="Players" detail="Confirmed, checked-in and historical participation for this game." />
            <ParticipantGroups detail={detail} />
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

      {reserveSide ? (
        <AddReserveDialog
          accessToken={accessToken}
          detail={detail}
          side={reserveSide}
          onClose={() => setReserveSide(null)}
          onSaved={async (savedNotice) => {
            setReserveSide(null);
            setNotice(savedNotice);
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

function AddReserveDialog({ accessToken, detail, side, onClose, onSaved }: {
  accessToken: string;
  detail: AdminGameDetail;
  side: AdminGameReserveSide;
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
      const params = new URLSearchParams({ side, query });
      void fetchJson<{ candidates: AdminReserveCandidate[] }>(
        `/api/referee/admin/games/${fixture.matchKind.toLowerCase()}/${fixture.id}/reserves?${params}`,
        { headers: auth(accessToken), cache: "no-store" },
      ).then((payload) => setCandidates(payload.candidates))
        .catch((loadError) => setError(message(loadError, "Could not search players.")))
        .finally(() => setLoading(false));
    }, 250);
    return () => window.clearTimeout(timer);
  }, [accessToken, fixture.id, fixture.matchKind, query, side]);

  async function submit() {
    if (!selected || note.trim().length < 3) return;
    setSaving(true); setError(null);
    try {
      await fetchJson(
        `/api/referee/admin/games/${fixture.matchKind.toLowerCase()}/${fixture.id}/reserves`,
        {
          method: "POST",
          headers: { ...auth(accessToken), "Content-Type": "application/json" },
          body: JSON.stringify({ profileId: selected.profileId, side, note }),
        },
      );
      await onSaved(`${selected.displayName} assigned as ${sideLabel(fixture, side)} reserve.`);
    } catch (saveError) {
      setError(message(saveError, "Could not assign this reserve."));
      setSaving(false);
    }
  }

  return (
    <div className={styles.modalBackdrop} role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <section aria-modal="true" className={styles.modal} role="dialog">
        <header><div><span>ADD RESERVE</span><h2>{sideLabel(fixture, side)}</h2></div><button onClick={onClose}>×</button></header>
        <p className={styles.modalIntro}>Choose one standby player. They remain outside the official roster until match operations explicitly replace someone.</p>
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

function ReserveSlot({ label, reserve, locked, onAdd, onRemove }: {
  label: string;
  reserve?: AdminGameReserve;
  locked: boolean;
  onAdd: () => void;
  onRemove: () => void;
}) {
  return (
    <article className={`${styles.reserveSlot} ${reserve ? styles.filledReserve : ""}`}>
      <div className={styles.reserveLabel}><span>{label}</span><b>{reserve ? "ASSIGNED" : "OPEN SLOT"}</b></div>
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

function ParticipantGroups({ detail }: { detail: AdminGameDetail }) {
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
        return <section key={definition.name}><header><strong>{definition.name}</strong><span>{players.length}</span></header>{players.map((player) => <PlayerRow key={player.profileId} player={player} />)}</section>;
      })}
      {!active.length ? <div className={styles.emptyList}>No confirmed players yet.</div> : null}
    </div>
  );
}

function PlayerRow({ player }: { player: AdminGameParticipant }) {
  return <div className={styles.playerRow}><Avatar name={player.displayName} url={player.avatarUrl} /><span><strong>{player.displayName}</strong><small>{player.username ? `@${player.username.replace(/^@/, "")} · ` : ""}{player.role ? humanize(player.role) : "Player"}</small></span><div>{player.checkedInAt ? <b>Checked in</b> : null}{player.ratingAtTeamAssignment !== null ? <em>{player.ratingAtTeamAssignment} SR</em> : null}</div></div>;
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

function reserveSides(fixture: RefereeFixture): Array<{ id: AdminGameReserveSide; label: string }> {
  return fixture.matchKind === "SOLO"
    ? [{ id: "WHITE", label: "White team reserve" }, { id: "BLACK", label: "Black team reserve" }]
    : [{ id: "HOME", label: `${fixture.homeClan.name} reserve` }, { id: "AWAY", label: `${fixture.awayClan.name} reserve` }];
}

function sideLabel(fixture: RefereeFixture, side: AdminGameReserveSide) {
  if (side === "WHITE") return "White team";
  if (side === "BLACK") return "Black team";
  return side === "HOME" ? fixture.homeClan.name : fixture.awayClan.name;
}

function canManageReserves(status: string) { return ["OPEN", "FULL", "SCHEDULED"].includes(status); }

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

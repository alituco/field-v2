"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { useCallback, useEffect, useState } from "react";

import type { AdminSubjectDetail } from "@/lib/admin-subject-detail";
import { createSupabaseBrowserClient } from "@/lib/supabase-browser";

import styles from "./subject-detail.module.css";

const supabase = createSupabaseBrowserClient();

export default function AdminSubjectDetailPage() {
  const params = useParams<{ subjectType: string; subjectId: string }>();
  const subjectType = String(params.subjectType ?? "").toUpperCase();
  const subjectId = String(params.subjectId ?? "");
  const [token, setToken] = useState<string | null>(null);
  const [sessionChecked, setSessionChecked] = useState(false);
  const [detail, setDetail] = useState<AdminSubjectDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!token || !["PLAYER", "CLAN"].includes(subjectType)) return;
    setLoading(true); setError(null);
    try {
      const response = await fetch(`/api/referee/admin/subjects/${subjectType.toLowerCase()}/${subjectId}`, {
        headers: { authorization: `Bearer ${token}` }, cache: "no-store",
      });
      const payload = await response.json() as { detail?: AdminSubjectDetail; error?: string };
      if (!response.ok || !payload.detail) throw new Error(payload.error ?? "Could not load this record.");
      setDetail(payload.detail);
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : "Could not load this record.");
    } finally {
      setLoading(false);
    }
  }, [subjectId, subjectType, token]);

  useEffect(() => {
    void supabase.auth.getSession().then(({ data }) => {
      setToken(data.session?.access_token ?? null);
      setSessionChecked(true);
    });
    const { data } = supabase.auth.onAuthStateChange((_event, session) => {
      setToken(session?.access_token ?? null); setSessionChecked(true);
    });
    return () => data.subscription.unsubscribe();
  }, []);
  useEffect(() => { if (token) void load(); else if (sessionChecked) setLoading(false); }, [load, sessionChecked, token]);

  if (!sessionChecked || loading) return <main className={styles.loading} role="status" aria-label="Loading account history"><i aria-hidden="true" /><i aria-hidden="true" /><i aria-hidden="true" /></main>;
  if (!token || !detail) return <State title={!token ? "Sign in required" : "Record unavailable"} detail={error ?? "This record could not be found."} />;

  const activeStrikes = detail.incidents.reduce((total, incident) => total + (incident.expiresAt && Date.parse(incident.expiresAt) <= Date.now() ? 0 : incident.strikeDelta), 0);
  return (
    <main className={styles.page}>
      <header className={styles.topbar}>
        <Link href="/admin?section=people">← <span>Players & clans</span></Link>
        <div><i>F</i><span>FIELD ADMIN</span></div>
        <button onClick={() => void load()} type="button">Refresh</button>
      </header>

      <section className={styles.hero}>
        <div className={styles.identity}>
          <Avatar detail={detail} />
          <div><span>{detail.subjectType} RECORD</span><h1>{detail.name}</h1><p>{detail.secondary ? `${detail.subjectType === "PLAYER" ? "@" : ""}${detail.secondary.replace(/^@/, "")}` : "No public identifier"}</p></div>
        </div>
        <div className={styles.health}>
          <strong>{detail.archivedAt ? "ARCHIVED" : detail.actions.some((action) => !action.revokedAt) ? "ACTION ACTIVE" : "CLEAR"}</strong>
          <span>{detail.reports.length} lifetime reports · {Math.max(0, activeStrikes)} active strikes</span>
        </div>
      </section>

      <section className={styles.facts}>{detail.facts.map((fact) => <article key={fact.label}><span>{fact.label}</span><strong>{fact.value}</strong></article>)}</section>

      <div className={styles.grid}>
        <div className={styles.main}>
          <Section title="Match history" count={detail.games.length} description="Every recorded clan and Solo Queue appearance or booking.">
            {detail.games.length ? <div className={styles.games}>{detail.games.map((game) => (
              <Link href={`/admin/games/${game.matchKind.toLowerCase()}/${game.id}`} key={`${game.matchKind}-${game.id}`}>
                <span className={styles.kind}>{game.matchKind}</span>
                <div><strong>{game.label}</strong><small>{dateText(game.date)} · {game.venue || "Venue unavailable"} · {humanize(game.status)}</small></div>
                <b>{game.result}</b>
                <em>{game.ratingChange === null ? (game.role ? humanize(game.role) : "View") : signed(game.ratingChange)}</em>
              </Link>
            ))}</div> : <Empty text="No games recorded." />}
          </Section>

          {detail.subjectType === "PLAYER" ? (
            <Section title="Clan history" count={detail.memberships.length} description="Current and previous clan memberships, including dates and roles.">
              {detail.memberships.length ? <div className={styles.memberships}>{detail.memberships.map((membership, index) => (
                <Link href={`/admin/people/clan/${membership.id}`} key={`${membership.id}-${index}`}>
                  <span>{membership.emblem}</span><div><strong>{membership.name} · {membership.tag}</strong><small>{humanize(membership.role)} · {dateText(membership.startedAt)} → {membership.endedAt ? dateText(membership.endedAt) : "Present"}</small></div><b>{membership.endedAt ? "FORMER" : "CURRENT"}</b>
                </Link>
              ))}</div> : <Empty text="No clan membership recorded." />}
            </Section>
          ) : (
            <Section title="Member history" count={detail.members.length} description="Active and former clan members remain visible for operational history.">
              {detail.members.length ? <div className={styles.memberships}>{detail.members.map((member) => (
                <Link href={`/admin/people/player/${member.profileId}`} key={`${member.profileId}-${member.joinedAt}`}>
                  <AvatarMini name={member.name} url={member.avatarUrl} /><div><strong>{member.name}</strong><small>{member.username ? `@${member.username.replace(/^@/, "")} · ` : ""}{humanize(member.role)} · Joined {dateText(member.joinedAt)}</small></div><b>{member.leftAt ? `LEFT ${dateText(member.leftAt)}` : "ACTIVE"}</b>
                </Link>
              ))}</div> : <Empty text="No members recorded." />}
            </Section>
          )}

          {detail.subjectType === "PLAYER" ? (
            <Section title="Player SR ledger" count={detail.ratingEvents.length} description="Independent Keeper and Outfield updates. Historical pre-reset entries stay labelled Legacy.">
              {detail.ratingEvents.length ? <div className={styles.ledger}>{detail.ratingEvents.map((event) => <article key={event.id}><div><strong>{event.ratingTrack === "GOALKEEPER" ? "Keeper" : event.ratingTrack === "OUTFIELD" ? "Outfield" : "Legacy"} · {humanize(event.sourceType)} · {humanize(event.result)}</strong><small>{dateText(event.createdAt)} · {event.sourceId.slice(0, 8)}</small></div><span>{event.before} → {event.after}</span><b className={event.change >= 0 ? styles.positive : styles.negative}>{signed(event.change)}</b></article>)}</div> : <Empty text="No rating changes recorded." />}
            </Section>
          ) : null}
        </div>

        <aside className={styles.side}>
          <Section title="Reports received" count={detail.reports.length} description="Complete moderation history for this subject.">
            {detail.reports.length ? <div className={styles.stack}>{detail.reports.map((report) => <article key={report.id}><header><b className={styles[report.priority.toLowerCase()]}>{humanize(report.priority)}</b><span>{humanize(report.status)}</span></header><strong>{humanize(report.category)}</strong><p>{report.details || "No written detail."}</p><small>Reported by {report.reporterName} · {humanize(report.source)} · {dateText(report.createdAt)}{report.matchId ? ` · Match ${report.matchId.slice(0, 8)}` : ""}</small>{report.assignedTo ? <small>Assigned to {report.assignedTo}</small> : null}{report.resolutionNote ? <em>{report.resolutionNote}{report.resolvedAt ? ` · ${dateText(report.resolvedAt)}` : ""}</em> : null}</article>)}</div> : <Empty text="No reports received." />}
          </Section>

          <Section title="Warnings & restrictions" count={detail.actions.length} description="Active, expired, and revoked moderation actions.">
            {detail.actions.length ? <div className={styles.stack}>{detail.actions.map((action) => <article key={action.id}><header><b>{humanize(action.actionType)}</b><span>{action.revokedAt ? "REVOKED" : action.endsAt && Date.parse(action.endsAt) <= Date.now() ? "EXPIRED" : "ACTIVE"}</span></header><strong>{humanize(action.reasonCode)}</strong><p>{action.privateNote || action.userMessage}</p><small>{dateText(action.startsAt)}{action.endsAt ? ` → ${dateText(action.endsAt)}` : ""}</small></article>)}</div> : <Empty text="No warnings or restrictions." />}
          </Section>

          <Section title="Reliability strikes" count={detail.incidents.length} description="Append-only strike history, including expiry and reversals.">
            {detail.incidents.length ? <div className={styles.ledger}>{detail.incidents.map((incident) => <article key={incident.id}><div><strong>{humanize(incident.outcome)}</strong><small>{dateText(incident.occurredAt)}{incident.expiresAt ? ` · expires ${dateText(incident.expiresAt)}` : ""}</small></div><span>{incident.activeBefore} → {incident.activeAfter}</span><b className={incident.reversed || incident.strikeDelta < 0 ? styles.positive : styles.negative}>{signed(incident.strikeDelta)}</b></article>)}</div> : <Empty text="No reliability incidents." />}
          </Section>

          <Section title="Admin audit" count={detail.audit.length} description="Permanent direct changes to this record.">
            {detail.audit.length ? <div className={styles.audit}>{detail.audit.map((item) => <article key={item.id}><i /><div><strong>{humanize(item.action)}</strong><p>{item.reason || "No reason provided."}</p><small>{dateText(item.createdAt)}</small></div></article>)}</div> : <Empty text="No direct admin actions." />}
          </Section>
        </aside>
      </div>
    </main>
  );
}

function Section({ title, count, description, children }: { title: string; count: number; description: string; children: React.ReactNode }) {
  return <section className={styles.card}><header><div><span>ADMIN RECORD</span><h2>{title}</h2><p>{description}</p></div><b>{count}</b></header>{children}</section>;
}
function Empty({ text }: { text: string }) { return <div className={styles.empty}>{text}</div>; }
function Avatar({ detail }: { detail: AdminSubjectDetail }) { return detail.subjectType === "CLAN" ? <span className={styles.avatar}>{detail.avatar ?? "⚽"}</span> : detail.avatar ? <img className={styles.avatar} src={detail.avatar} alt="" /> : <span className={styles.avatar}>{initials(detail.name)}</span>; }
function AvatarMini({ name, url }: { name: string; url: string | null }) { return url ? <img className={styles.avatarMini} src={url} alt="" /> : <span className={styles.avatarMini}>{initials(name)}</span>; }
function State({ title, detail }: { title: string; detail: string }) { return <main className={styles.state}><span>FIELD ADMIN</span><h1>{title}</h1><p>{detail}</p><Link href="/admin?section=people">Back to Players & clans</Link></main>; }
function humanize(value: string) { return value.toLowerCase().replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase()); }
function initials(value: string) { return value.split(/\s+/).slice(0, 2).map((part) => part[0]?.toUpperCase()).join("") || "P"; }
function signed(value: number) { return value > 0 ? `+${value}` : String(value); }
function dateText(value: string) { const date = new Date(value.length === 10 ? `${value}T12:00:00Z` : value); return Number.isNaN(date.getTime()) ? value : new Intl.DateTimeFormat("en-BH", { day: "numeric", month: "short", year: "numeric", timeZone: "Asia/Bahrain" }).format(date); }

"use client";

import { useCallback, useEffect, useMemo, useState } from "react";

import type {
  AdminReliabilityAppealQueueItem,
  AdminReliabilityPolicyPayload,
  AdminReliabilityQueueItem,
} from "@/lib/admin-reliability";
import {
  RELIABILITY_APPEAL_CATEGORIES,
  RELIABILITY_CLAN_DEPOSIT_FORFEIT_OUTCOMES,
  RELIABILITY_FORFEIT_OUTCOMES,
  bpsToPercent,
  cloneReliabilityPolicyConfig,
  diffReliabilityPolicyConfigs,
  percentToBps,
  reliabilityPolicyDefaults,
  reliabilityTimelineForKickoff,
  resolveReliabilityPolicyAt,
  validateReliabilityPolicyConfig,
  type ReliabilityPolicyConfig,
  type ReliabilityPolicyVersion,
  type ReliabilitySanctionKind,
} from "@/lib/reliability-policy";

import styles from "./reliability-section.module.css";

type ReliabilityTab = "policy" | "operations" | "history";
type JsonRecord = Record<string, unknown>;
type QueueItem = AdminReliabilityQueueItem;
type ReliabilityPayload = AdminReliabilityPolicyPayload & {
  attendanceQueue?: QueueItem[];
  appealsQueue?: AdminReliabilityAppealQueueItem[];
};
type AppealReviewDecision = "UPHOLD" | "OVERTURN";

type FieldSpec = {
  path: string;
  label: string;
  hint?: string;
  kind: "number" | "bps" | "toggle";
  unit?: string;
  minimum?: number;
  maximum?: number;
};

type FieldSection = {
  id: string;
  title: string;
  detail: string;
  fields: FieldSpec[];
};

const FIELD_SECTIONS: FieldSection[] = [
  {
    id: "attendance-clock",
    title: "Attendance clock",
    detail: "The referee can start check-in at any time. Server time still decides whether an arrival is on time, late, or a no-show.",
    fields: [
      numberField("attendance.checkInOpenLeadMinutes", "Arrival reminder begins", "min before kickoff", 0, 10_080),
      numberField("attendance.checkInLeadMinutes", "Check-in deadline", "min before kickoff", 0, 1_440),
      numberField("attendance.noShowGraceMinutes", "No-show cutoff", "min after kickoff", 0, 180),
      numberField("attendance.strikeLifetimeDays", "Strike lifetime", "days", 1, 3_650),
      numberField("attendance.appealWindowHours", "Appeal window", "hours", 1, 720),
    ],
  },
  {
    id: "solo-structure",
    title: "Solo match controls",
    detail: "Team finalization, party lock, and the refund used when a suspension releases unrelated bookings. Solo remains fixed at six players per side.",
    fields: [
      numberField("solo.teamAssignmentLeadMinutes", "Assign teams and kits", "min before", 0, 10_080),
      numberField("solo.partyLockLeadMinutes", "Lock parties", "min before", 0, 10_080),
      bpsField("solo.releaseFutureBookingsRefundBps", "Released booking refund", "%", 100),
      toggleField("solo.highestCrossedOnly", "Apply only the highest newly crossed sanction", "Prevents stacked restrictions when one incident crosses multiple thresholds."),
    ],
  },
  {
    id: "solo-cancellations",
    title: "Solo cancellation bands",
    detail: "The full-refund cutoff must stay earlier than the partial-refund cutoff.",
    fields: [
      numberField("solo.cancellations.early.minimumHoursBeforeKickoff", "Early · starts at", "hours before", 0, 8_760),
      numberField("solo.cancellations.early.strikes", "Early · strikes", "strikes", 0, 20),
      bpsField("solo.cancellations.early.refundBps", "Early · refund", "%", 100),
      toggleField("solo.cancellations.early.advertise", "Early · publish replacement offer"),
      bpsField("solo.cancellations.early.discountBps", "Early · replacement discount", "%", 100),
      toggleField("solo.cancellations.early.notify", "Early · notify players"),
      numberField("solo.cancellations.late.minimumHoursBeforeKickoff", "Late · starts at", "hours before", 0, 8_760),
      numberField("solo.cancellations.late.strikes", "Late · strikes", "strikes", 0, 20),
      bpsField("solo.cancellations.late.refundBps", "Late · refund", "%", 100),
      toggleField("solo.cancellations.late.advertise", "Late · publish replacement offer"),
      bpsField("solo.cancellations.late.discountBps", "Late · replacement discount", "%", 100),
      toggleField("solo.cancellations.late.notify", "Late · notify players"),
      numberField("solo.cancellations.veryLate.strikes", "Very late · strikes", "strikes", 0, 20),
      bpsField("solo.cancellations.veryLate.refundBps", "Very late · refund", "%", 100),
      toggleField("solo.cancellations.veryLate.advertise", "Very late · publish replacement offer"),
      bpsField("solo.cancellations.veryLate.discountBps", "Very late · replacement discount", "%", 100),
      toggleField("solo.cancellations.veryLate.notify", "Very late · notify players"),
      numberField("solo.cancellations.afterKickoff.strikes", "After kickoff · strikes", "strikes", 0, 20),
      bpsField("solo.cancellations.afterKickoff.refundBps", "After kickoff · refund", "%", 100),
    ],
  },
  {
    id: "solo-outcomes",
    title: "Solo attendance outcomes",
    detail: "One final outcome produces the strike and wallet refund shown here.",
    fields: [
      numberField("solo.outcomes.onTime.strikes", "On time · strikes", "strikes", 0, 20),
      bpsField("solo.outcomes.onTime.refundBps", "On time · refund", "%", 100),
      numberField("solo.outcomes.late.strikes", "Late · strikes", "strikes", 0, 20),
      bpsField("solo.outcomes.late.refundBps", "Late · refund", "%", 100),
      numberField("solo.outcomes.noShow.strikes", "No-show · strikes", "strikes", 0, 20),
      bpsField("solo.outcomes.noShow.refundBps", "No-show · refund", "%", 100),
      bpsField("solo.outcomes.fieldCancelled.refundBps", "Field cancellation · refund", "%", 100),
    ],
  },
  {
    id: "deposit-replacement",
    title: "Deposit and replacement",
    detail: "The refundable reliability deposit and the last-minute replacement sequence.",
    fields: [
      numberField("solo.reliabilityDeposit.activeStrikeThreshold", "Player deposit starts at", "active strikes", 1, 20),
      bpsField("solo.reliabilityDeposit.depositBps", "Player reliability deposit", "%", 100),
      toggleField("replacement.postCheckInDeadlineMarketplaceEnabled", "Keep marketplace open after check-in deadline", "Disabled closes all new bookings at the hard check-in deadline and hides the match from joinable listings."),
      numberField("replacement.originalPlayerReclaimUntilMinutesAfterKickoff", "Original player may reclaim until", "min after kickoff", 0, 180),
      numberField("replacement.reserveActivationMinutesAfterKickoff", "Reserve place becomes final", "min after kickoff", 0, 180),
      numberField("replacement.maxPartySize", "Maximum party size", "players", 1, 4),
    ],
  },
  {
    id: "sr-protection",
    title: "SR and shorthanded protection",
    detail: "Percent values are stored precisely as basis points and shown here as normal percentages.",
    fields: [
      bpsField("sr.latePositiveMultiplierBps", "Late player · positive SR retained", "%", 200),
      bpsField("sr.lateNegativeMultiplierBps", "Late player · negative SR applied", "%", 200),
      numberField("sr.shorthandedQualifyingActualMinutes", "Protection activates after", "actual min", 0, 180),
      bpsField("sr.protectedLosingOnTimeMultiplierBps", "Responsible losers · negative SR", "%", 200),
      bpsField("sr.protectedWinnerMultiplierBps", "Opposing winners · positive SR", "%", 200),
      bpsField("sr.disadvantagedWinnerMultiplierBps", "Disadvantaged winners · positive SR", "%", 200),
      toggleField("sr.latePlayerGetsTeamProtection", "Late player receives team protection"),
    ],
  },
  {
    id: "injury",
    title: "Verified injury",
    detail: "These rules apply only when the referee records that the player cannot continue.",
    fields: [
      bpsField("injury.halfMatchThresholdBps", "Match-completion threshold", "%", 100),
      bpsField("injury.completedLossMultiplierBps", "After threshold · losing SR applied", "%", 200),
      bpsField("injury.incompleteLosingMultiplierBps", "Before threshold · losing SR applied", "%", 200),
      bpsField("injury.incompleteWinningMultiplierBps", "Before threshold · winner SR applied", "%", 200),
      bpsField("injury.incompleteRefundBps", "Before threshold · refund", "%", 100),
    ],
  },
  {
    id: "clan-attendance",
    title: "Clan attendance",
    detail: "The product is seeded for seven-a-side. Individual player outcomes still apply separately.",
    fields: [
      numberField("clan.minimumOnTimeWithoutClanStrike", "Minimum on time without clan strike", "players", 1, 20),
      numberField("clan.minimumAtKickoffWithoutForfeit", "Minimum at kickoff without forfeit", "players", 1, 20),
      numberField("clan.partialAttendanceStrikes", "Short at deadline · clan strikes", "strikes", 0, 20),
      numberField("clan.forfeitStrikes", "Below minimum at kickoff · clan strikes", "strikes", 0, 20),
      numberField("clan.entireClanNoShowStrikes", "Entire clan no-show · strikes", "strikes", 0, 20),
      numberField("clan.forfeitScore", "Forfeit winning score", "goals", 0, 99),
    ],
  },
  {
    id: "clan-cancellations",
    title: "Clan cancellation and deposit",
    detail: "Server-calculated Field Wallet refunds, clan strikes, and refundable reliability deposits. Every checkout snapshots the policy for that kickoff date.",
    fields: [
      numberField("clan.cancellations.early.minimumHoursBeforeKickoff", "Early · starts at", "hours before", 0, 8_760),
      numberField("clan.cancellations.early.strikes", "Early · clan strikes", "strikes", 0, 20),
      bpsField("clan.cancellations.early.refundBps", "Early · fee refund", "%", 100),
      numberField("clan.cancellations.late.minimumHoursBeforeKickoff", "Late · starts at", "hours before", 0, 8_760),
      numberField("clan.cancellations.late.strikes", "Late · clan strikes", "strikes", 0, 20),
      bpsField("clan.cancellations.late.refundBps", "Late · fee refund", "%", 100),
      numberField("clan.cancellations.veryLate.strikes", "Very late · clan strikes", "strikes", 0, 20),
      bpsField("clan.cancellations.veryLate.refundBps", "Very late · fee refund", "%", 100),
      numberField("clan.cancellations.afterKickoff.strikes", "After kickoff · clan strikes", "strikes", 0, 20),
      bpsField("clan.cancellations.afterKickoff.refundBps", "After kickoff · fee refund", "%", 100),
      toggleField("clan.cancellations.afterKickoff.forfeit", "After-kickoff cancellation creates an official forfeit", "When enabled, the opponent receives the configured forfeit score and the match is sent to the audit trail."),
      numberField("clan.reliabilityDeposit.activeStrikeThreshold", "Clan deposit starts at", "active strikes", 1, 20),
      bpsField("clan.reliabilityDeposit.depositBps", "Clan reliability deposit", "%", 100),
    ],
  },
];

export function ReliabilitySection({
  accessToken,
  refreshKey,
  onError,
  onNotice,
}: {
  accessToken: string;
  refreshKey: number;
  onError: (message: string) => void;
  onNotice: (message: string) => void;
}) {
  const [payload, setPayload] = useState<ReliabilityPayload | null>(null);
  const [tab, setTab] = useState<ReliabilityTab>("policy");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);
  const [activeDraftId, setActiveDraftId] = useState<string | null>(null);
  const [editor, setEditor] = useState<ReliabilityPolicyConfig | null>(null);
  const [effectiveDate, setEffectiveDate] = useState("");
  const [summary, setSummary] = useState("");
  const [dirty, setDirty] = useState(false);
  const [createDialog, setCreateDialog] = useState<{
    sourceVersionId: string | null;
    effectiveDate: string;
    summary: string;
  } | null>(null);
  const [publishDialog, setPublishDialog] = useState<{ reason: string } | null>(null);
  const [appealDialog, setAppealDialog] = useState<{
    appeal: AdminReliabilityAppealQueueItem;
    decision: AppealReviewDecision;
    note: string;
  } | null>(null);
  const [previewDate, setPreviewDate] = useState(todayInBahrain());
  const [expandedHistory, setExpandedHistory] = useState<string | null>(null);

  const load = useCallback(async (quiet = false) => {
    if (!quiet) setLoading(true);
    setLocalError(null);
    try {
      const next = await fetchReliabilityPayload(accessToken);
      setPayload(next);
      const selected = next.drafts.find((draft) => draft.id === activeDraftId) ?? next.drafts[0] ?? null;
      if (selected) selectDraft(selected, setActiveDraftId, setEditor, setEffectiveDate, setSummary, setDirty);
      else {
        setActiveDraftId(null);
        setEditor(null);
        setDirty(false);
      }
    } catch (error) {
      const message = errorMessage(error, "Could not load reliability policy.");
      setLocalError(message);
      onError(message);
    } finally {
      setLoading(false);
    }
  }, [accessToken, activeDraftId, onError]);

  useEffect(() => {
    void load();
    // The selected draft is deliberately restored inside load without making it
    // a network dependency that would refetch after every selection.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [accessToken, refreshKey]);

  const activeDraft = payload?.drafts.find((draft) => draft.id === activeDraftId) ?? null;
  const baseline = useMemo(() => {
    if (!payload || !activeDraft) return payload?.inForce ?? null;
    return payload.history.find((version) => version.id === activeDraft.supersedesId) ?? payload.inForce;
  }, [activeDraft, payload]);
  const validation = useMemo(
    () => editor ? validateReliabilityPolicyConfig(editor) : [],
    [editor],
  );
  const changes = useMemo(
    () => editor && baseline ? diffReliabilityPolicyConfigs(baseline.config, editor) : [],
    [baseline, editor],
  );
  const timeline = useMemo(() =>
    reliabilityTimelineForKickoff(editor ?? payload?.inForce?.config ?? reliabilityPolicyDefaults, "2026-01-15T20:00:00+03:00"),
  [editor, payload?.inForce?.config]);
  const previewPolicy = useMemo(
    () => payload ? resolveReliabilityPolicyAt(payload.history, `${previewDate}T00:00:00+03:00`) : null,
    [payload, previewDate],
  );
  const createSource = createDialog?.sourceVersionId
    ? payload?.history.find((version) => version.id === createDialog.sourceVersionId) ?? null
    : null;
  const createReplacesScheduled = Boolean(
    createDialog && createSource && isFutureVersion(createSource) &&
    createDialog.effectiveDate === bahrainDateInput(createSource.effectiveFrom),
  );
  const publishReplacesScheduled = Boolean(
    activeDraft && baseline && isFutureVersion(baseline) &&
    activeDraft.supersedesId === baseline.id &&
    effectiveDate === bahrainDateInput(baseline.effectiveFrom),
  );

  function changeValue(path: string, value: unknown) {
    if (!editor) return;
    let next = setAtPath(editor, path, value);
    // These are one policy decision represented in both the cancellation and
    // replacement snapshots for backwards-compatible server consumers. Keep
    // them atomic and expose only the single cancellation control to admins.
    if (path === "solo.cancellations.late.discountBps") {
      next = setAtPath(next, "replacement.lateCancellationDiscountBps", value);
    } else if (path === "solo.cancellations.late.notify") {
      next = setAtPath(
        next,
        "replacement.notifyEligiblePlayersOnLateCancellation",
        value,
      );
    }
    setEditor(next);
    setDirty(true);
  }

  function changeSanctions(
    owner: "solo" | "clan",
    sanctions: ReliabilityPolicyConfig["solo"]["sanctions"] | ReliabilityPolicyConfig["clan"]["sanctions"],
  ) {
    if (!editor) return;
    const next = cloneReliabilityPolicyConfig(editor);
    if (owner === "solo") next.solo.sanctions = sanctions as ReliabilityPolicyConfig["solo"]["sanctions"];
    else next.clan.sanctions = sanctions as ReliabilityPolicyConfig["clan"]["sanctions"];
    setEditor(next);
    setDirty(true);
  }

  async function createDraft() {
    if (!createDialog) return;
    setSaving(true);
    setLocalError(null);
    try {
      await fetchJson("/api/referee/admin/reliability-policy", accessToken, {
        method: "POST",
        body: JSON.stringify({
          sourceVersionId: createDialog.sourceVersionId,
          effectiveFrom: bahrainDateToIso(createDialog.effectiveDate),
          summary: createDialog.summary,
        }),
      });
      setCreateDialog(null);
      await load(true);
      onNotice("Reliability policy draft created. Nothing changes until it is published.");
    } catch (error) {
      const message = errorMessage(error, "Could not create the policy draft.");
      setLocalError(message);
      onError(message);
    } finally {
      setSaving(false);
    }
  }

  async function saveDraft() {
    if (!activeDraft || !editor) return;
    if (validation.length > 0) {
      setLocalError("Fix the highlighted policy settings before saving.");
      return;
    }
    setSaving(true);
    setLocalError(null);
    try {
      await fetchJson(`/api/referee/admin/reliability-policy/${activeDraft.id}`, accessToken, {
        method: "PATCH",
        body: JSON.stringify({
          config: editor,
          effectiveFrom: bahrainDateToIso(effectiveDate),
          summary,
          expectedUpdatedAt: activeDraft.updatedAt,
        }),
      });
      await load(true);
      setDirty(false);
      onNotice("Reliability draft saved. The live policy is unchanged.");
    } catch (error) {
      const message = errorMessage(error, "Could not save the policy draft.");
      setLocalError(message);
      onError(message);
    } finally {
      setSaving(false);
    }
  }

  async function publishDraft() {
    if (!activeDraft || !publishDialog || dirty || validation.length > 0) return;
    setSaving(true);
    setLocalError(null);
    try {
      await fetchJson(
        `/api/referee/admin/reliability-policy/${activeDraft.id}/publish`,
        accessToken,
        { method: "POST", body: JSON.stringify({ reason: publishDialog.reason }) },
      );
      setPublishDialog(null);
      await load(true);
      onNotice(`Policy scheduled from ${formatBahrainDate(activeDraft.effectiveFrom)}. Published versions are immutable.`);
    } catch (error) {
      const message = errorMessage(error, "Could not publish the policy.");
      setLocalError(message);
      onError(message);
    } finally {
      setSaving(false);
    }
  }

  async function reviewAppeal() {
    if (!appealDialog || appealDialog.note.trim().length < 10) return;
    setSaving(true);
    setLocalError(null);
    try {
      const response = await fetchJson(
        `/api/referee/admin/reliability-appeals/${appealDialog.appeal.id}/review`,
        accessToken,
        {
          method: "POST",
          body: JSON.stringify({
            decision: appealDialog.decision,
            note: appealDialog.note,
          }),
        },
      ) as { policies?: ReliabilityPayload; warning?: string };
      if (response.policies) setPayload(response.policies);
      else await load(true);
      const decision = appealDialog.decision;
      setAppealDialog(null);
      onNotice(decision === "OVERTURN"
        ? "Appeal approved. The strike and its sanctions were reversed, and wallet corrections were applied."
        : "Appeal reviewed. The original attendance decision remains in place.");
      if (response.warning) onError(response.warning);
    } catch (error) {
      const message = errorMessage(error, "Could not review the reliability appeal.");
      setLocalError(message);
      onError(message);
    } finally {
      setSaving(false);
    }
  }

  if (loading && !payload) return <ReliabilitySkeleton />;
  if (!payload) {
    return (
      <section className={`admin-card ${styles.unavailable}`}>
        <strong>Reliability policy is unavailable</strong>
        <p>{localError ?? "Refresh the admin panel to try again."}</p>
        <button className="admin-primary-button" onClick={() => void load()} type="button">Try again</button>
      </section>
    );
  }

  return (
    <div className={styles.sectionStack}>
      <ReliabilityHero
        inForce={payload.inForce}
        scheduled={payload.scheduled}
        drafts={payload.drafts}
        onCreate={() => setCreateDialog(newDraftDialog(payload.inForce?.id ?? null))}
      />

      <div className={styles.tabs} role="tablist" aria-label="Reliability workspace">
        {([
          ["policy", "Policy editor"],
          ["operations", "Attendance & appeals"],
          ["history", "Policy history"],
        ] as Array<[ReliabilityTab, string]>).map(([id, label]) => (
          <button
            aria-selected={tab === id}
            className={tab === id ? styles.activeTab : ""}
            key={id}
            onClick={() => setTab(id)}
            role="tab"
            type="button"
          >
            {label}
            {id === "operations" && queueCount(payload) > 0 ? <em>{queueCount(payload)}</em> : null}
          </button>
        ))}
      </div>

      {localError ? (
        <div className={styles.localError} role="alert">
          <span>!</span><p>{localError}</p><button onClick={() => setLocalError(null)} type="button">Dismiss</button>
        </div>
      ) : null}

      {tab === "policy" ? (
        activeDraft && editor ? (
          <div className={styles.editorLayout}>
            <div className={styles.editorMain}>
              <section className={`admin-card ${styles.draftHeader}`}>
                <div>
                  <span className={styles.eyebrow}>Safe draft · version {activeDraft.version || "new"}</span>
                  <h2>Schedule this rule set</h2>
                  <p>Published rules are never edited. This draft applies to unpaid, unbooked matches kicking off on or after its Bahrain effective date. A match locks its full policy when the first player or clan pays.</p>
                </div>
                {payload.drafts.length > 1 ? (
                  <label className={styles.draftPicker}>
                    <span>Open draft</span>
                    <select
                      value={activeDraft.id}
                      onChange={(event) => {
                        const selected = payload.drafts.find((draft) => draft.id === event.target.value);
                        if (selected) selectDraft(selected, setActiveDraftId, setEditor, setEffectiveDate, setSummary, setDirty);
                      }}
                    >
                      {payload.drafts.map((draft) => (
                        <option key={draft.id} value={draft.id}>{draft.summary || `Draft ${draft.id.slice(0, 8)}`}</option>
                      ))}
                    </select>
                  </label>
                ) : null}
                <div className={styles.scheduleFields}>
                  <label>
                    <span>Starts on · Bahrain</span>
                    <input
                      min={tomorrowInBahrain()}
                      onChange={(event) => { setEffectiveDate(event.target.value); setDirty(true); }}
                      type="date"
                      value={effectiveDate}
                    />
                  </label>
                  <label>
                    <span>Plain-language change summary</span>
                    <input
                      maxLength={500}
                      onChange={(event) => { setSummary(event.target.value); setDirty(true); }}
                      placeholder="Example: Move the no-show cutoff to 12 minutes"
                      value={summary}
                    />
                  </label>
                </div>
              </section>

              {FIELD_SECTIONS.map((section, index) => (
                <PolicyFields
                  config={editor}
                  issues={validation}
                  key={section.id}
                  onChange={changeValue}
                  open={index < 2}
                  section={section}
                />
              ))}

              <ReservePlanCard
                order={editor.replacement.order}
                onChange={(order) => changeValue("replacement.order", order)}
              />

              <SanctionsCard
                owner="solo"
                sanctions={editor.solo.sanctions}
                onChange={(sanctions) => changeSanctions("solo", sanctions)}
              />
              <LockedReliabilityRulesCard config={editor} />
              <SanctionsCard
                owner="clan"
                sanctions={editor.clan.sanctions}
                onChange={(sanctions) => changeSanctions("clan", sanctions)}
              />
              <AppealsCard config={editor} onChange={(next) => { setEditor(next); setDirty(true); }} />
            </div>

            <aside className={styles.publishRail}>
              <section className={`admin-card ${styles.timelineCard}`}>
                <span className={styles.eyebrow}>Worked example</span>
                <h3>8:00 PM kickoff</h3>
                <div className={styles.timeline}>
                  <TimelinePoint label="Arrival reminder" time={formatBahrainTime(timeline.checkInOpensAt)} tone="neutral" />
                  <TimelinePoint label="Check in by" time={formatBahrainTime(timeline.checkInDeadline)} tone="warning" />
                  <TimelinePoint label="Kickoff" time={formatBahrainTime(timeline.kickoff)} tone="neutral" />
                  <TimelinePoint label="No-show at" time={formatBahrainTime(timeline.noShowCutoff)} tone="danger" />
                </div>
                <small>Referees may check players in earlier. All classifications use backend time, never the player's device clock.</small>
              </section>

              <section className={`admin-card ${styles.changeCard}`}>
                <div className={styles.changeHeading}>
                  <div>
                    <span className={styles.eyebrow}>Publication check</span>
                    <h3>{changes.length} setting{changes.length === 1 ? "" : "s"} changed</h3>
                  </div>
                  <span className={validation.length > 0 ? styles.invalidBadge : styles.validBadge}>
                    {validation.length > 0 ? `${validation.length} issue${validation.length === 1 ? "" : "s"}` : "Valid"}
                  </span>
                </div>
                {validation.length > 0 ? (
                  <ul className={styles.issueList}>
                    {validation.slice(0, 5).map((issue) => <li key={`${issue.path}-${issue.message}`}>{issue.message}</li>)}
                  </ul>
                ) : changes.length > 0 ? (
                  <div className={styles.diffPreview}>
                    {changes.slice(0, 5).map((change) => (
                      <div key={change.path}>
                        <strong>{change.label}</strong>
                        <span><del>{change.before}</del> → <ins>{change.after}</ins></span>
                      </div>
                    ))}
                    {changes.length > 5 ? <small>+ {changes.length - 5} more changes</small> : null}
                  </div>
                ) : <p className={styles.mutedCopy}>This draft currently matches the policy it supersedes.</p>}

                <div className={styles.railActions}>
                  <button
                    className="admin-secondary-button"
                    disabled={saving || validation.length > 0 || !dirty}
                    onClick={() => void saveDraft()}
                    type="button"
                  >
                    {saving ? "Saving…" : dirty ? "Save draft" : "Draft saved"}
                  </button>
                  <button
                    className="admin-primary-button"
                    disabled={saving || dirty || validation.length > 0 || summary.trim().length < 5}
                    onClick={() => setPublishDialog({ reason: summary })}
                    type="button"
                  >
                    Review & publish
                  </button>
                </div>
                {dirty ? <p className={styles.unsaved}>Save this draft before publishing.</p> : null}
              </section>
            </aside>
          </div>
        ) : (
          <EmptyDraft
            inForce={payload.inForce}
            onCreate={() => setCreateDialog(newDraftDialog(payload.inForce?.id ?? null))}
          />
        )
      ) : tab === "operations" ? (
        <OperationsReadiness
          onReviewAppeal={(appeal, decision) => setAppealDialog({ appeal, decision, note: "" })}
          payload={payload}
        />
      ) : (
        <HistorySection
          expandedId={expandedHistory}
          history={payload.history}
          onClone={(version) => setCreateDialog(isCurrentEffectiveLeaf(version, payload.history)
            ? newDraftDialog(
                version.id,
                `Replace scheduled policy v${version.version}`,
                bahrainDateInput(version.effectiveFrom),
              )
            : newDraftDialog(version.id, `Update policy v${version.version}`))}
          onExpand={(id) => setExpandedHistory((current) => current === id ? null : id)}
          onPreviewDate={setPreviewDate}
          previewDate={previewDate}
          previewPolicy={previewPolicy}
        />
      )}

      {createDialog ? (
        <PolicyModal onClose={() => !saving && setCreateDialog(null)}>
          <span className={styles.eyebrow}>{createReplacesScheduled ? "Scheduled policy correction" : "New effective-dated version"}</span>
          <h2>{createReplacesScheduled ? `Replace scheduled version ${createSource?.version}` : "Create policy draft"}</h2>
          <p className={styles.modalLead}>{createReplacesScheduled
            ? "Create an append-only replacement at the same start date. The prior scheduled version stays in history, but the newer version will win for that date."
            : "Start from an existing published version, make changes safely, then publish it for a future date."}</p>
          <label className={styles.modalField}>
            <span>Starts on · Bahrain</span>
            <input
              min={tomorrowInBahrain()}
              onChange={(event) => setCreateDialog({ ...createDialog, effectiveDate: event.target.value })}
              type="date"
              value={createDialog.effectiveDate}
            />
          </label>
          <label className={styles.modalField}>
            <span>Change summary</span>
            <textarea
              maxLength={500}
              onChange={(event) => setCreateDialog({ ...createDialog, summary: event.target.value })}
              placeholder="What should another admin understand about this version?"
              value={createDialog.summary}
            />
          </label>
          <div className={styles.modalNotice}>{createReplacesScheduled
            ? "This correction affects only unpaid, unbooked inventory from that date. Matches with an accepted booking or clan payment keep their disclosed policy."
            : "Creating a draft does not change player charges, strikes, refunds, or match rules."}</div>
          <div className={styles.modalActions}>
            <button className="admin-secondary-button" disabled={saving} onClick={() => setCreateDialog(null)} type="button">Cancel</button>
            <button
              className="admin-primary-button"
              disabled={saving || createDialog.summary.trim().length < 5 || !createDialog.effectiveDate}
              onClick={() => void createDraft()}
              type="button"
            >
              {saving ? "Creating…" : "Create safe draft"}
            </button>
          </div>
        </PolicyModal>
      ) : null}

      {publishDialog && activeDraft ? (
        <PolicyModal onClose={() => !saving && setPublishDialog(null)} wide>
          <span className={styles.eyebrow}>{publishReplacesScheduled ? "Append-only scheduled correction" : "Permanent policy history"}</span>
          <h2>{publishReplacesScheduled ? `Replace scheduled version ${baseline?.version}?` : "Publish this reliability policy?"}</h2>
          <p className={styles.modalLead}>
            It will govern unpaid, unbooked matches kicking off from <strong>{formatBahrainDate(bahrainDateToIso(effectiveDate))}</strong>. Earlier matches and matches with an accepted payment keep the policy shown at checkout.
          </p>
          <div className={styles.publishSummary}>
            <div><span>Changed settings</span><strong>{changes.length}</strong></div>
            <div><span>Effective date</span><strong>{formatBahrainDate(bahrainDateToIso(effectiveDate))}</strong></div>
            <div><span>Storage</span><strong>Immutable</strong></div>
          </div>
          <label className={styles.modalField}>
            <span>Reason for the audit trail</span>
            <textarea
              maxLength={1000}
              onChange={(event) => setPublishDialog({ reason: event.target.value })}
              value={publishDialog.reason}
            />
          </label>
          <div className={styles.modalWarning}>{publishReplacesScheduled
            ? `Version ${baseline?.version} remains immutable in history. This newer version becomes the policy selected at the same effective date.`
            : "After publication, this version cannot be edited or deleted. Any correction requires a new effective-dated version."}</div>
          <div className={styles.modalActions}>
            <button className="admin-secondary-button" disabled={saving} onClick={() => setPublishDialog(null)} type="button">Keep as draft</button>
            <button
              className="admin-primary-button"
              disabled={saving || publishDialog.reason.trim().length < 10}
              onClick={() => void publishDraft()}
              type="button"
            >
              {saving ? "Publishing…" : "Publish policy"}
            </button>
          </div>
        </PolicyModal>
      ) : null}

      {appealDialog ? (
        <PolicyModal onClose={() => !saving && setAppealDialog(null)} wide>
          <span className={styles.eyebrow}>Audited appeal decision</span>
          <h2>{appealDialog.decision === "OVERTURN" ? "Approve this appeal?" : "Uphold the original decision?"}</h2>
          <p className={styles.modalLead}>
            <strong>{appealDialog.appeal.playerName}</strong> appealed a {humanize(appealDialog.appeal.outcome)} decision for a {appealDialog.appeal.matchKind.toLowerCase()} match.
          </p>
          <div className={styles.appealFacts}>
            <div><span>Category</span><strong>{humanize(appealDialog.appeal.category)}</strong></div>
            <div><span>Current consequence</span><strong>{appealDialog.appeal.strikeDelta} strike{appealDialog.appeal.strikeDelta === 1 ? "" : "s"}</strong></div>
            <div><span>Current refund</span><strong>{appealDialog.appeal.refundBps / 100}%</strong></div>
          </div>
          <blockquote className={styles.appealMessage}>{appealDialog.appeal.message}</blockquote>
          <div className={appealDialog.decision === "OVERTURN" ? styles.modalNotice : styles.modalWarning}>
            {appealDialog.decision === "OVERTURN"
              ? "This appends a strike reversal, revokes only sanctions caused by this incident, corrects attendance to excused, and returns any eligible refund or forfeited deposit to Field Wallet. Nothing is deleted."
              : "The attendance outcome, strike, refund, and related sanctions will remain unchanged. The player will receive your review result."}
          </div>
          <label className={styles.modalField}>
            <span>Required review note · visible in the audit trail</span>
            <textarea
              autoFocus
              maxLength={2000}
              onChange={(event) => setAppealDialog({ ...appealDialog, note: event.target.value })}
              placeholder="Explain the evidence and why this decision is correct…"
              value={appealDialog.note}
            />
          </label>
          <div className={styles.modalActions}>
            <button className="admin-secondary-button" disabled={saving} onClick={() => setAppealDialog(null)} type="button">Cancel</button>
            <button
              className={appealDialog.decision === "OVERTURN" ? "admin-primary-button" : styles.upholdButton}
              disabled={saving || appealDialog.note.trim().length < 10}
              onClick={() => void reviewAppeal()}
              type="button"
            >
              {saving
                ? "Recording decision…"
                : appealDialog.decision === "OVERTURN"
                  ? "Approve & correct"
                  : "Uphold decision"}
            </button>
          </div>
        </PolicyModal>
      ) : null}
    </div>
  );
}

function ReliabilityHero({
  inForce,
  scheduled,
  drafts,
  onCreate,
}: {
  inForce: ReliabilityPolicyVersion | null;
  scheduled: ReliabilityPolicyVersion[];
  drafts: ReliabilityPolicyVersion[];
  onCreate: () => void;
}) {
  return (
    <section className={styles.hero}>
      <div className={styles.heroStatus}><i /> Policy engine online</div>
      <div className={styles.heroGrid}>
        <div>
          <span>Policy in force</span>
          <strong>{inForce ? `Version ${inForce.version}` : "No published policy"}</strong>
          <p>{inForce ? `${inForce.summary} · since ${formatBahrainDate(inForce.effectiveFrom)}` : "Create and publish the first reliability policy."}</p>
        </div>
        <div>
          <span>Next scheduled</span>
          <strong>{scheduled[0] ? formatBahrainDate(scheduled[0].effectiveFrom) : "Nothing scheduled"}</strong>
          <p>{scheduled[0]?.summary ?? "The current rules continue until a new version starts."}</p>
        </div>
        <div>
          <span>Safe drafts</span>
          <strong>{drafts.length}</strong>
          <p>Drafts never affect live bookings.</p>
        </div>
      </div>
      <button onClick={onCreate} type="button">+ New policy update</button>
    </section>
  );
}

function PolicyFields({
  section,
  config,
  issues,
  open,
  onChange,
}: {
  section: FieldSection;
  config: ReliabilityPolicyConfig;
  issues: ReturnType<typeof validateReliabilityPolicyConfig>;
  open: boolean;
  onChange: (path: string, value: unknown) => void;
}) {
  const [expanded, setExpanded] = useState(open);
  const sectionIssues = issues.filter((issue) =>
    section.fields.some((field) =>
      issue.path === field.path || issue.path.startsWith(`${field.path}.`)),
  );
  return (
    <details
      className={`admin-card ${styles.policyGroup}`}
      onToggle={(event) => setExpanded(event.currentTarget.open)}
      open={expanded}
    >
      <summary>
        <div><span>{section.title}</span><small>{section.detail}</small></div>
        <b>{section.fields.length} controls</b>
        <i>⌄</i>
      </summary>
      <div className={styles.fieldGrid}>
        {section.fields.map((field) => {
          const issue = issues.find((candidate) => candidate.path === field.path);
          const value = getAtPath(config, field.path);
          if (field.kind === "toggle") {
            return (
              <label className={`${styles.toggleField} ${issue ? styles.fieldInvalid : ""}`} key={field.path}>
                <span><strong>{field.label}</strong>{field.hint ? <small>{field.hint}</small> : null}</span>
                <input
                  checked={value === true}
                  onChange={(event) => onChange(field.path, event.target.checked)}
                  type="checkbox"
                />
                <i />
              </label>
            );
          }
          const displayValue = field.kind === "bps" ? bpsToPercent(Number(value)) : Number(value);
          return (
            <label className={`${styles.numberField} ${issue ? styles.fieldInvalid : ""}`} key={field.path}>
              <span>{field.label}</span>
              <div>
                <input
                  max={field.maximum}
                  min={field.minimum ?? 0}
                  onChange={(event) => {
                    const number = event.target.valueAsNumber;
                    if (Number.isFinite(number)) {
                      onChange(field.path, field.kind === "bps" ? percentToBps(number) : number);
                    }
                  }}
                  step={field.kind === "bps" ? 0.01 : 1}
                  type="number"
                  value={displayValue}
                />
                <em>{field.unit}</em>
              </div>
              {field.hint ? <small>{field.hint}</small> : null}
              {issue ? <small className={styles.fieldError}>{issue.message}</small> : null}
            </label>
          );
        })}
      </div>
      {sectionIssues.length > 0 ? <span className={styles.visuallyHidden}>{sectionIssues.length} invalid settings</span> : null}
    </details>
  );
}

function SanctionsCard({ owner, sanctions, onChange }: {
  owner: "solo" | "clan";
  sanctions: ReliabilityPolicyConfig["solo"]["sanctions"] | ReliabilityPolicyConfig["clan"]["sanctions"];
  onChange: (value: typeof sanctions) => void;
}) {
  const includesRelease = owner === "solo";
  return (
    <details className={`admin-card ${styles.policyGroup}`}>
      <summary>
        <div><span>{owner === "solo" ? "Player consequence ladder" : "Clan consequence ladder"}</span><small>Sanctions trigger once when a threshold is crossed. Keep thresholds in ascending order.</small></div>
        <b>{sanctions.length} steps</b><i>⌄</i>
      </summary>
      <div className={styles.sanctionTable}>
        <div className={styles.sanctionHead}><span>Strikes</span><span>Consequence</span><span>Days</span>{includesRelease ? <span>Release bookings</span> : null}<span /></div>
        {sanctions.map((sanction, index) => (
          <div className={styles.sanctionRow} key={`${sanction.kind}-${index}`}>
            <input
              aria-label={`Threshold for consequence ${index + 1}`}
              min={1}
              onChange={(event) => onChange(replaceArrayItem(sanctions, index, { ...sanction, threshold: event.target.valueAsNumber }))}
              type="number"
              value={sanction.threshold}
            />
            <select
              aria-label={`Consequence ${index + 1}`}
              onChange={(event) => {
                const kind = event.target.value as ReliabilitySanctionKind;
                onChange(replaceArrayItem(sanctions, index, {
                  ...sanction,
                  kind,
                  durationDays: kind === "INDEFINITE_SUSPENSION"
                    ? null
                    : kind === "WARNING"
                      ? 0
                      : sanction.durationDays === null || sanction.durationDays < 1
                        ? 7
                        : sanction.durationDays,
                }));
              }}
              value={sanction.kind}
            >
              <option value="WARNING">Private warning</option>
              <option value="BOOKING_RESTRICTION">Booking restriction</option>
              <option value="PARTICIPATION_SUSPENSION">Participation suspension</option>
              <option value="INDEFINITE_SUSPENSION">Indefinite review</option>
            </select>
            <input
              aria-label={`Duration for consequence ${index + 1}`}
              disabled={sanction.kind === "WARNING" || sanction.kind === "INDEFINITE_SUSPENSION"}
              min={1}
              onChange={(event) => onChange(replaceArrayItem(sanctions, index, { ...sanction, durationDays: event.target.valueAsNumber }))}
              title={sanction.kind === "WARNING"
                ? "Warnings stay in private history and do not expire."
                : sanction.kind === "INDEFINITE_SUSPENSION"
                  ? "Indefinite review has no end date."
                  : undefined}
              type="number"
              value={sanction.kind === "WARNING" || sanction.kind === "INDEFINITE_SUSPENSION"
                ? ""
                : sanction.durationDays ?? ""}
            />
            {includesRelease ? (
              <label className={styles.compactCheck}>
                <input
                  checked={(sanction as ReliabilityPolicyConfig["solo"]["sanctions"][number]).releaseFutureBookings}
                  onChange={(event) => {
                    const next = sanctions.map((current, row) => row === index
                      ? {
                          ...current,
                          releaseFutureBookings: event.target.checked,
                        } as ReliabilityPolicyConfig["solo"]["sanctions"][number]
                      : current) as typeof sanctions;
                    onChange(next);
                  }}
                  type="checkbox"
                />
                <span>{(sanction as ReliabilityPolicyConfig["solo"]["sanctions"][number]).releaseFutureBookings ? "Yes" : "No"}</span>
              </label>
            ) : null}
            <button
              aria-label={`Remove consequence ${index + 1}`}
              disabled={sanctions.length === 1}
              onClick={() => onChange(sanctions.filter((_, row) => row !== index) as typeof sanctions)}
              type="button"
            >×</button>
          </div>
        ))}
        <button
          className={styles.addRule}
          onClick={() => {
            const threshold = (sanctions.at(-1)?.threshold ?? 0) + 1;
            const next = includesRelease
              ? { threshold, kind: "BOOKING_RESTRICTION" as const, durationDays: 7, releaseFutureBookings: false }
              : { threshold, kind: "BOOKING_RESTRICTION" as const, durationDays: 14 };
            onChange([...sanctions, next] as typeof sanctions);
          }}
          type="button"
        >+ Add consequence step</button>
      </div>
    </details>
  );
}

function ReservePlanCard({ order, onChange }: {
  order: ReliabilityPolicyConfig["replacement"]["order"];
  onChange: (order: ReliabilityPolicyConfig["replacement"]["order"]) => void;
}) {
  return (
    <details className={`admin-card ${styles.policyGroup}`}>
      <summary>
        <div>
          <span>Host-run reserve plan</span>
          <small>Field shows this operational sequence to the referee. It does not automatically assign or activate an on-field reserve.</small>
        </div>
        <b>Manual operation</b><i>⌄</i>
      </summary>
      <div className={styles.orderList}>
        {order.map((step, index) => (
          <div key={step}>
            <span>{index + 1}</span>
            <div>
              <strong>{humanize(step)}</strong>
              <small>{reserveStepDescription(step)}</small>
            </div>
            <div>
              <button
                aria-label={`Move ${humanize(step)} earlier`}
                disabled={index === 0}
                onClick={() => onChange(moveItem(order, index, index - 1))}
                type="button"
              >↑</button>
              <button
                aria-label={`Move ${humanize(step)} later`}
                disabled={index === order.length - 1}
                onClick={() => onChange(moveItem(order, index, index + 1))}
                type="button"
              >↓</button>
            </div>
          </div>
        ))}
      </div>
    </details>
  );
}

function LockedReliabilityRulesCard({ config }: {
  config: ReliabilityPolicyConfig;
}) {
  return (
    <details className={`admin-card ${styles.policyGroup}`}>
      <summary><div><span>Locked product and safety rules</span><small>Shown honestly here, but not presented as live controls.</small></div><b>Not editable</b><i>⌄</i></summary>
      <div className={styles.choiceGroups}>
        <div className={styles.lockedRule}><span>Solo format</span><strong>{config.solo.playersPerSide} players per side</strong><small>The current game inventory and position capacities are built for 6-a-side.</small></div>
        <div className={styles.lockedRule}><span>Clan format</span><strong>{config.clan.playersPerSide} players per side</strong><small>Clan scheduling, roster confirmation, and formation views are built for 7-a-side.</small></div>
        <div className={styles.lockedRule}><span>Field cancellation</span><strong>Zero strikes</strong><small>A venue or Field cancellation never becomes a player reliability penalty.</small></div>
        <div className={styles.lockedRule}><span>Verified injury</span><strong>Assigned referee · zero strikes</strong><small>Evidence authority and no-strike treatment are safety invariants, not penalty knobs.</small></div>
      </div>
    </details>
  );
}

function AppealsCard({ config, onChange }: {
  config: ReliabilityPolicyConfig;
  onChange: (config: ReliabilityPolicyConfig) => void;
}) {
  function toggleCategory(category: (typeof RELIABILITY_APPEAL_CATEGORIES)[number]) {
    const next = cloneReliabilityPolicyConfig(config);
    next.appeals.allowedCategories = next.appeals.allowedCategories.includes(category)
      ? next.appeals.allowedCategories.filter((item) => item !== category)
      : [...next.appeals.allowedCategories, category];
    onChange(next);
  }
  function toggleForfeit(outcome: (typeof RELIABILITY_FORFEIT_OUTCOMES)[number]) {
    const next = cloneReliabilityPolicyConfig(config);
    next.solo.reliabilityDeposit.forfeitOutcomes = next.solo.reliabilityDeposit.forfeitOutcomes.includes(outcome)
      ? next.solo.reliabilityDeposit.forfeitOutcomes.filter((item) => item !== outcome)
      : [...next.solo.reliabilityDeposit.forfeitOutcomes, outcome];
    onChange(next);
  }
  function toggleClanForfeit(outcome: (typeof RELIABILITY_CLAN_DEPOSIT_FORFEIT_OUTCOMES)[number]) {
    const next = cloneReliabilityPolicyConfig(config);
    next.clan.reliabilityDeposit.forfeitOutcomes = next.clan.reliabilityDeposit.forfeitOutcomes.includes(outcome)
      ? next.clan.reliabilityDeposit.forfeitOutcomes.filter((item) => item !== outcome)
      : [...next.clan.reliabilityDeposit.forfeitOutcomes, outcome];
    onChange(next);
  }
  return (
    <details className={`admin-card ${styles.policyGroup}`}>
      <summary><div><span>Appeals, deposit forfeiture and wallet</span><small>Player-facing exceptions stay explicit and auditable.</small></div><b>Review rules</b><i>⌄</i></summary>
      <div className={styles.choiceGroups}>
        <fieldset><legend>Allowed appeal categories</legend><div>
          {RELIABILITY_APPEAL_CATEGORIES.map((category) => (
            <label key={category}><input checked={config.appeals.allowedCategories.includes(category)} onChange={() => toggleCategory(category)} type="checkbox" /><span>{humanize(category)}</span></label>
          ))}
        </div></fieldset>
        <fieldset><legend>Player deposit is forfeited for</legend><div>
          {RELIABILITY_FORFEIT_OUTCOMES.map((outcome) => (
            <label key={outcome}><input checked={config.solo.reliabilityDeposit.forfeitOutcomes.includes(outcome)} onChange={() => toggleForfeit(outcome)} type="checkbox" /><span>{humanize(outcome)}</span></label>
          ))}
        </div></fieldset>
        <fieldset><legend>Clan deposit is forfeited for</legend><div>
          {RELIABILITY_CLAN_DEPOSIT_FORFEIT_OUTCOMES.map((outcome) => (
            <label key={outcome}><input checked={config.clan.reliabilityDeposit.forfeitOutcomes.includes(outcome)} onChange={() => toggleClanForfeit(outcome)} type="checkbox" /><span>{humanize(outcome)}</span></label>
          ))}
        </div></fieldset>
        <div className={styles.lockedRule}><span>Routine traffic</span><strong>Not automatically excused</strong><small>An admin may still overturn a documented exceptional case. Automatic excusal is intentionally locked off.</small></div>
        <div className={styles.lockedRule}><span>Refund destination</span><strong>Field wallet · BHD</strong><small>Financial ledger destination is locked for consistency.</small></div>
      </div>
    </details>
  );
}

function OperationsReadiness({ payload, onReviewAppeal }: {
  payload: ReliabilityPayload;
  onReviewAppeal: (
    appeal: AdminReliabilityAppealQueueItem,
    decision: AppealReviewDecision,
  ) => void;
}) {
  const attendance = payload.attendanceQueue;
  const appeals = payload.appealsQueue;
  return (
    <div className={styles.operationsGrid}>
      <QueueCard
        eyebrow="Authoritative match facts"
        items={attendance}
        readiness={attendance === undefined ? "Attendance capture is ready to feed this view once match-day check-in records are enabled." : "No finalized late, cancellation, or no-show decisions yet."}
        title="Recent attendance decisions"
      />
      <AppealsQueueCard
        eyebrow={`${payload.inForce?.config.attendance.appealWindowHours ?? 48}-hour review window`}
        items={appeals}
        onReview={onReviewAppeal}
        readiness={appeals === undefined ? "Appeal categories and deadlines are configured. Submitted attendance appeals will appear here." : "No attendance appeals are waiting for a decision."}
        title="Appeals"
      />
      <section className={`admin-card ${styles.readinessCard}`}>
        <span className={styles.eyebrow}>Policy snapshot</span>
        <h3>Every decision remains explainable</h3>
        <div>
          <p><i className={styles.goodDot} /><span><strong>Effective-dated</strong>Old matches and matches with an accepted booking or clan payment keep their disclosed policy.</span></p>
          <p><i className={styles.goodDot} /><span><strong>Server timed</strong>Phone clock changes cannot alter outcomes.</span></p>
          <p><i className={styles.goodDot} /><span><strong>Wallet based</strong>Refunds and deposits resolve as Field credit.</span></p>
          <p><i className={styles.goodDot} /><span><strong>Appealable</strong>Facts and consequences remain privately reviewable.</span></p>
        </div>
      </section>
    </div>
  );
}

function AppealsQueueCard({ eyebrow, title, items, readiness, onReview }: {
  eyebrow: string;
  title: string;
  items: AdminReliabilityAppealQueueItem[] | undefined;
  readiness: string;
  onReview: (
    appeal: AdminReliabilityAppealQueueItem,
    decision: AppealReviewDecision,
  ) => void;
}) {
  return (
    <section className={`admin-card ${styles.queueCard}`}>
      <header><div><span className={styles.eyebrow}>{eyebrow}</span><h3>{title}</h3></div><b>{items?.length ?? 0}</b></header>
      {items && items.length > 0 ? (
        <div className={`${styles.queueList} ${styles.appealQueueList}`}>{items.slice(0, 8).map((item) => (
          <article key={item.id}>
            <div>
              <strong>{item.title}</strong>
              <p>{item.message}</p>
              <small>
                {humanize(item.matchKind)} · {humanize(item.outcome)} · {item.strikeDelta} strike{item.strikeDelta === 1 ? "" : "s"} · {item.refundBps / 100}% refund
              </small>
            </div>
            <div className={styles.appealActions}>
              <button onClick={() => onReview(item, "UPHOLD")} type="button">Uphold</button>
              <button onClick={() => onReview(item, "OVERTURN")} type="button">Overturn</button>
            </div>
          </article>
        ))}</div>
      ) : <div className={styles.queueEmpty}><span>✓</span><strong>Queue is clear</strong><p>{readiness}</p></div>}
    </section>
  );
}

function QueueCard({ eyebrow, title, items, readiness }: {
  eyebrow: string;
  title: string;
  items: QueueItem[] | undefined;
  readiness: string;
}) {
  return (
    <section className={`admin-card ${styles.queueCard}`}>
      <header><div><span className={styles.eyebrow}>{eyebrow}</span><h3>{title}</h3></div><b>{items?.length ?? 0}</b></header>
      {items && items.length > 0 ? (
        <div className={styles.queueList}>{items.slice(0, 8).map((item) => (
          <article key={item.id}><div><strong>{item.title}</strong><p>{item.detail}</p></div><span>{humanize(item.status)}</span></article>
        ))}</div>
      ) : <div className={styles.queueEmpty}><span>✓</span><strong>Queue is clear</strong><p>{readiness}</p></div>}
    </section>
  );
}

function HistorySection({ history, previewDate, previewPolicy, expandedId, onPreviewDate, onExpand, onClone }: {
  history: ReliabilityPolicyVersion[];
  previewDate: string;
  previewPolicy: ReliabilityPolicyVersion | null;
  expandedId: string | null;
  onPreviewDate: (value: string) => void;
  onExpand: (id: string) => void;
  onClone: (version: ReliabilityPolicyVersion) => void;
}) {
  return (
    <div className={styles.historyLayout}>
      <section className={`admin-card ${styles.previewCard}`}>
        <span className={styles.eyebrow}>Policy in force preview</span><h3>Resolve any match date</h3>
        <label><span>Match date · Bahrain</span><input onChange={(event) => onPreviewDate(event.target.value)} type="date" value={previewDate} /></label>
        <div className={previewPolicy ? styles.previewResult : styles.previewMissing}>
          <span>{previewPolicy ? `Version ${previewPolicy.version}` : "No policy"}</span>
          <strong>{previewPolicy?.summary ?? "No published version covers this date."}</strong>
          {previewPolicy ? <small>Effective {formatBahrainDate(previewPolicy.effectiveFrom)}</small> : null}
        </div>
        <p>Resolution uses match kickoff for uncommitted inventory. The first accepted player booking or clan payment freezes that match’s complete policy, so later changes never rewrite accepted charges, deadlines, refunds, deposits, or outcomes.</p>
      </section>
      <section className={styles.historyList}>
        {history.length === 0 ? <div className={`admin-card ${styles.historyEmpty}`}>No policy has been published yet.</div> : history.map((version, index) => {
          const previous = history[index + 1] ?? null;
          const diff = previous ? diffReliabilityPolicyConfigs(previous.config, version.config) : [];
          const expanded = expandedId === version.id;
          return (
            <article className={`admin-card ${styles.historyItem}`} key={version.id}>
              <button className={styles.historySummary} onClick={() => onExpand(version.id)} type="button">
                <span className={styles.versionMark}>v{version.version}</span>
                <span><b>{version.summary || "Reliability policy"}</b><small>Effective {formatBahrainDate(version.effectiveFrom)} · published by {version.publishedByName ?? "Field admin"}</small></span>
                <em>{diff.length > 0 ? `${diff.length} changes` : index === history.length - 1 ? "Initial version" : "No changes"}</em>
                <i>{expanded ? "−" : "+"}</i>
              </button>
              {expanded ? (
                <div className={styles.historyDetail}>
                  {diff.length > 0 ? <div className={styles.historyDiff}>{diff.map((change) => (
                    <div key={change.path}><span>{change.label}</span><del>{change.before}</del><b>→</b><ins>{change.after}</ins></div>
                  ))}</div> : <p>This is the first immutable policy snapshot.</p>}
                  <div className={styles.historyActions}><span>Published {formatDateTime(version.publishedAt)}</span><button className="admin-secondary-button" onClick={() => onClone(version)} type="button">{isCurrentEffectiveLeaf(version, history) ? "Replace scheduled version" : "Clone into new draft"}</button></div>
                </div>
              ) : null}
            </article>
          );
        })}
      </section>
    </div>
  );
}

function EmptyDraft({ inForce, onCreate }: { inForce: ReliabilityPolicyVersion | null; onCreate: () => void }) {
  return (
    <section className={`admin-card ${styles.emptyDraft}`}>
      <span>＋</span><h2>No policy draft is open</h2><p>{inForce ? `Version ${inForce.version} remains in force. Create a safe copy to schedule any change.` : "Create the initial version, review every rule, then publish it."}</p>
      <button className="admin-primary-button" onClick={onCreate} type="button">Create policy update</button>
    </section>
  );
}

function PolicyModal({ children, onClose, wide = false }: { children: React.ReactNode; onClose: () => void; wide?: boolean }) {
  useEffect(() => {
    function closeOnEscape(event: KeyboardEvent) { if (event.key === "Escape") onClose(); }
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [onClose]);
  return (
    <div className={styles.modalBackdrop} onMouseDown={onClose} role="presentation">
      <section aria-modal="true" className={`${styles.modal} ${wide ? styles.modalWide : ""}`} onMouseDown={(event) => event.stopPropagation()} role="dialog">
        <button aria-label="Close" className={styles.modalClose} onClick={onClose} type="button">×</button>{children}
      </section>
    </div>
  );
}

function TimelinePoint({ label, time, tone }: { label: string; time: string; tone: "warning" | "neutral" | "danger" }) {
  return <div className={styles[tone]}><i /><span>{label}</span><strong>{time}</strong></div>;
}

function ReliabilitySkeleton() {
  return <div className={styles.skeleton}><span /><div><span /><span /><span /></div><section><span /><span /></section></div>;
}

function numberField(path: string, label: string, unit: string, minimum: number, maximum: number): FieldSpec {
  return { path, label, kind: "number", unit, minimum, maximum };
}
function bpsField(path: string, label: string, unit: string, maximum: number): FieldSpec {
  return { path, label, kind: "bps", unit, minimum: 0, maximum };
}
function toggleField(path: string, label: string, hint?: string): FieldSpec {
  return { path, label, hint, kind: "toggle" };
}

function newDraftDialog(sourceVersionId: string | null, summary = "", effectiveDate = tomorrowInBahrain()) {
  return { sourceVersionId, effectiveDate, summary };
}

function selectDraft(
  draft: ReliabilityPolicyVersion,
  setId: (value: string) => void,
  setEditor: (value: ReliabilityPolicyConfig) => void,
  setDate: (value: string) => void,
  setSummary: (value: string) => void,
  setDirty: (value: boolean) => void,
) {
  setId(draft.id);
  setEditor(cloneReliabilityPolicyConfig(draft.config));
  setDate(bahrainDateInput(draft.effectiveFrom));
  setSummary(draft.summary);
  setDirty(false);
}

function setAtPath(config: ReliabilityPolicyConfig, path: string, value: unknown) {
  const next = cloneReliabilityPolicyConfig(config) as unknown as JsonRecord;
  const keys = path.split(".");
  let current = next;
  keys.slice(0, -1).forEach((key) => { current = current[key] as JsonRecord; });
  current[keys.at(-1)!] = value;
  return next as unknown as ReliabilityPolicyConfig;
}

function getAtPath(config: ReliabilityPolicyConfig, path: string): unknown {
  return path.split(".").reduce<unknown>((current, key) =>
    current && typeof current === "object" ? (current as JsonRecord)[key] : undefined, config);
}

function replaceArrayItem<T>(items: T[], index: number, item: T) {
  return items.map((current, row) => row === index ? item : current);
}

function moveItem<T>(items: T[], from: number, to: number) {
  const next = [...items];
  const [item] = next.splice(from, 1);
  next.splice(to, 0, item);
  return next;
}

async function fetchReliabilityPayload(accessToken: string) {
  return fetchJson<ReliabilityPayload>("/api/referee/admin/reliability-policy", accessToken);
}

async function fetchJson<T = unknown>(path: string, token: string, init: RequestInit = {}) {
  const response = await fetch(path, {
    ...init,
    cache: "no-store",
    headers: { "Content-Type": "application/json", authorization: `Bearer ${token}`, ...init.headers },
  });
  const payload = (await response.json().catch(() => ({}))) as T & { error?: string };
  if (!response.ok) throw new Error(payload.error ?? `Request failed (${response.status}).`);
  return payload;
}

function queueCount(payload: ReliabilityPayload) {
  return (payload.attendanceQueue?.length ?? 0) + (payload.appealsQueue?.length ?? 0);
}

function todayInBahrain() {
  return bahrainDateInput(new Date().toISOString());
}

function tomorrowInBahrain() {
  const now = new Date();
  now.setUTCDate(now.getUTCDate() + 1);
  return bahrainDateInput(now.toISOString());
}

function bahrainDateInput(value: string) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "Asia/Bahrain",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date(value));
  const part = (type: Intl.DateTimeFormatPartTypes) => parts.find((item) => item.type === type)?.value ?? "";
  return `${part("year")}-${part("month")}-${part("day")}`;
}

function bahrainDateToIso(value: string) {
  const parsed = Date.parse(`${value}T00:00:00+03:00`);
  return Number.isFinite(parsed) ? new Date(parsed).toISOString() : "";
}

function formatBahrainDate(value: string) {
  return new Intl.DateTimeFormat("en-BH", {
    timeZone: "Asia/Bahrain",
    day: "numeric",
    month: "short",
    year: "numeric",
  }).format(new Date(value));
}

function formatBahrainTime(value: Date) {
  return new Intl.DateTimeFormat("en-BH", {
    timeZone: "Asia/Bahrain",
    hour: "numeric",
    minute: "2-digit",
  }).format(value);
}

function formatDateTime(value: string | null) {
  if (!value) return "—";
  return new Intl.DateTimeFormat("en-BH", {
    timeZone: "Asia/Bahrain",
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}

function isFutureVersion(version: ReliabilityPolicyVersion) {
  return Date.parse(version.effectiveFrom) > Date.now();
}

function isCurrentEffectiveLeaf(
  version: ReliabilityPolicyVersion,
  history: ReliabilityPolicyVersion[],
) {
  return isFutureVersion(version) && !history.some((candidate) =>
    candidate.effectiveFrom === version.effectiveFrom &&
    candidate.version > version.version);
}

function reserveStepDescription(step: ReliabilityPolicyConfig["replacement"]["order"][number]) {
  switch (step) {
    case "EMERGENCY_NOTIFICATION":
      return "Notify eligible players about the open place.";
    case "ON_FIELD_RESERVE":
      return "The host confirms a checked-in reserve after the configured cutoff.";
    case "PLAY_SHORTHANDED":
      return "Record the side as shorthanded when no eligible replacement is available.";
  }
}

function humanize(value: string) {
  return value.toLowerCase().replaceAll("_", " ").replace(/^./, (letter) => letter.toUpperCase());
}

function errorMessage(error: unknown, fallback: string) {
  return error instanceof Error && error.message ? error.message : fallback;
}

"use client";

import { useEffect, useMemo, useState } from "react";

import { SHORTHANDED_REASONS } from "@/lib/match-action-input";
import type {
  ReliabilityAttendancePlayer,
  ReliabilityShorthandedPeriod,
  RefereeFixture,
} from "@/lib/types";

type EvidenceActionBody = Record<
  string,
  string | boolean | null | undefined
>;

type DialogKind = "injury" | "start-short" | "end-short" | null;

const REASON_LABELS: Record<(typeof SHORTHANDED_REASONS)[number], string> = {
  LATE_ARRIVAL: "Late arrival",
  NO_SHOW: "No-show",
  INJURY: "Injury",
  OTHER: "Other",
};

export function RefereeReliabilityEvidencePanel({
  fixture,
  submitting,
  onAction,
  financialOnly = false,
}: {
  fixture: RefereeFixture;
  submitting: string | null;
  onAction: (body: EvidenceActionBody) => Promise<boolean>;
  financialOnly?: boolean;
}) {
  const context = fixture.reliabilityContext;
  const injuries = context?.verifiedInjuries ?? [];
  const activePeriods = context?.openShorthandedPeriods ?? [];
  const checkedInPlayers = useMemo(
    () => context?.players.filter((player) => player.isCheckedIn) ?? [],
    [context?.players],
  );
  const injuryProfileIds = useMemo(
    () => new Set(injuries.map((injury) => injury.profileId)),
    [injuries],
  );
  const injuryCandidates = checkedInPlayers.filter(
    (player) => !injuryProfileIds.has(player.profileId),
  );
  const availableSides = sidesFor(fixture).filter(
    (side) => !activePeriods.some((period) => period.side === side.value),
  );

  const [expanded, setExpanded] = useState(activePeriods.length > 0);
  const [dialog, setDialog] = useState<DialogKind>(null);
  const [profileId, setProfileId] = useState("");
  const [unableToContinue, setUnableToContinue] = useState(true);
  const [replacementAvailable, setReplacementAvailable] = useState(false);
  const [matchContinued, setMatchContinued] = useState(true);
  const [side, setSide] = useState("");
  const [reason, setReason] = useState("LATE_ARRIVAL");
  const [causedByProfileId, setCausedByProfileId] = useState("");
  const [periodId, setPeriodId] = useState("");
  const [replacementProfileId, setReplacementProfileId] = useState("");
  const [note, setNote] = useState("");
  const [localError, setLocalError] = useState<string | null>(null);

  useEffect(() => {
    setExpanded(activePeriods.length > 0);
    setDialog(null);
    setProfileId("");
    setSide("");
    setPeriodId("");
    setNote("");
    setLocalError(null);
  }, [fixture.id]);

  useEffect(() => {
    if (activePeriods.length > 0) setExpanded(true);
  }, [activePeriods.length]);

  useEffect(() => {
    if (!dialog) return;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape" && submitting === null) setDialog(null);
    };
    window.addEventListener("keydown", onKeyDown);
    return () => {
      document.body.style.overflow = previousOverflow;
      window.removeEventListener("keydown", onKeyDown);
    };
  }, [dialog, submitting]);

  if (!context) return null;

  function openInjury() {
    setProfileId(injuryCandidates[0]?.profileId ?? "");
    setUnableToContinue(true);
    setReplacementAvailable(false);
    setMatchContinued(true);
    setNote("");
    setLocalError(null);
    setDialog("injury");
  }

  function openStartShort() {
    const nextSide = availableSides[0]?.value ?? "";
    setSide(nextSide);
    setReason("LATE_ARRIVAL");
    setCausedByProfileId("");
    setNote("");
    setLocalError(null);
    setDialog("start-short");
  }

  function openEndShort(period: ReliabilityShorthandedPeriod) {
    setPeriodId(period.id);
    setReplacementProfileId("");
    setNote("");
    setLocalError(null);
    setDialog("end-short");
  }

  const canRecord = fixture.status === "LIVE";
  const selectedPeriod = activePeriods.find((period) => period.id === periodId) ?? null;
  const sidePlayers = context.players.filter(
    (player) => playerSide(fixture, player) === side,
  );
  const replacementPlayers = selectedPeriod
    ? checkedInPlayers.filter(
        (player) =>
          playerSide(fixture, player) === selectedPeriod.side &&
          player.profileId !== selectedPeriod.causedByProfileId,
      )
    : [];

  async function submitInjury(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setLocalError(null);
    if (!profileId) {
      setLocalError("Choose a checked-in player.");
      return;
    }
    const succeeded = await onAction({
      action: "record_verified_injury",
      profileId,
      unableToContinue,
      replacementAvailable: financialOnly ? false : replacementAvailable,
      matchContinued,
      note: note.trim() || null,
    });
    if (succeeded) setDialog(null);
  }

  async function submitStartShort(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setLocalError(null);
    if (!side) {
      setLocalError("Choose the team playing short.");
      return;
    }
    if (reason === "OTHER" && note.trim().length < 5) {
      setLocalError("Add a concise factual note for the other reason.");
      return;
    }
    const succeeded = await onAction({
      action: "start_shorthanded",
      side,
      reason,
      causedByProfileId: causedByProfileId || null,
      note: note.trim() || null,
    });
    if (succeeded) setDialog(null);
  }

  async function submitEndShort(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setLocalError(null);
    if (!periodId) {
      setLocalError("Choose the active period to end.");
      return;
    }
    const succeeded = await onAction({
      action: "end_shorthanded",
      periodId,
      replacementProfileId: replacementProfileId || null,
      note: note.trim() || null,
    });
    if (succeeded) setDialog(null);
  }

  return (
    <>
      <section className={`reliability-evidence ${expanded ? "expanded" : ""}`}>
        <button
          aria-expanded={expanded}
          className="reliability-evidence-summary"
          onClick={() => setExpanded((current) => !current)}
          type="button"
        >
          <span className="reliability-evidence-icon" aria-hidden="true">✚</span>
          <span>
            <strong>{financialOnly ? "Injury refund evidence" : "Match operations"}</strong>
            <small>
              {financialOnly
                ? "Verified injury facts for the existing refund policy only"
                : activePeriods.length > 0
                ? `${activePeriods.length} team ${activePeriods.length === 1 ? "is" : "are"} playing short`
                : injuries.length > 0
                  ? `${injuries.length} verified ${injuries.length === 1 ? "injury" : "injuries"}`
                  : fixture.matchKind === "SOLO"
                    ? "Host reserve plan and in-match evidence"
                    : "Injury and shorthanded evidence"}
            </small>
          </span>
          {!financialOnly && activePeriods.length > 0 ? (
            <span className="reliability-evidence-live">Live</span>
          ) : null}
          <span className="reliability-evidence-chevron" aria-hidden="true">⌄</span>
        </button>

        {expanded ? (
          <div className="reliability-evidence-body">
            {!financialOnly && fixture.matchKind === "SOLO" && context.replacementOrder.length > 0 ? (
              <div className="reliability-reserve-plan">
                <header>
                  <span><strong>Host reserve plan</strong><small>Frozen match policy · {context.policyVersionId?.slice(0, 8) ?? "snapshot"}</small></span>
                  <b>Manual</b>
                </header>
                <ol>
                  {context.replacementOrder.map((step, index) => (
                    <li key={step}>
                      <span>{index + 1}</span>
                      <div>
                        <strong>{reserveStepLabel(step)}</strong>
                        <small>{reserveStepDetail(step, context.reserveActivationAt, context.originalPlayerReclaimUntilAt)}</small>
                      </div>
                    </li>
                  ))}
                </ol>
                <p>Follow and record this plan. Field does not automatically assign or activate a reserve.</p>
              </div>
            ) : null}
            {!financialOnly && activePeriods.length > 0 ? (
              <div className="shorthanded-active-list">
                {activePeriods.map((period) => (
                  <div className="shorthanded-active-row" key={period.id}>
                    <span className="shorthanded-pulse" aria-hidden="true" />
                    <span>
                      <strong>{sideName(fixture, period.side)} playing short</strong>
                      <small>
                        {REASON_LABELS[period.reason]} · from {formatMatchSecond(period.startedMatchSecond)}
                      </small>
                    </span>
                    <button
                      className="ghost-button compact-button"
                      disabled={!canRecord || submitting !== null}
                      onClick={() => openEndShort(period)}
                      type="button"
                    >
                      End
                    </button>
                  </div>
                ))}
              </div>
            ) : null}

            <div className="reliability-evidence-actions">
              <button
                disabled={!canRecord || injuryCandidates.length === 0 || submitting !== null}
                onClick={openInjury}
                type="button"
              >
                <span aria-hidden="true">✚</span>
                <span><strong>Verify injury</strong><small>Checked-in player</small></span>
              </button>
              {!financialOnly ? <button
                disabled={!canRecord || availableSides.length === 0 || submitting !== null}
                onClick={openStartShort}
                type="button"
              >
                <span aria-hidden="true">−1</span>
                <span><strong>Team playing short</strong><small>Start server timer</small></span>
              </button> : null}
            </div>

            <p className="reliability-evidence-note">
              {financialOnly
                ? "Record only facts you witnessed. This is refund evidence only: it does not change SR, attendance or playing time. Record the player’s actual departure separately in Playing time. No external replacements are allowed."
                : "Record only facts you witnessed. The server records match time; host facts drive the policy’s SR and refund rules."}
            </p>
          </div>
        ) : null}
      </section>

      {dialog ? (
        <div
          className="safety-modal-backdrop"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget && submitting === null) {
              setDialog(null);
            }
          }}
        >
          <section
            aria-labelledby="reliability-evidence-dialog-title"
            aria-modal="true"
            className="safety-modal reliability-evidence-modal"
            role="dialog"
          >
            <button
              aria-label="Close"
              className="safety-modal-close"
              disabled={submitting !== null}
              onClick={() => setDialog(null)}
              type="button"
            >
              <span aria-hidden="true">×</span>
            </button>

            {dialog === "injury" ? (
              <form onSubmit={submitInjury}>
                <div className="safety-modal-icon reliability-injury-icon" aria-hidden="true">✚</div>
                <span className="safety-modal-eyebrow">Verified match fact</span>
                <h2 id="reliability-evidence-dialog-title">Record an injury</h2>
                <p className="safety-modal-intro">
                  Use this only for an injury you verified during play. The match
                  second is taken from the server clock.
                </p>

                <label>
                  <span className="field-label">Checked-in player</span>
                  <select
                    autoFocus
                    className="select"
                    onChange={(event) => setProfileId(event.target.value)}
                    required
                    value={profileId}
                  >
                    {injuryCandidates.map((player) => (
                      <option key={player.profileId} value={player.profileId}>
                        {player.displayName} · {sideName(fixture, playerSide(fixture, player))}
                      </option>
                    ))}
                  </select>
                </label>

                <div className="reliability-fact-choices">
                  <BooleanFact
                    checked={unableToContinue}
                    label="Unable to continue"
                    onChange={setUnableToContinue}
                  />
                  {!financialOnly ? <BooleanFact
                    checked={replacementAvailable}
                    label="Replacement available"
                    onChange={setReplacementAvailable}
                  /> : null}
                  <BooleanFact
                    checked={matchContinued}
                    label="Match continued"
                    onChange={setMatchContinued}
                  />
                </div>

                <EvidenceNote value={note} onChange={setNote} />
                <EvidencePolicyNotice financialOnly={financialOnly} />
                {localError ? <div className="safety-modal-error">{localError}</div> : null}
                <ModalActions
                  busy={submitting !== null}
                  confirmLabel={submitting === "record_verified_injury" ? "Recording…" : "Record verified injury"}
                  onCancel={() => setDialog(null)}
                />
              </form>
            ) : dialog === "start-short" ? (
              <form onSubmit={submitStartShort}>
                <div className="safety-modal-icon reliability-short-icon" aria-hidden="true">−1</div>
                <span className="safety-modal-eyebrow">Server-timed match fact</span>
                <h2 id="reliability-evidence-dialog-title">Team is playing short</h2>
                <p className="safety-modal-intro">
                  Start this when play actually begins with one fewer player.
                  Do not estimate or enter a match time.
                </p>

                <div className="reliability-side-grid" aria-label="Team playing short">
                  {availableSides.map((candidate) => (
                    <button
                      className={side === candidate.value ? "active" : ""}
                      key={candidate.value}
                      onClick={() => {
                        setSide(candidate.value);
                        setCausedByProfileId("");
                      }}
                      type="button"
                    >
                      <span aria-hidden="true">{candidate.emblem}</span>
                      <strong>{candidate.label}</strong>
                    </button>
                  ))}
                </div>

                <div className="safety-form-row">
                  <label>
                    <span className="field-label">Reason</span>
                    <select
                      className="select"
                      onChange={(event) => setReason(event.target.value)}
                      value={reason}
                    >
                      {SHORTHANDED_REASONS.map((item) => (
                        <option key={item} value={item}>{REASON_LABELS[item]}</option>
                      ))}
                    </select>
                  </label>
                  <label>
                    <span className="field-label">Player (optional)</span>
                    <select
                      className="select"
                      onChange={(event) => setCausedByProfileId(event.target.value)}
                      value={causedByProfileId}
                    >
                      <option value="">Not linked</option>
                      {sidePlayers.map((player) => (
                        <option key={player.profileId} value={player.profileId}>
                          {player.displayName}
                        </option>
                      ))}
                    </select>
                  </label>
                </div>
                <EvidenceNote value={note} onChange={setNote} />
                <EvidencePolicyNotice />
                {localError ? <div className="safety-modal-error">{localError}</div> : null}
                <ModalActions
                  busy={submitting !== null || !side}
                  confirmLabel={submitting === "start_shorthanded" ? "Starting…" : "Start period"}
                  onCancel={() => setDialog(null)}
                />
              </form>
            ) : (
              <form onSubmit={submitEndShort}>
                <div className="safety-modal-icon" aria-hidden="true">✓</div>
                <span className="safety-modal-eyebrow">End server timer</span>
                <h2 id="reliability-evidence-dialog-title">
                  {selectedPeriod ? `${sideName(fixture, selectedPeriod.side)} restored` : "End shorthanded period"}
                </h2>
                <p className="safety-modal-intro">
                  End this when the team is back to its expected number. The
                  server records the exact match second.
                </p>
                <label>
                  <span className="field-label">Replacement (optional)</span>
                  <select
                    autoFocus
                    className="select"
                    onChange={(event) => setReplacementProfileId(event.target.value)}
                    value={replacementProfileId}
                  >
                    <option value="">No replacement linked</option>
                    {replacementPlayers.map((player) => (
                      <option key={player.profileId} value={player.profileId}>
                        {player.displayName}
                      </option>
                    ))}
                  </select>
                </label>
                <EvidenceNote value={note} onChange={setNote} />
                <EvidencePolicyNotice />
                {localError ? <div className="safety-modal-error">{localError}</div> : null}
                <ModalActions
                  busy={submitting !== null || !periodId}
                  confirmLabel={submitting === "end_shorthanded" ? "Ending…" : "End period now"}
                  onCancel={() => setDialog(null)}
                />
              </form>
            )}
          </section>
        </div>
      ) : null}
    </>
  );
}

function BooleanFact({
  checked,
  label,
  onChange,
}: {
  checked: boolean;
  label: string;
  onChange: (value: boolean) => void;
}) {
  return (
    <label className="reliability-fact-choice">
      <span>{label}</span>
      <input
        checked={checked}
        onChange={(event) => onChange(event.target.checked)}
        type="checkbox"
      />
      <span className="reliability-fact-switch" aria-hidden="true" />
    </label>
  );
}

function EvidenceNote({
  value,
  onChange,
}: {
  value: string;
  onChange: (value: string) => void;
}) {
  return (
    <label>
      <span className="field-label">Concise note (optional)</span>
      <textarea
        className="input textarea reliability-evidence-textarea"
        maxLength={1000}
        onChange={(event) => onChange(event.target.value)}
        placeholder="Facts only — what you directly observed."
        value={value}
      />
    </label>
  );
}

function EvidencePolicyNotice({ financialOnly = false }: { financialOnly?: boolean }) {
  return (
    <div className="reliability-policy-notice">
      <strong>{financialOnly ? "Refund evidence only" : "Host facts are authoritative"}</strong>
      <span>
        {financialOnly
          ? "The existing injury refund policy decides eligibility; recording this fact does not promise a refund. It has no SR, attendance or participation effect. Use Playing time separately for an actual departure. External replacements remain unavailable."
          : "This evidence may change Player SR or refund treatment under the policy snapshotted for this match. It does not add a strike for a verified injury."}
      </span>
    </div>
  );
}

function ModalActions({
  busy,
  confirmLabel,
  onCancel,
}: {
  busy: boolean;
  confirmLabel: string;
  onCancel: () => void;
}) {
  return (
    <div className="safety-modal-actions">
      <button className="ghost-button" disabled={busy} onClick={onCancel} type="button">
        Cancel
      </button>
      <button className="primary-button" disabled={busy} type="submit">
        {confirmLabel}
      </button>
    </div>
  );
}

function sidesFor(fixture: RefereeFixture) {
  return fixture.matchKind === "SOLO"
    ? [
        { value: "WHITE", label: fixture.homeClan.name, emblem: fixture.homeClan.emblem },
        { value: "BLACK", label: fixture.awayClan.name, emblem: fixture.awayClan.emblem },
      ]
    : [
        { value: "HOME", label: fixture.homeClan.name, emblem: fixture.homeClan.emblem },
        { value: "AWAY", label: fixture.awayClan.name, emblem: fixture.awayClan.emblem },
      ];
}

function playerSide(
  fixture: RefereeFixture,
  player: ReliabilityAttendancePlayer,
) {
  if (player.side) return player.side;
  if (fixture.matchKind === "SOLO") {
    if (player.teamId === "WHITE" || player.teamId === "BLACK") return player.teamId;
  }
  if (player.teamId === fixture.homeClan.id) return "HOME";
  if (player.teamId === fixture.awayClan.id) return "AWAY";
  return null;
}

function sideName(fixture: RefereeFixture, side: string | null) {
  if (side === "WHITE" || side === "HOME") return fixture.homeClan.name;
  if (side === "BLACK" || side === "AWAY") return fixture.awayClan.name;
  return "Team";
}

function formatMatchSecond(value: number) {
  const safe = Math.max(0, Math.round(value));
  return `${Math.floor(safe / 60)}:${String(safe % 60).padStart(2, "0")}`;
}

function reserveStepLabel(step: NonNullable<RefereeFixture["reliabilityContext"]>["replacementOrder"][number]) {
  switch (step) {
    case "EMERGENCY_NOTIFICATION": return "Notify eligible players";
    case "ON_FIELD_RESERVE": return "Confirm the on-field reserve";
    case "PLAY_SHORTHANDED": return "Record play as shorthanded";
  }
}

function reserveStepDetail(
  step: NonNullable<RefereeFixture["reliabilityContext"]>["replacementOrder"][number],
  reserveActivationAt: string | null,
  reclaimUntilAt: string | null,
) {
  switch (step) {
    case "EMERGENCY_NOTIFICATION":
      return "Use the emergency replacement list in the configured order.";
    case "ON_FIELD_RESERVE":
      return `Original player may reclaim until ${formatBahrainClock(reclaimUntilAt)}; reserve is final at ${formatBahrainClock(reserveActivationAt)}.`;
    case "PLAY_SHORTHANDED":
      return "If no eligible reserve is confirmed, start and record the short-handed period.";
  }
}

function formatBahrainClock(value: string | null) {
  if (!value || !Number.isFinite(Date.parse(value))) return "the policy cutoff";
  return new Intl.DateTimeFormat("en-BH", {
    timeZone: "Asia/Bahrain",
    hour: "numeric",
    minute: "2-digit",
  }).format(new Date(value));
}

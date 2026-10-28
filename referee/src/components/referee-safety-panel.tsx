"use client";

import { useEffect, useMemo, useState } from "react";

import {
  FORFEIT_STOP_REASON_CODES,
  REPORT_CATEGORIES,
  REPORT_PRIORITIES,
  STOP_REASON_CODES,
  type ReportSubjectType,
  type StopMode,
} from "@/lib/match-action-input";
import type { RefereeFixture } from "@/lib/types";
import { SEASON_ZERO_POLICY } from "@/lib/season-zero-actions";

type SafetyActionBody = Record<
  string,
  string | number | null | undefined
>;

type RefereeSafetyPanelProps = {
  fixture: RefereeFixture;
  submitting: string | null;
  onAction: (body: SafetyActionBody) => Promise<boolean>;
  compact?: boolean;
};

type DialogKind = "stop" | "report" | null;
type AbandonOutcome = "NEUTRAL" | "TEAM_RESPONSIBLE";

const STOP_LABELS: Record<(typeof STOP_REASON_CODES)[number], string> = {
  MEDICAL_EMERGENCY: "Medical emergency",
  SERIOUS_INJURY: "Serious injury",
  FIGHTING_OR_VIOLENCE: "Fight or violence",
  THREAT_TO_REFEREE: "Threat to referee",
  UNSAFE_VENUE_OR_WEATHER: "Unsafe venue or weather",
  CROWD_OR_SECURITY: "Crowd or security issue",
  EQUIPMENT_OR_TECHNICAL_FAILURE: "Equipment or technical failure",
  INSUFFICIENT_PLAYERS: "Not enough players",
  TEAM_WALKOUT: "Team walkout",
  REFEREE_UNABLE_TO_CONTINUE: "Referee unable to continue",
  OTHER: "Other safety reason",
};

const REPORT_LABELS: Record<(typeof REPORT_CATEGORIES)[number], string> = {
  HARASSMENT: "Harassment",
  THREATS_OR_VIOLENCE: "Threats or violence",
  DISCRIMINATION: "Discrimination",
  DANGEROUS_PLAY: "Dangerous play",
  CHEATING: "Cheating",
  NO_SHOW_OR_MATCH_MANIPULATION: "No-show or match manipulation",
  INAPPROPRIATE_CONTENT: "Inappropriate content",
  SAFETY_OR_VENUE: "Safety or venue issue",
  SCORE_OR_RESULT: "Score or result issue",
  REFEREE_ABUSE: "Referee abuse",
  OTHER: "Other",
};

export function RefereeSafetyPanel({
  fixture,
  submitting,
  onAction,
  compact = false,
}: RefereeSafetyPanelProps) {
  const [dialog, setDialog] = useState<DialogKind>(null);
  const [stopMode, setStopMode] = useState<StopMode>("TEMPORARY");
  const [abandonOutcome, setAbandonOutcome] =
    useState<AbandonOutcome>("NEUTRAL");
  const [responsibleClanId, setResponsibleClanId] = useState("");
  const [stopReason, setStopReason] = useState("");
  const [stopNote, setStopNote] = useState("");
  const [reportSubject, setReportSubject] =
    useState<ReportSubjectType>("MATCH");
  const [reportTargetId, setReportTargetId] = useState(fixture.id);
  const [reportCategory, setReportCategory] = useState("");
  const [reportPriority, setReportPriority] = useState("HIGH");
  const [reportDetails, setReportDetails] = useState("");
  const [localError, setLocalError] = useState<string | null>(null);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);

  const reportablePlayers = useMemo(() => {
    if (fixture.participantIds.length === 0) return [];
    const participantIds = new Set(fixture.participantIds);
    return fixture.players.filter((player) => participantIds.has(player.id));
  }, [fixture.participantIds, fixture.players]);

  useEffect(() => {
    setDialog(null);
    setStopMode("TEMPORARY");
    setAbandonOutcome("NEUTRAL");
    setResponsibleClanId("");
    setStopReason("");
    setStopNote("");
    setReportSubject("MATCH");
    setReportTargetId(fixture.id);
    setReportCategory("");
    setReportPriority("HIGH");
    setReportDetails("");
    setLocalError(null);
    setSuccessMessage(null);
  }, [fixture.id]);

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

  function openDialog(kind: Exclude<DialogKind, null>) {
    setLocalError(null);
    setSuccessMessage(null);
    setDialog(kind);
  }

  function chooseReportSubject(subject: ReportSubjectType) {
    setReportSubject(subject);
    setReportTargetId(
      subject === "MATCH"
        ? fixture.id
        : subject === "CLAN"
          ? fixture.homeClan.id
          : reportablePlayers[0]?.id ?? "",
    );
  }

  async function submitStop(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setLocalError(null);
    const isTeamForfeit =
      fixture.matchKind === "CLAN" &&
      stopMode === "ABANDON" &&
      abandonOutcome === "TEAM_RESPONSIBLE";
    if (!stopReason) {
      setLocalError("Choose why play is being stopped.");
      return;
    }
    if (isTeamForfeit && !responsibleClanId) {
      setLocalError("Choose the team responsible for ending the match.");
      return;
    }
    if (isTeamForfeit && stopNote.trim().length < 10) {
      setLocalError("Briefly explain how the team caused the match to end.");
      return;
    }
    if (!isTeamForfeit && stopReason === "OTHER" && stopNote.trim().length < 10) {
      setLocalError("Add a short explanation for this stoppage.");
      return;
    }

    const succeeded = await onAction(
      isTeamForfeit
        ? {
            action: "forfeit",
            reportedClanId: responsibleClanId,
            category: categoryForForfeitReason(stopReason),
            details: stopNote.trim(),
            reasonCode: stopReason,
            note: stopReason === "OTHER" ? stopNote.trim() : null,
            replayOffsetSeconds: currentReplayOffset(fixture),
          }
        : {
            action: "stop",
            mode: stopMode,
            reasonCode: stopReason,
            note: stopNote.trim() || null,
          },
    );
    if (!succeeded) {
      setLocalError("The stoppage was not saved. Review the error and try again.");
      return;
    }

    setDialog(null);
    setSuccessMessage(
      isTeamForfeit
        ? "Provisional 3–0 result recorded and sent to admins for review."
        : stopMode === "ABANDON"
        ? fixture.ratingPolicyId === SEASON_ZERO_POLICY
          ? "Play stopped. Ratings are held for organizer review; no result or forfeit has been awarded."
          : "Match abandoned. The incident and broadcast stop were recorded."
        : "Safety stop recorded. Resume play only when it is safe.",
    );
  }

  async function submitReport(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setLocalError(null);
    if (!reportTargetId) {
      setLocalError("Choose who or what you are reporting.");
      return;
    }
    if (!reportCategory) {
      setLocalError("Choose a report reason.");
      return;
    }
    if (reportDetails.trim().length < 5) {
      setLocalError("Briefly explain what happened.");
      return;
    }

    const succeeded = await onAction({
      action: "report",
      subjectType: reportSubject,
      subjectId: reportTargetId,
      category: reportCategory,
      details: reportDetails.trim(),
      priority: reportPriority,
      replayOffsetSeconds: currentReplayOffset(fixture),
    });
    if (!succeeded) {
      setLocalError("The report was not sent. Review the error and try again.");
      return;
    }

    setDialog(null);
    setSuccessMessage("Report sent privately to the admin review queue.");
  }

  const canStop = fixture.status === "LIVE";

  return (
    <>
      <section className={`${compact ? "compact" : "panel"} referee-safety-panel`}>
        {!compact ? (
          <>
            <div className="referee-safety-heading">
              <div>
                <span className="referee-safety-kicker">Incident tools</span>
                <h2 className="panel-title">Match safety</h2>
              </div>
              <span className="referee-safety-private">Private log</span>
            </div>
            <p className="referee-safety-copy">
              Pause play for a documented safety issue or flag something for admin
              review.
            </p>
          </>
        ) : null}
        <div className="referee-safety-actions">
          <button
            className="referee-safety-action stop"
            disabled={!canStop || submitting !== null}
            onClick={() => openDialog("stop")}
            type="button"
          >
            <SafetyIcon />
            <span>
              <strong>{compact ? "Stop play" : "Safety stop"}</strong>
              <small>{canStop ? "Pause or abandon" : "Live matches only"}</small>
            </span>
          </button>
          <button
            className="referee-safety-action report"
            disabled={submitting !== null}
            onClick={() => openDialog("report")}
            type="button"
          >
            <FlagIcon />
            <span>
              <strong>{compact ? "Report" : "File report"}</strong>
              <small>Private admin review</small>
            </span>
          </button>
        </div>
        {successMessage ? (
          <div className="referee-safety-success" role="status">
            <span aria-hidden="true">✓</span>
            {successMessage}
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
            aria-labelledby="safety-dialog-title"
            aria-modal="true"
            className="safety-modal"
            role="dialog"
          >
            <button
              aria-label="Close"
              className="safety-modal-close"
              disabled={submitting !== null}
              onClick={() => setDialog(null)}
              type="button"
            >
              <CloseIcon />
            </button>

            {dialog === "stop" ? (
              <form onSubmit={submitStop}>
                <div className="safety-modal-icon danger"><SafetyIcon /></div>
                <span className="safety-modal-eyebrow">Live match control</span>
                <h2 id="safety-dialog-title">Stop play safely</h2>
                <p className="safety-modal-intro">
                  Use this for a real safety incident. Ordinary breaks can use the
                  regular Pause button.
                </p>

                <div className="safety-mode-grid">
                  <button
                    className={stopMode === "TEMPORARY" ? "active" : ""}
                    onClick={() => {
                      setStopMode("TEMPORARY");
                      setAbandonOutcome("NEUTRAL");
                      setResponsibleClanId("");
                    }}
                    type="button"
                  >
                    <strong>Temporary stop</strong>
                    <span>Pause clock and review</span>
                  </button>
                  <button
                    className={`abandon ${stopMode === "ABANDON" ? "active" : ""}`}
                    onClick={() => setStopMode("ABANDON")}
                    type="button"
                  >
                    <strong>Abandon match</strong>
                    <span>End and mark cancelled</span>
                  </button>
                </div>

                {stopMode === "ABANDON" && fixture.matchKind === "CLAN" ? (
                  <div className="abandon-outcome-block">
                    <span className="field-label">How should this be recorded?</span>
                    <div className="abandon-outcome-grid">
                      <button
                        className={abandonOutcome === "NEUTRAL" ? "active" : ""}
                        onClick={() => {
                          setAbandonOutcome("NEUTRAL");
                          setResponsibleClanId("");
                          setStopReason("");
                        }}
                        type="button"
                      >
                        <strong>Neutral abandonment</strong>
                        <span>No team is judged responsible</span>
                      </button>
                      <button
                        className={`responsible ${abandonOutcome === "TEAM_RESPONSIBLE" ? "active" : ""}`}
                        onClick={() => {
                          setAbandonOutcome("TEAM_RESPONSIBLE");
                          setResponsibleClanId("");
                          if (!FORFEIT_STOP_REASON_CODES.includes(
                            stopReason as (typeof FORFEIT_STOP_REASON_CODES)[number],
                          )) {
                            setStopReason("");
                          }
                        }}
                        type="button"
                      >
                        <strong>Team responsible</strong>
                        <span>Report + provisional 3–0</span>
                      </button>
                    </div>
                  </div>
                ) : null}

                {stopMode === "ABANDON" &&
                abandonOutcome === "TEAM_RESPONSIBLE" &&
                fixture.matchKind === "CLAN" ? (
                  <div className="responsible-team-block">
                    <span className="field-label">Team responsible</span>
                    <div className="responsible-team-grid">
                      {[fixture.homeClan, fixture.awayClan].map((clan) => (
                        <button
                          className={responsibleClanId === clan.id ? "active" : ""}
                          key={clan.id}
                          onClick={() => setResponsibleClanId(clan.id)}
                          type="button"
                        >
                          <span aria-hidden="true">{clan.emblem}</span>
                          <strong>{clan.name}</strong>
                        </button>
                      ))}
                    </div>
                  </div>
                ) : null}

                <label>
                  <span className="field-label">Reason</span>
                  <select
                    autoFocus
                    className="select"
                    onChange={(event) => setStopReason(event.target.value)}
                    required
                    value={stopReason}
                  >
                    <option value="">Choose a reason</option>
                    {(stopMode === "ABANDON" &&
                    abandonOutcome === "TEAM_RESPONSIBLE"
                      ? FORFEIT_STOP_REASON_CODES
                      : STOP_REASON_CODES
                    ).map((reason) => (
                      <option key={reason} value={reason}>{STOP_LABELS[reason]}</option>
                    ))}
                  </select>
                </label>
                <label>
                  <span className="field-label">
                    {stopMode === "ABANDON" && abandonOutcome === "TEAM_RESPONSIBLE"
                      ? "What happened?"
                      : "Notes (optional)"}
                  </span>
                  <textarea
                    className="input textarea"
                    maxLength={2000}
                    onChange={(event) => setStopNote(event.target.value)}
                    placeholder={
                      stopMode === "ABANDON" && abandonOutcome === "TEAM_RESPONSIBLE"
                        ? "State the facts that made this team responsible for ending the match."
                        : "What happened, where, and who was involved?"
                    }
                    required={
                      stopMode === "ABANDON" && abandonOutcome === "TEAM_RESPONSIBLE"
                    }
                    value={stopNote}
                  />
                </label>

                <div className={`safety-consequence ${stopMode === "ABANDON" ? "danger" : ""}`}>
                  <strong>
                    {stopMode === "ABANDON" && abandonOutcome === "TEAM_RESPONSIBLE"
                      ? responsibleClanId
                        ? `${opponentName(fixture, responsibleClanId)} receives a provisional 3–0 win`
                        : "Choose the team responsible"
                      : stopMode === "ABANDON"
                        ? "This ends the match"
                        : "Clock will pause"}
                  </strong>
                  <span>
                    {stopMode === "ABANDON" && abandonOutcome === "TEAM_RESPONSIBLE"
                      ? "The match stops immediately. Player and clan SR wait for an admin to confirm or overturn the referee decision."
                      : stopMode === "ABANDON"
                      ? "The fixture is cancelled, active cards are cleared, the broadcast is stopped, and admins are alerted."
                      : "A timestamped incident and admin report are created. You can resume when the venue is safe."}
                  </span>
                </div>
                <p className="safety-emergency-note">
                  Handle immediate danger first. This form does not contact emergency services.
                </p>
                {localError ? <div className="safety-modal-error">{localError}</div> : null}
                <div className="safety-modal-actions">
                  <button
                    className="ghost-button"
                    disabled={submitting !== null}
                    onClick={() => setDialog(null)}
                    type="button"
                  >
                    Go back
                  </button>
                  <button
                    className={stopMode === "ABANDON" ? "danger-button" : "primary-button"}
                    disabled={
                      submitting !== null ||
                      !stopReason ||
                      (stopMode === "ABANDON" &&
                        abandonOutcome === "TEAM_RESPONSIBLE" &&
                        (!responsibleClanId || stopNote.trim().length < 10))
                    }
                    type="submit"
                  >
                    {submitting === "stop" || submitting === "forfeit"
                      ? "Saving…"
                      : stopMode === "ABANDON" && abandonOutcome === "TEAM_RESPONSIBLE"
                        ? "Record provisional 3–0"
                      : stopMode === "ABANDON"
                        ? "Confirm abandonment"
                        : "Pause for safety"}
                  </button>
                </div>
              </form>
            ) : (
              <form onSubmit={submitReport}>
                <div className="safety-modal-icon"><FlagIcon /></div>
                <span className="safety-modal-eyebrow">Private admin report</span>
                <h2 id="safety-dialog-title">Flag an issue</h2>
                <p className="safety-modal-intro">
                  Reports are not shown to players or clans. Admins review the
                  context before taking action.
                </p>

                <div className="report-subject-tabs" aria-label="Report subject">
                  <button
                    className={reportSubject === "MATCH" ? "active" : ""}
                    onClick={() => chooseReportSubject("MATCH")}
                    type="button"
                  >Match</button>
                  {reportablePlayers.length > 0 ? (
                    <button
                      className={reportSubject === "PLAYER" ? "active" : ""}
                      onClick={() => chooseReportSubject("PLAYER")}
                      type="button"
                    >Player</button>
                  ) : null}
                  {fixture.matchKind === "CLAN" ? (
                    <button
                      className={reportSubject === "CLAN" ? "active" : ""}
                      onClick={() => chooseReportSubject("CLAN")}
                      type="button"
                    >Clan</button>
                  ) : null}
                </div>

                {reportSubject === "PLAYER" ? (
                  <label>
                    <span className="field-label">Player</span>
                    <select
                      className="select"
                      onChange={(event) => setReportTargetId(event.target.value)}
                      value={reportTargetId}
                    >
                      {reportablePlayers.map((player) => (
                        <option key={player.id} value={player.id}>
                          {player.displayName} · {teamName(fixture, player.clanId)}
                        </option>
                      ))}
                    </select>
                  </label>
                ) : reportSubject === "CLAN" ? (
                  <label>
                    <span className="field-label">Clan</span>
                    <select
                      className="select"
                      onChange={(event) => setReportTargetId(event.target.value)}
                      value={reportTargetId}
                    >
                      {[fixture.homeClan, fixture.awayClan].map((clan) => (
                        <option key={clan.id} value={clan.id}>{clan.name}</option>
                      ))}
                    </select>
                  </label>
                ) : (
                  <div className="report-match-target">
                    <span>Match</span>
                    <strong>{fixture.homeClan.tag} vs {fixture.awayClan.tag}</strong>
                  </div>
                )}

                <div className="safety-form-row">
                  <label>
                    <span className="field-label">Issue</span>
                    <select
                      autoFocus
                      className="select"
                      onChange={(event) => setReportCategory(event.target.value)}
                      required
                      value={reportCategory}
                    >
                      <option value="">Choose a reason</option>
                      {REPORT_CATEGORIES.map((category) => (
                        <option key={category} value={category}>{REPORT_LABELS[category]}</option>
                      ))}
                    </select>
                  </label>
                  <label>
                    <span className="field-label">Priority</span>
                    <select
                      className="select"
                      onChange={(event) => setReportPriority(event.target.value)}
                      value={reportPriority}
                    >
                      {REPORT_PRIORITIES.map((priority) => (
                        <option key={priority} value={priority}>{titleCase(priority)}</option>
                      ))}
                    </select>
                  </label>
                </div>
                <label>
                  <span className="field-label">What happened?</span>
                  <textarea
                    className="input textarea"
                    maxLength={2000}
                    onChange={(event) => setReportDetails(event.target.value)}
                    placeholder="Add the facts an admin needs to review this fairly."
                    required
                    value={reportDetails}
                  />
                </label>
                <div className="report-replay-note">
                  The current match time is attached so admins can find the moment in the replay.
                </div>
                {localError ? <div className="safety-modal-error">{localError}</div> : null}
                <div className="safety-modal-actions">
                  <button
                    className="ghost-button"
                    disabled={submitting !== null}
                    onClick={() => setDialog(null)}
                    type="button"
                  >Cancel</button>
                  <button
                    className="primary-button"
                    disabled={
                      submitting !== null ||
                      !reportTargetId ||
                      !reportCategory ||
                      reportDetails.trim().length < 5
                    }
                    type="submit"
                  >
                    {submitting === "report" ? "Sending…" : "Send report"}
                  </button>
                </div>
              </form>
            )}
          </section>
        </div>
      ) : null}
    </>
  );
}

function currentReplayOffset(fixture: RefereeFixture) {
  const clock = fixture.clock;
  if (!clock) return 0;
  const runningSeconds = clock.status === "RUNNING" && clock.startedAt
    ? Math.max(0, Math.floor((Date.now() - Date.parse(clock.startedAt)) / 1000))
    : 0;
  return Math.min(10_800, Math.max(0, Math.round(clock.accumulatedSeconds + runningSeconds)));
}

function categoryForForfeitReason(reasonCode: string) {
  switch (reasonCode) {
    case "FIGHTING_OR_VIOLENCE":
      return "THREATS_OR_VIOLENCE";
    case "THREAT_TO_REFEREE":
      return "REFEREE_ABUSE";
    case "CROWD_OR_SECURITY":
      return "SAFETY_OR_VENUE";
    case "INSUFFICIENT_PLAYERS":
    case "TEAM_WALKOUT":
      return "NO_SHOW_OR_MATCH_MANIPULATION";
    default:
      return "OTHER";
  }
}

function opponentName(fixture: RefereeFixture, responsibleClanId: string) {
  return fixture.homeClan.id === responsibleClanId
    ? fixture.awayClan.name
    : fixture.homeClan.name;
}

function teamName(fixture: RefereeFixture, clanId: string) {
  if (fixture.homeClan.id === clanId) return fixture.homeClan.name;
  if (fixture.awayClan.id === clanId) return fixture.awayClan.name;
  return "Team";
}

function titleCase(value: string) {
  return value.charAt(0) + value.slice(1).toLowerCase();
}

function SafetyIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24">
      <path d="M12 3 5.5 5.6v5.7c0 4.3 2.7 8 6.5 9.7 3.8-1.7 6.5-5.4 6.5-9.7V5.6L12 3Z" />
      <path d="M12 7.2v5.4M12 16.2h.01" />
    </svg>
  );
}

function FlagIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24">
      <path d="M6 21V4m0 1h10.3l-1.8 3 1.8 3H6" />
    </svg>
  );
}

function CloseIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24">
      <path d="m7 7 10 10M17 7 7 17" />
    </svg>
  );
}

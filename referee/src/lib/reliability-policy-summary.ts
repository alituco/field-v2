import type { ReliabilityPolicyConfig } from "./reliability-policy";

export type ReliabilityPolicyDocumentStatus = "ACTIVE" | "DRAFT" | "SCHEDULED" | "HISTORICAL";

export type ReliabilityPolicySummaryRule = {
  title: string;
  explanation: string;
  facts?: string[];
};

export type ReliabilityPolicySummarySection = {
  id: string;
  title: string;
  introduction: string;
  rules: ReliabilityPolicySummaryRule[];
};

export type ReliabilityPolicySummaryDocument = {
  title: string;
  status: ReliabilityPolicyDocumentStatus;
  versionLabel: string;
  effectiveDateLabel: string;
  changeSummary: string;
  generatedAtLabel: string;
  sections: ReliabilityPolicySummarySection[];
};

export type ReliabilityPolicySummaryMetadata = {
  status: ReliabilityPolicyDocumentStatus;
  version?: number | null;
  effectiveFrom: string;
  changeSummary?: string;
  generatedAt?: Date;
};

export function buildReliabilityPolicySummary(
  config: ReliabilityPolicyConfig,
  metadata: ReliabilityPolicySummaryMetadata,
): ReliabilityPolicySummaryDocument {
  const generatedAt = metadata.generatedAt ?? new Date();
  const solo = config.solo.cancellations;
  const clan = config.clan.cancellations;
  const soloEarlyHours = solo.early.minimumHoursBeforeKickoff;
  const soloLateHours = solo.late.minimumHoursBeforeKickoff;
  const clanEarlyHours = clan.early.minimumHoursBeforeKickoff;
  const clanLateHours = clan.late.minimumHoursBeforeKickoff;

  return {
    title: "Field Reliability Policy",
    status: metadata.status,
    versionLabel: metadata.version ? `Version ${metadata.version}` : "Unpublished draft",
    effectiveDateLabel: formatBahrainDate(metadata.effectiveFrom),
    changeSummary: metadata.changeSummary?.trim() || "Reliability rules for Field matches.",
    generatedAtLabel: formatBahrainDateTime(generatedAt),
    sections: [
      {
        id: "at-a-glance",
        title: "At a glance",
        introduction: "The essential rules players, clans, referees, and support staff need before matchday.",
        rules: [
          {
            title: "Match format",
            explanation: `Solo matches are ${config.solo.playersPerSide}v${config.solo.playersPerSide}. Clan matches are ${config.clan.playersPerSide}v${config.clan.playersPerSide}. Existing games keep their original format.`,
            facts: [
              `Solo: ${config.solo.playersPerSide} players per side`,
              `Clan: ${config.clan.playersPerSide} players per side`,
            ],
          },
          {
            title: "Check-in is referee managed",
            explanation: `Referees may check players in at any time. A player is late after the check-in deadline, ${config.attendance.checkInLeadMinutes} minutes before kickoff, and becomes a no-show ${config.attendance.noShowGraceMinutes} minutes after kickoff.`,
          },
          {
            title: "Strikes expire",
            explanation: `An active reliability strike expires after ${config.attendance.strikeLifetimeDays} days. An appeal must be submitted within ${config.attendance.appealWindowHours} hours.`,
          },
        ],
      },
      {
        id: "solo-cancellations",
        title: "Solo match cancellations",
        introduction: "The cancellation time determines the booking refund and reliability strikes.",
        rules: [
          consequenceRule(
            `Cancel at least ${soloEarlyHours} hours before kickoff`,
            "The place is released with the early-cancellation consequence.",
            solo.early.refundBps,
            solo.early.strikes,
            solo.early.advertise ? "The place is advertised again." : "The normal open-place flow applies.",
          ),
          consequenceRule(
            `Cancel between ${soloLateHours} and ${soloEarlyHours} hours before kickoff`,
            "This is treated as a late cancellation.",
            solo.late.refundBps,
            solo.late.strikes,
            solo.late.notify ? "Eligible replacement players are notified." : undefined,
          ),
          consequenceRule(
            `Cancel less than ${soloLateHours} hours before kickoff`,
            "This is treated as a very-late cancellation.",
            solo.veryLate.refundBps,
            solo.veryLate.strikes,
          ),
          consequenceRule(
            "Cancel after kickoff",
            "The cancellation is recorded as a no-show.",
            solo.afterKickoff.refundBps,
            solo.afterKickoff.strikes,
          ),
        ],
      },
      {
        id: "clan-cancellations",
        title: "Clan match cancellations",
        introduction: "Clan consequences apply to the clan. Individual attendance may still be recorded separately.",
        rules: [
          consequenceRule(
            `Cancel at least ${clanEarlyHours} hours before kickoff`,
            "The clan receives the early-cancellation consequence.",
            clan.early.refundBps,
            clan.early.strikes,
          ),
          consequenceRule(
            `Cancel between ${clanLateHours} and ${clanEarlyHours} hours before kickoff`,
            "This is treated as a late clan cancellation.",
            clan.late.refundBps,
            clan.late.strikes,
          ),
          consequenceRule(
            `Cancel less than ${clanLateHours} hours before kickoff`,
            "This is treated as a very-late clan cancellation.",
            clan.veryLate.refundBps,
            clan.veryLate.strikes,
          ),
          consequenceRule(
            "Cancel after kickoff",
            clan.afterKickoff.forfeit
              ? `The opponent receives an official ${config.clan.forfeitScore}–0 forfeit win.`
              : "The match is closed without an automatic forfeit score.",
            clan.afterKickoff.refundBps,
            clan.afterKickoff.strikes,
          ),
        ],
      },
      {
        id: "attendance",
        title: "Attendance and match readiness",
        introduction: "Server time and referee decisions determine whether attendance is early, late, or a no-show.",
        rules: [
          {
            title: "Solo attendance",
            explanation: "Each player receives one final attendance outcome.",
            facts: [
              outcomeFact("On time", config.solo.outcomes.onTime),
              outcomeFact("Late", config.solo.outcomes.late),
              outcomeFact("No-show", config.solo.outcomes.noShow),
              `Field or venue cancellation: ${percent(config.solo.outcomes.fieldCancelled.refundBps)} refund and ${strikes(config.solo.outcomes.fieldCancelled.strikes)}`,
            ],
          },
          {
            title: "Clan readiness",
            explanation: `A clan needs ${config.clan.minimumOnTimeWithoutClanStrike} players checked in by the deadline to avoid a clan strike and at least ${config.clan.minimumAtKickoffWithoutForfeit} players at kickoff to avoid forfeiting.`,
            facts: [
              `Short at the deadline: ${strikes(config.clan.partialAttendanceStrikes)}`,
              `Below the kickoff minimum: ${strikes(config.clan.forfeitStrikes)}`,
              `Entire clan absent: ${strikes(config.clan.entireClanNoShowStrikes)}`,
            ],
          },
        ],
      },
      {
        id: "deposits-sanctions",
        title: "Reliability deposits and sanctions",
        introduction: "Repeated reliability issues can add a refundable deposit or temporarily restrict participation.",
        rules: [
          {
            title: "Player reliability deposit",
            explanation: `At ${config.solo.reliabilityDeposit.activeStrikeThreshold} active strikes, a player pays a ${percent(config.solo.reliabilityDeposit.depositBps)} reliability deposit. An on-time return goes to Field Wallet.`,
            facts: [`The deposit is forfeited for: ${humanList(config.solo.reliabilityDeposit.forfeitOutcomes)}.`],
          },
          {
            title: "Clan reliability deposit",
            explanation: `At ${config.clan.reliabilityDeposit.activeStrikeThreshold} active strikes, a clan pays a ${percent(config.clan.reliabilityDeposit.depositBps)} reliability deposit.`,
            facts: [`The deposit is forfeited for: ${humanList(config.clan.reliabilityDeposit.forfeitOutcomes)}.`],
          },
          {
            title: "Player sanction ladder",
            explanation: config.solo.highestCrossedOnly
              ? "When one incident crosses several thresholds, only the strongest newly reached sanction applies."
              : "Every newly crossed sanction threshold may apply.",
            facts: config.solo.sanctions.map(sanctionFact),
          },
          {
            title: "Clan sanction ladder",
            explanation: "Clan sanctions depend on the clan's active strike total.",
            facts: config.clan.sanctions.map(sanctionFact),
          },
        ],
      },
      {
        id: "teams-replacements",
        title: "Teams, parties, and replacements",
        introduction: "These rules control when lineups settle and how Field fills a last-minute opening.",
        rules: [
          {
            title: "Team and kit assignment",
            explanation: `Solo teams and kits are assigned ${minutesBefore(config.solo.teamAssignmentLeadMinutes)} before kickoff. Parties lock ${minutesBefore(config.solo.partyLockLeadMinutes)} before kickoff, with a maximum party size of ${config.replacement.maxPartySize}.`,
          },
          {
            title: "Replacement order",
            explanation: config.replacement.order.map((step, index) => `${index + 1}. ${replacementStep(step)}`).join(" "),
            facts: [
              `Replacement discount: ${percent(config.replacement.lateCancellationDiscountBps)}`,
              `Original player may reclaim the place until ${config.replacement.originalPlayerReclaimUntilMinutesAfterKickoff} minutes after kickoff.`,
              `Reserve placement becomes final ${config.replacement.reserveActivationMinutesAfterKickoff} minutes after kickoff.`,
            ],
          },
        ],
      },
      {
        id: "rating-injury",
        title: "Player rating and verified injuries",
        introduction: "Attendance can adjust normal SR movement, while verified injuries receive their own treatment.",
        rules: [
          {
            title: "Late-player SR",
            explanation: `A late player receives ${percent(config.sr.latePositiveMultiplierBps)} of a normal SR gain and ${percent(config.sr.lateNegativeMultiplierBps)} of a normal SR loss.`,
          },
          {
            title: "Shorthanded protection",
            explanation: `Protection begins only after a side actually plays short-handed for ${config.sr.shorthandedQualifyingActualMinutes} minutes. On-time losing players receive ${percent(config.sr.protectedLosingOnTimeMultiplierBps)} of the normal loss; opposing winners receive ${percent(config.sr.protectedWinnerMultiplierBps)} of the normal gain.`,
            facts: [`A disadvantaged side that still wins receives ${percent(config.sr.disadvantagedWinnerMultiplierBps)} of the normal gain.`],
          },
          {
            title: "Referee-verified injury",
            explanation: `Before ${percent(config.injury.halfMatchThresholdBps)} of the match is completed, a verified injury receives a ${percent(config.injury.incompleteRefundBps)} refund, ${percent(config.injury.incompleteLosingMultiplierBps)} of a normal losing SR change, and ${percent(config.injury.incompleteWinningMultiplierBps)} of a normal winning SR change.`,
            facts: [`After the threshold, ${percent(config.injury.completedLossMultiplierBps)} of a normal losing SR change applies.`],
          },
        ],
      },
      {
        id: "appeals-refunds",
        title: "Appeals, refunds, and exceptions",
        introduction: "All corrections remain in the audit trail; published policy versions are not rewritten.",
        rules: [
          {
            title: "Appeals",
            explanation: `Appeals must be submitted within ${config.attendance.appealWindowHours} hours. Accepted categories are ${humanList(config.appeals.allowedCategories)}.`,
            facts: [config.appeals.routineTrafficAutomaticallyExcused
              ? "Routine traffic may be automatically excused."
              : "Routine traffic is not automatically excused."],
          },
          {
            title: "Refund destination",
            explanation: "Policy refunds are credited to Field Wallet in the game's currency. USD and historical BHD balances are kept separately, without currency conversion.",
          },
        ],
      },
    ],
  };
}

export function reliabilityPolicySummaryHtml(document: ReliabilityPolicySummaryDocument) {
  const sections = document.sections.map((section) => `
    <section>
      <header><span>${escapeHtml(section.id.replaceAll("-", " "))}</span><h2>${escapeHtml(section.title)}</h2><p>${escapeHtml(section.introduction)}</p></header>
      <div class="rules">${section.rules.map((rule) => `
        <article><h3>${escapeHtml(rule.title)}</h3><p>${escapeHtml(rule.explanation)}</p>${rule.facts?.length ? `<ul>${rule.facts.map((fact) => `<li>${escapeHtml(fact)}</li>`).join("")}</ul>` : ""}</article>
      `).join("")}</div>
    </section>`).join("");

  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(document.title)} · ${escapeHtml(document.versionLabel)}</title><style>
  :root{color-scheme:light;font-family:Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#0f172a;background:#eef2f3}*{box-sizing:border-box}body{margin:0}.page{width:min(960px,calc(100% - 32px));margin:32px auto;background:#fff;box-shadow:0 20px 60px #0f172a1a}.cover{padding:48px;background:linear-gradient(135deg,#0f172a,#064e3b);color:#fff}.brand{color:#34d399;font-size:12px;font-weight:900;letter-spacing:.18em}.cover h1{margin:24px 0 10px;font-size:42px;letter-spacing:-.04em}.cover p{max-width:680px;margin:0;color:#cbd5e1;line-height:1.6}.meta{display:grid;grid-template-columns:repeat(3,1fr);gap:1px;margin-top:32px;background:#ffffff24;border:1px solid #ffffff24}.meta div{padding:16px;background:#0f172a66}.meta span,.meta strong{display:block}.meta span{color:#94a3b8;font-size:10px;font-weight:800;text-transform:uppercase}.meta strong{margin-top:6px}.content{padding:40px 48px 56px}section+section{margin-top:42px}section>header span{color:#059669;font-size:10px;font-weight:900;letter-spacing:.14em;text-transform:uppercase}h2{margin:6px 0 5px;font-size:25px}section>header p{margin:0;color:#64748b;line-height:1.6}.rules{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px;margin-top:18px}article{border:1px solid #dbe5e2;border-radius:14px;padding:18px;background:#fbfdfc}h3{margin:0;font-size:15px}article p{margin:8px 0 0;color:#475569;font-size:13px;line-height:1.55}ul{margin:12px 0 0;padding-left:18px;color:#334155;font-size:12px;line-height:1.6}.foot{border-top:1px solid #e2e8f0;padding:20px 48px;color:#64748b;font-size:11px}@media(max-width:650px){.page{width:100%;margin:0}.cover,.content{padding:28px 22px}.cover h1{font-size:32px}.meta,.rules{grid-template-columns:1fr}.foot{padding:18px 22px}}@media print{body{background:#fff}.page{width:100%;margin:0;box-shadow:none}.cover{-webkit-print-color-adjust:exact;print-color-adjust:exact}section,article{break-inside:avoid}.rules{grid-template-columns:repeat(2,minmax(0,1fr))}}
  </style></head><body><main class="page"><div class="cover"><div class="brand">FIELD</div><h1>${escapeHtml(document.title)}</h1><p>${escapeHtml(document.changeSummary)}</p><div class="meta"><div><span>Status</span><strong>${escapeHtml(statusLabel(document.status))}</strong></div><div><span>Version</span><strong>${escapeHtml(document.versionLabel)}</strong></div><div><span>Effective in Bahrain</span><strong>${escapeHtml(document.effectiveDateLabel)}</strong></div></div></div><div class="content">${sections}</div><footer class="foot">Generated from Field's canonical policy configuration on ${escapeHtml(document.generatedAtLabel)}. The stored policy version remains the source of truth.</footer></main></body></html>`;
}

function consequenceRule(title: string, explanation: string, refundBps: number, strikeCount: number, extra?: string) {
  return {
    title,
    explanation,
    facts: [`Refund: ${percent(refundBps)}`, `Reliability consequence: ${strikes(strikeCount)}`, ...(extra ? [extra] : [])],
  } satisfies ReliabilityPolicySummaryRule;
}

function outcomeFact(label: string, outcome: { refundBps: number; strikes: number }) {
  return `${label}: ${strikes(outcome.strikes)} and ${percent(outcome.refundBps)} refund`;
}

function sanctionFact(sanction: {
  threshold: number;
  kind: string;
  durationDays: number | null;
}) {
  const duration = sanction.durationDays === null
    ? "indefinite"
    : sanction.durationDays === 0
      ? "immediate warning"
      : `${sanction.durationDays} days`;
  return `${sanction.threshold} active ${sanction.threshold === 1 ? "strike" : "strikes"}: ${humanize(sanction.kind)} (${duration})`;
}

function percent(bps: number) {
  return `${formatNumber(bps / 100)}%`;
}

function strikes(count: number) {
  return `${formatNumber(count)} ${count === 1 ? "strike" : "strikes"}`;
}

function minutesBefore(minutes: number) {
  if (minutes % 60 === 0) return `${formatNumber(minutes / 60)} ${minutes === 60 ? "hour" : "hours"}`;
  return `${formatNumber(minutes)} minutes`;
}

function replacementStep(step: ReliabilityPolicyConfig["replacement"]["order"][number]) {
  switch (step) {
    case "EMERGENCY_NOTIFICATION": return "Notify eligible replacement players.";
    case "ON_FIELD_RESERVE": return "Use the assigned on-field reserve.";
    case "PLAY_SHORTHANDED": return "Record the team as playing short-handed.";
  }
}

function humanList(values: readonly string[]) {
  return new Intl.ListFormat("en", { style: "long", type: "conjunction" })
    .format(values.map(humanize));
}

function humanize(value: string) {
  return value.toLowerCase().replaceAll("_", " ").replace(/^./, (letter) => letter.toUpperCase());
}

function formatNumber(value: number) {
  return new Intl.NumberFormat("en", { maximumFractionDigits: 2 }).format(value);
}

function formatBahrainDate(value: string) {
  return new Intl.DateTimeFormat("en-BH", {
    timeZone: "Asia/Bahrain",
    day: "numeric",
    month: "long",
    year: "numeric",
  }).format(new Date(value));
}

function formatBahrainDateTime(value: Date) {
  return new Intl.DateTimeFormat("en-BH", {
    timeZone: "Asia/Bahrain",
    dateStyle: "medium",
    timeStyle: "short",
  }).format(value);
}

function statusLabel(status: ReliabilityPolicyDocumentStatus) {
  switch (status) {
    case "ACTIVE": return "Active policy";
    case "DRAFT": return "Draft — not in force";
    case "SCHEDULED": return "Published — scheduled";
    case "HISTORICAL": return "Historical version";
  }
}

function escapeHtml(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

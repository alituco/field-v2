"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import type {
  BlueCard,
  FixtureClock,
  FixtureEvent,
  Player,
  RefereeFixture,
  RefereeFixturesResponse,
} from "@/lib/types";

const codeStorageKey = "field_referee_access_code";

export default function RefereePage() {
  const [code, setCode] = useState("");
  const [storedCode, setStoredCode] = useState("");
  const [fixtures, setFixtures] = useState<RefereeFixture[]>([]);
  const [activeFixtureId, setActiveFixtureId] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [now, setNow] = useState(Date.now());
  const [submittingAction, setSubmittingAction] = useState<string | null>(null);
  const [goalClanId, setGoalClanId] = useState("");
  const [goalPlayerId, setGoalPlayerId] = useState("");
  const [assistPlayerId, setAssistPlayerId] = useState("");
  const [cardClanId, setCardClanId] = useState("");
  const [cardPlayerId, setCardPlayerId] = useState("");
  const [alertedCardIds, setAlertedCardIds] = useState<string[]>([]);
  const didLoadStoredCode = useRef(false);

  const activeFixture =
    fixtures.find((fixture) => fixture.id === activeFixtureId) ??
    fixtures[0] ??
    null;

  const loadFixtures = useCallback(
    async (accessCode = storedCode) => {
      if (!accessCode) return;

      setIsLoading(true);
      setError(null);

      try {
        const response = await fetch("/api/referee/fixtures", {
          headers: { "x-referee-code": accessCode },
          cache: "no-store",
        });
        const payload = (await response.json()) as
          | RefereeFixturesResponse
          | { error: string };

        if (!response.ok || "error" in payload) {
          throw new Error(
            "error" in payload ? payload.error : "Could not load fixtures.",
          );
        }

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
    },
    [storedCode],
  );

  useEffect(() => {
    if (didLoadStoredCode.current) return;
    didLoadStoredCode.current = true;
    const savedCode = window.localStorage.getItem(codeStorageKey) ?? "";
    setStoredCode(savedCode);
    setCode(savedCode);
    if (savedCode) void loadFixtures(savedCode);
  }, [loadFixtures]);

  useEffect(() => {
    const interval = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(interval);
  }, []);

  useEffect(() => {
    if (!storedCode) return;
    const interval = window.setInterval(() => void loadFixtures(), 10000);
    return () => window.clearInterval(interval);
  }, [loadFixtures, storedCode]);

  useEffect(() => {
    if (!activeFixture) return;
    const homeClanId = activeFixture.homeClan.id;
    const firstHomePlayer = playersForClan(activeFixture, homeClanId)[0]?.id ?? "";

    setGoalClanId((current) => current || homeClanId);
    setCardClanId((current) => current || homeClanId);
    setGoalPlayerId((current) => current || firstHomePlayer);
    setCardPlayerId((current) => current || firstHomePlayer);
  }, [activeFixture]);

  const expiredCards = useMemo(() => {
    if (!activeFixture) return [];
    return activeFixture.blueCards.filter(
      (card) => card.status === "ACTIVE" && new Date(card.expiresAt).getTime() <= now,
    );
  }, [activeFixture, now]);

  useEffect(() => {
    const freshExpiredCards = expiredCards.filter(
      (card) => !alertedCardIds.includes(card.id),
    );
    if (freshExpiredCards.length === 0) return;

    window.navigator.vibrate?.([220, 120, 220]);
    setAlertedCardIds((current) => [
      ...current,
      ...freshExpiredCards.map((card) => card.id),
    ]);
  }, [alertedCardIds, expiredCards]);

  function saveCode(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const trimmedCode = code.trim();
    window.localStorage.setItem(codeStorageKey, trimmedCode);
    setStoredCode(trimmedCode);
    void loadFixtures(trimmedCode);
  }

  function signOut() {
    window.localStorage.removeItem(codeStorageKey);
    setStoredCode("");
    setCode("");
    setFixtures([]);
    setActiveFixtureId(null);
  }

  async function runAction(
    body: Record<string, string | number | null | undefined>,
  ) {
    if (!activeFixture) return;
    const action = String(body.action ?? "action");
    setSubmittingAction(action);
    setError(null);

    try {
      const response = await fetch(
        `/api/referee/fixtures/${activeFixture.id}/action`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-referee-code": storedCode,
          },
          body: JSON.stringify(body),
        },
      );
      const payload = (await response.json()) as { error?: string };
      if (!response.ok) throw new Error(payload.error ?? "Action failed.");
      await loadFixtures();
    } catch (actionError) {
      setError(
        actionError instanceof Error ? actionError.message : "Action failed.",
      );
    } finally {
      setSubmittingAction(null);
    }
  }

  const goalPlayers = activeFixture
    ? playersForClan(activeFixture, goalClanId || activeFixture.homeClan.id)
    : [];
  const cardPlayers = activeFixture
    ? playersForClan(activeFixture, cardClanId || activeFixture.homeClan.id)
    : [];
  const elapsedSeconds = activeFixture
    ? elapsedFromClock(activeFixture.clock, now)
    : 0;
  const durationSeconds = activeFixture?.clock?.durationSeconds ?? 3600;
  const matchProgress = Math.min(1, elapsedSeconds / durationSeconds);

  if (!storedCode) {
    return (
      <main className="app-shell">
        <div className="content">
          <form className="code-card" onSubmit={saveCode}>
            <div className="brand">
              <div className="rail" />
              <div>
                <h1 className="title">REFEREE</h1>
                <p className="subtitle">FIELD MATCH CONTROL</p>
              </div>
            </div>
            <div style={{ height: 22 }} />
            <label className="field-label" htmlFor="code">
              Access code
            </label>
            <input
              id="code"
              className="input"
              value={code}
              onChange={(event) => setCode(event.target.value)}
              autoComplete="one-time-code"
              inputMode="numeric"
            />
            {error ? <div className="error">{error}</div> : null}
            <div style={{ height: 14 }} />
            <button className="primary-button" type="submit">
              Open Console
            </button>
          </form>
        </div>
      </main>
    );
  }

  return (
    <main className="app-shell">
      <div className="content">
        <header className="topbar">
          <div className="brand">
            <div className="rail" />
            <div>
              <h1 className="title">REFEREE</h1>
              <p className="subtitle">
                {activeFixture ? activeFixture.venue : "NO ACTIVE FIXTURE"}
              </p>
            </div>
          </div>
          <button className="ghost-button" onClick={signOut} type="button">
            Lock
          </button>
        </header>

        {error ? <div className="error">{error}</div> : null}

        {fixtures.length === 0 ? (
          <section className="panel">
            <div className="utility-row">
              <div>
                <h2 className="panel-title">No fixtures</h2>
                <p className="small-text">Scheduled/live matches will show here.</p>
              </div>
              <button
                className="ghost-button"
                disabled={isLoading}
                onClick={() => void loadFixtures()}
                type="button"
              >
                Refresh
              </button>
            </div>
          </section>
        ) : null}

        {fixtures.length > 0 ? (
          <FixtureStrip
            fixtures={fixtures}
            activeFixtureId={activeFixture?.id ?? null}
            onSelect={setActiveFixtureId}
          />
        ) : null}

        {activeFixture ? (
          <>
            <section className="timer-card">
              <div className="score-row">
                <ScoreTeam fixture={activeFixture} clanId={activeFixture.homeClan.id} />
                <div className="score-value">
                  {scoreFor(activeFixture, activeFixture.homeClan.id)}
                  <span style={{ color: "rgba(255,255,255,0.35)" }}>:</span>
                  {scoreFor(activeFixture, activeFixture.awayClan.id)}
                </div>
                <ScoreTeam
                  fixture={activeFixture}
                  clanId={activeFixture.awayClan.id}
                  alignEnd
                />
              </div>
              <div className="clock">
                <div className="clock-time">{formatClock(elapsedSeconds)}</div>
                <div className="clock-state">
                  {activeFixture.clock?.status ?? "NOT_STARTED"}
                </div>
              </div>
              <div className="progress">
                <span style={{ width: `${matchProgress * 100}%` }} />
              </div>
              <div
                className={
                  activeFixture.clock?.status === "RUNNING"
                    ? "control-grid"
                    : "control-grid single"
                }
              >
                {activeFixture.clock?.status === "RUNNING" ? (
                  <button
                    className="ghost-button"
                    disabled={submittingAction !== null}
                    onClick={() => void runAction({ action: "pause" })}
                    type="button"
                  >
                    Pause
                  </button>
                ) : activeFixture.clock?.status === "PAUSED" ? (
                  <button
                    className="primary-button"
                    disabled={submittingAction !== null}
                    onClick={() => void runAction({ action: "resume" })}
                    type="button"
                  >
                    Resume
                  </button>
                ) : (
                  <button
                    className="primary-button"
                    disabled={submittingAction !== null}
                    onClick={() =>
                      void runAction({ action: "start", durationSeconds: 3600 })
                    }
                    type="button"
                  >
                    Start Match
                  </button>
                )}
                {activeFixture.clock?.status === "RUNNING" ? (
                  <button
                    className="danger-button"
                    disabled={submittingAction !== null}
                    onClick={() => void runAction({ action: "finish" })}
                    type="button"
                  >
                    Finish
                  </button>
                ) : null}
              </div>
            </section>

            {expiredCards.length > 0 ? (
              <section className="alert-card">
                <strong>Blue card timer up</strong>
                <div style={{ height: 8 }} />
                <div className="blue-list">
                  {expiredCards.map((card) => (
                    <div className="utility-row" key={card.id}>
                      <span>{playerName(activeFixture, card.profileId)}</span>
                      <button
                        className="dark-button"
                        disabled={submittingAction !== null}
                        onClick={() =>
                          void runAction({
                            action: "expire_blue_card",
                            blueCardId: card.id,
                          })
                        }
                        type="button"
                      >
                        Returned
                      </button>
                    </div>
                  ))}
                </div>
              </section>
            ) : null}

            <section className="panel">
              <div className="panel-heading">
                <h2 className="panel-title">Goal</h2>
                <span className="small-text">{formatMinute(elapsedSeconds)}</span>
              </div>
              <TeamSegment
                fixture={activeFixture}
                selectedClanId={goalClanId || activeFixture.homeClan.id}
                onSelect={(clanId) => {
                  setGoalClanId(clanId);
                  setGoalPlayerId(playersForClan(activeFixture, clanId)[0]?.id ?? "");
                  setAssistPlayerId("");
                }}
              />
              <div className="form-grid">
                <PlayerSelect
                  id="scorer"
                  label="Scorer"
                  value={goalPlayerId}
                  players={goalPlayers}
                  onChange={setGoalPlayerId}
                />
                <PlayerSelect
                  id="assist"
                  label="Assist"
                  value={assistPlayerId}
                  players={goalPlayers.filter((player) => player.id !== goalPlayerId)}
                  onChange={setAssistPlayerId}
                  optional
                />
                <button
                  className="primary-button"
                  disabled={!goalPlayerId || submittingAction !== null}
                  onClick={() =>
                    void runAction({
                      action: "goal",
                      clanId: goalClanId || activeFixture.homeClan.id,
                      profileId: goalPlayerId,
                      assistProfileId: assistPlayerId || null,
                    })
                  }
                  type="button"
                >
                  Record Goal
                </button>
              </div>
            </section>

            <section className="panel">
              <div className="panel-heading">
                <h2 className="panel-title">Blue Cards</h2>
                <span className="small-text">2:00 timeout</span>
              </div>
              <TeamSegment
                fixture={activeFixture}
                selectedClanId={cardClanId || activeFixture.homeClan.id}
                onSelect={(clanId) => {
                  setCardClanId(clanId);
                  setCardPlayerId(playersForClan(activeFixture, clanId)[0]?.id ?? "");
                }}
              />
              <div className="form-grid">
                <PlayerSelect
                  id="card-player"
                  label="Player"
                  value={cardPlayerId}
                  players={cardPlayers}
                  onChange={setCardPlayerId}
                />
                <button
                  className="dark-button"
                  disabled={!cardPlayerId || submittingAction !== null}
                  onClick={() =>
                    void runAction({
                      action: "blue_card",
                      clanId: cardClanId || activeFixture.homeClan.id,
                      profileId: cardPlayerId,
                    })
                  }
                  type="button"
                >
                  Start Blue Card
                </button>
              </div>

              <div style={{ height: 14 }} />
              <ActiveBlueCards
                cards={activeFixture.blueCards}
                fixture={activeFixture}
                now={now}
              />
            </section>

            <section className="panel">
              <div className="panel-heading">
                <h2 className="panel-title">Timeline</h2>
                <button
                  className="ghost-button"
                  disabled={isLoading}
                  onClick={() => void loadFixtures()}
                  type="button"
                >
                  Refresh
                </button>
              </div>
              <EventList fixture={activeFixture} />
            </section>
          </>
        ) : null}
      </div>
    </main>
  );
}

function FixtureStrip({
  fixtures,
  activeFixtureId,
  onSelect,
}: {
  fixtures: RefereeFixture[];
  activeFixtureId: string | null;
  onSelect: (fixtureId: string) => void;
}) {
  return (
    <div className="fixture-strip">
      {fixtures.map((fixture) => (
        <button
          className={`fixture-card ${fixture.id === activeFixtureId ? "active" : ""}`}
          key={fixture.id}
          onClick={() => onSelect(fixture.id)}
          type="button"
        >
          <div className="fixture-meta">
            <span>{fixture.matchDate}</span>
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
        {clan.skillRating} SR
      </div>
    </div>
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
  id,
  label,
  value,
  players,
  onChange,
  optional = false,
}: {
  id: string;
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
        id={id}
        value={value}
        onChange={(event) => onChange(event.target.value)}
      >
        {optional ? <option value="">No assist</option> : null}
        {players.map((player) => (
          <option key={player.id} value={player.id}>
            {player.displayName}
          </option>
        ))}
      </select>
    </label>
  );
}

function ActiveBlueCards({
  cards,
  fixture,
  now,
}: {
  cards: BlueCard[];
  fixture: RefereeFixture;
  now: number;
}) {
  const activeCards = cards.filter((card) => card.status === "ACTIVE");

  if (activeCards.length === 0) {
    return <div className="empty">No active blue cards</div>;
  }

  return (
    <div className="blue-list">
      {activeCards.map((card) => {
        const remaining = Math.max(
          0,
          Math.ceil((new Date(card.expiresAt).getTime() - now) / 1000),
        );
        const expired = remaining === 0;
        return (
          <div
            className={`blue-card-row ${expired ? "expired" : ""}`}
            key={card.id}
          >
            <div>
              <div className="event-title">{playerName(fixture, card.profileId)}</div>
              <div className="event-subtitle">
                {clanTag(fixture, card.clanId)} at {card.minute}'
              </div>
            </div>
            <div className={`countdown ${expired ? "expired" : ""}`}>
              {formatClock(remaining)}
            </div>
          </div>
        );
      })}
    </div>
  );
}

function EventList({ fixture }: { fixture: RefereeFixture }) {
  if (fixture.events.length === 0) {
    return <div className="empty">No events recorded</div>;
  }

  return (
    <div className="event-list">
      {fixture.events.map((event) => (
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
  if (event.eventType === "GOAL") {
    return `Goal: ${playerName(fixture, event.profileId)}`;
  }
  if (event.eventType === "BLUE_CARD") {
    return `Blue card: ${playerName(fixture, event.profileId)}`;
  }
  if (event.eventType === "BLUE_CARD_EXPIRED") {
    return `Returned: ${playerName(fixture, event.profileId)}`;
  }
  return event.eventType.replaceAll("_", " ");
}

function eventSubtitle(fixture: RefereeFixture, event: FixtureEvent) {
  const team = event.clanId ? clanTag(fixture, event.clanId) : "Match";
  if (event.eventType === "GOAL" && event.assistProfileId) {
    return `${team}, assist ${playerName(fixture, event.assistProfileId)}`;
  }
  return team;
}

function playersForClan(fixture: RefereeFixture, clanId: string) {
  return fixture.players.filter((player) => player.clanId === clanId);
}

function scoreFor(fixture: RefereeFixture, clanId: string) {
  return fixture.goals.filter((goal) => goal.clanId === clanId).length;
}

function playerName(fixture: RefereeFixture, profileId: string | null) {
  if (!profileId) return "Unknown player";
  return (
    fixture.players.find((player) => player.id === profileId)?.displayName ??
    "Unknown player"
  );
}

function clanTag(fixture: RefereeFixture, clanId: string) {
  if (fixture.homeClan.id === clanId) return fixture.homeClan.tag;
  if (fixture.awayClan.id === clanId) return fixture.awayClan.tag;
  return "TEAM";
}

function elapsedFromClock(clock: FixtureClock | null, now: number) {
  if (!clock) return 0;
  if (clock.status !== "RUNNING" || !clock.startedAt) {
    return Math.max(0, clock.accumulatedSeconds);
  }

  const startedAt = new Date(clock.startedAt).getTime();
  return Math.max(0, clock.accumulatedSeconds + Math.floor((now - startedAt) / 1000));
}

function formatClock(totalSeconds: number) {
  const safeSeconds = Math.max(0, Math.floor(totalSeconds));
  const minutes = Math.floor(safeSeconds / 60);
  const seconds = safeSeconds % 60;
  return `${minutes}:${seconds.toString().padStart(2, "0")}`;
}

function formatMinute(totalSeconds: number) {
  const minute = Math.floor(Math.max(0, totalSeconds) / 60);
  return `${minute}:${(Math.max(0, totalSeconds) % 60).toString().padStart(2, "0")}`;
}

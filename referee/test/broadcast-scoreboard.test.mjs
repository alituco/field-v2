import assert from 'node:assert/strict';
import test from 'node:test';

import { deriveScoreboard } from '../public/broadcast-scoreboard.mjs';

const nowMs = Date.parse('2026-10-20T03:00:00.000Z');
const isoBefore = seconds => new Date(nowMs - seconds * 1000).toISOString();
const isoAfter = seconds => new Date(nowMs + seconds * 1000).toISOString();

function payload(overrides = {}) {
  return {
    home: { name: 'White Team', tag: 'white' },
    away: { name: 'Black Team', tag: 'black' },
    homeScore: 2,
    awayScore: 1,
    fixtureStatus: 'LIVE',
    clock: {
      status: 'RUNNING', started_at: isoBefore(34),
      accumulated_seconds: 25 * 60, duration_seconds: 3600,
    },
    serverTime: new Date(nowMs).toISOString(),
    scheduledStart: '2026-10-20T03:30:00.000Z',
    timeZone: 'America/Phoenix',
    halftimePaused: false,
    latestGoal: null,
    ...overrides,
  };
}

function goal(overrides = {}) {
  return {
    id: 'goal-1', createdAt: isoBefore(2), minute: 25,
    scorerName: 'Ali A.', team: 'HOME', ...overrides,
  };
}

test('running clock uses the passed time, uppercase tags, and first-half state', () => {
  const input = payload();
  const output = deriveScoreboard(input, nowMs);
  assert.equal(output.homeLabel, 'WHITE');
  assert.equal(output.awayLabel, 'BLACK');
  assert.equal(output.homeScore, '2');
  assert.equal(output.awayScore, '1');
  assert.equal(output.clockText, '25:34');
  assert.equal(output.statusText, '1ST HALF');
  assert.equal(output.variant, 'clock');
  assert.equal(output.goalSide, null);
  assert.equal(output.showLiveDot, true);
  assert.equal(deriveScoreboard(input, nowMs + 1000).clockText, '25:35');
});

test('second-half selection uses configured duration or an explicit halfway point', () => {
  const clock = { status: 'RUNNING', started_at: isoBefore(10), accumulated_seconds: 1790, duration_seconds: 3600 };
  const second = deriveScoreboard(payload({ clock }), nowMs);
  assert.equal(second.clockText, '30:00');
  assert.equal(second.statusText, '2ND HALF');
  assert.equal(deriveScoreboard(payload({ clock: { ...clock, accumulated_seconds: 1190, duration_seconds: 2400 } }), nowMs).statusText, '2ND HALF');
  assert.equal(deriveScoreboard(payload({ clock: { ...clock, accumulated_seconds: 1190 }, halftimeSeconds: 1200 }), nowMs).statusText, '2ND HALF');
});

test('ordinary pause freezes actual elapsed time even if started_at is stale', () => {
  const output = deriveScoreboard(payload({
    clock: { status: 'PAUSED', started_at: isoBefore(600), accumulated_seconds: 1645, duration_seconds: 3600 },
  }), nowMs);
  assert.equal(output.clockText, '27:25');
  assert.equal(output.statusText, 'PAUSED');
  assert.equal(output.variant, 'paused');
  assert.equal(output.showLiveDot, false);
});

test('half-time requires the authoritative break flag and beats a fresh goal', () => {
  const paused = payload({
    clock: { status: 'PAUSED', started_at: null, accumulated_seconds: 1800, duration_seconds: 3600 },
    halftimePaused: true,
    latestGoal: goal(),
  });
  const halftime = deriveScoreboard(paused, nowMs);
  assert.equal(halftime.clockText, '30:00');
  assert.equal(halftime.statusText, 'HT');
  assert.equal(halftime.variant, 'halftime');
  assert.equal(halftime.goalSide, null);
  assert.equal(halftime.showLiveDot, false);
  const ordinary = deriveScoreboard({ ...paused, halftimePaused: false, latestGoal: null }, nowMs);
  assert.equal(ordinary.statusText, 'PAUSED');
  assert.equal(ordinary.variant, 'paused');
});

test('full time has priority over goal and half-time state and keeps recorded added time', () => {
  const output = deriveScoreboard(payload({
    fixtureStatus: 'FINAL', halftimePaused: true, latestGoal: goal(),
    clock: { status: 'ENDED', started_at: isoBefore(500), accumulated_seconds: 3865, duration_seconds: 3600 },
  }), nowMs);
  assert.equal(output.clockText, '64:25');
  assert.equal(output.statusText, 'FT');
  assert.equal(output.variant, 'ended');
  assert.equal(output.goalSide, null);
  assert.equal(output.showLiveDot, false);
  assert.equal(deriveScoreboard(payload({ clock: { status: 'ENDED', accumulated_seconds: 3600, duration_seconds: 3600 } }), nowMs).variant, 'ended');
});

test('live elapsed time can exceed match duration and is safely capped at three hours', () => {
  const overtime = deriveScoreboard(payload({
    clock: { status: 'RUNNING', started_at: isoBefore(60), accumulated_seconds: 3600, duration_seconds: 3600 },
  }), nowMs);
  assert.equal(overtime.clockText, '61:00');
  assert.equal(overtime.variant, 'clock');
  assert.equal(overtime.statusText, '2ND HALF');
  const capped = deriveScoreboard(payload({
    clock: { status: 'RUNNING', started_at: isoBefore(10000), accumulated_seconds: 10000, duration_seconds: 3600 },
  }), nowMs);
  assert.equal(capped.clockText, '180:00');
});

test('pre-kickoff displays scheduled Phoenix time and cannot announce an old goal', () => {
  const output = deriveScoreboard(payload({
    fixtureStatus: 'SCHEDULED', latestGoal: goal(),
    clock: { status: 'NOT_STARTED', started_at: null, accumulated_seconds: 0, duration_seconds: 3600 },
  }), nowMs);
  assert.equal(output.clockText, '8:30PM');
  assert.equal(output.statusText, 'KICKOFF');
  assert.equal(output.variant, 'kickoff');
  assert.equal(output.goalSide, null);
  assert.equal(output.showLiveDot, false);
});

test('fresh goals show exact scorer and minute copy for the actual side', () => {
  for (const team of ['HOME', 'AWAY']) {
    const output = deriveScoreboard(payload({ latestGoal: goal({ team }) }), nowMs);
    assert.equal(output.statusText, 'GOAL Ali A. 25′');
    assert.equal(output.variant, 'goal');
    assert.equal(output.goalSide, team);
    assert.equal(output.showLiveDot, false);
  }
  const pausedGoal = deriveScoreboard(payload({
    latestGoal: goal(),
    clock: { status: 'PAUSED', started_at: null, accumulated_seconds: 1500, duration_seconds: 3600 },
  }), nowMs);
  assert.equal(pausedGoal.variant, 'goal');
});

test('goal expiry is anchored to createdAt and score changes cannot restart it', () => {
  const input = payload({ latestGoal: goal({ createdAt: isoBefore(7.999) }) });
  assert.equal(deriveScoreboard(input, nowMs).variant, 'goal');
  const expired = deriveScoreboard(input, nowMs + 2);
  assert.equal(expired.variant, 'clock');
  assert.equal(expired.goalSide, null);
  const scoreChanged = deriveScoreboard({ ...input, homeScore: 3 }, nowMs + 1000);
  assert.equal(scoreChanged.variant, 'clock');
  assert.equal(scoreChanged.homeScore, '3');
  assert.equal(deriveScoreboard(payload({ homeScore: 10 }), nowMs).variant, 'clock');
});

test('goal timestamps tolerate small clock skew but reject a materially future event', () => {
  assert.equal(deriveScoreboard(payload({ latestGoal: goal({ createdAt: isoAfter(4) }) }), nowMs).variant, 'goal');
  const future = deriveScoreboard(payload({ latestGoal: goal({ createdAt: isoAfter(6) }) }), nowMs);
  assert.equal(future.variant, 'clock');
  assert.equal(future.goalSide, null);
});

test('malformed goal identity, date, and side cannot create a goal announcement', () => {
  for (const invalid of [
    goal({ id: '' }), goal({ id: null }), goal({ createdAt: 'bad-date' }),
    goal({ createdAt: null }), goal({ team: 'WHITE' }), goal({ team: 'OTHER' }),
    goal({ team: null }), {}, 'goal', 42,
  ]) {
    const output = deriveScoreboard(payload({ latestGoal: invalid }), nowMs);
    assert.equal(output.variant, 'clock', JSON.stringify(invalid));
    assert.equal(output.goalSide, null);
    assert.doesNotMatch(output.statusText, /NaN|undefined|\[object Object\]/);
  }
});

test('team labels prefer trimmed tags and fall back to uppercase names', () => {
  const output = deriveScoreboard(payload({
    home: { name: 'White Team', tag: '  whi  ' },
    away: { name: 'The Devils', tag: '   ' },
  }), nowMs);
  assert.equal(output.homeLabel, 'WHI');
  assert.equal(output.awayLabel, 'THE DEVILS');
});

test('malformed goal names and minutes never leak implementation strings', () => {
  for (const change of [
    { scorerName: undefined }, { scorerName: null }, { scorerName: {} },
    { minute: NaN }, { minute: Infinity }, { minute: -7 }, { minute: 'bad-value' },
  ]) {
    const output = deriveScoreboard(payload({ latestGoal: goal(change) }), nowMs);
    assert.equal(typeof output.statusText, 'string');
    assert.doesNotMatch(output.statusText, /NaN|Infinity|undefined|\[object Object\]|-\d+′/);
  }
});

test('scores are safe finite nonnegative integer strings capped at 999', () => {
  for (const value of [-1, NaN, Infinity, -Infinity, 'invalid', undefined, null]) {
    const output = deriveScoreboard(payload({ homeScore: value, awayScore: value }), nowMs);
    assert.equal(output.homeScore, '0', String(value));
    assert.equal(output.awayScore, '0', String(value));
  }
  const output = deriveScoreboard(payload({ homeScore: '3.9', awayScore: 10000 }), nowMs);
  assert.equal(output.homeScore, '3');
  assert.equal(output.awayScore, '999');
});

test('malformed clock numbers never render NaN, negative values, or an invalid date', () => {
  for (const accumulated_seconds of [-30, NaN, Infinity, 'bad-value', null]) {
    const output = deriveScoreboard(payload({ clock: {
      status: 'RUNNING', started_at: 'not-a-date', accumulated_seconds,
      duration_seconds: 'bad-value',
    } }), nowMs);
    assert.equal(output.clockText, '00:00');
    assert.doesNotMatch(output.clockText + output.statusText, /NaN|Infinity|Invalid|-/);
  }
  const futureStart = deriveScoreboard(payload({ clock: {
    status: 'RUNNING', started_at: isoAfter(60), accumulated_seconds: 1500, duration_seconds: 3600,
  } }), nowMs);
  assert.equal(futureStart.clockText, '25:00');
});

test('projection does not mutate a shared overlay payload', () => {
  const input = payload({ latestGoal: goal() });
  Object.freeze(input.home); Object.freeze(input.away); Object.freeze(input.clock);
  Object.freeze(input.latestGoal); Object.freeze(input);
  const before = JSON.stringify(input);
  assert.doesNotThrow(() => deriveScoreboard(input, nowMs));
  assert.equal(JSON.stringify(input), before);
});

test('missing schedule stays blank and unknown team labels stay honest', () => {
  const output = deriveScoreboard(payload({
    home: null, away: { name: '', tag: '' }, scheduledStart: null,
    fixtureStatus: 'SCHEDULED',
    clock: { status: 'NOT_STARTED', started_at: null, accumulated_seconds: 0, duration_seconds: 3600 },
  }), nowMs);
  assert.equal(output.homeLabel, 'TBD');
  assert.equal(output.awayLabel, 'TBD');
  assert.equal(output.clockText, '');
  assert.equal(output.statusText, 'KICKOFF');
  assert.equal(output.variant, 'kickoff');
});

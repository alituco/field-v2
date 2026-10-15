// Pure SQL normalization/calculation integration in an isolated PostgreSQL
// runtime; no Supabase connection, tables, settlement, or production dependency.
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite \
//   node supabase/scripts/test_season_zero_sr_timeline.mjs
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import assert from 'node:assert/strict';

const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const prefix = 'fieldrush_rating_private.';
let scenarios = 0;
let invalidChecks = 0;
let permissions = 0;
let eventId = 0;
const epoch = Date.parse('2026-10-14T12:00:00Z');
function event(type, second, player_id = null, wallSecond = second) {
  return {id: `e${++eventId}`, type, second, player_id, recorded_at: new Date(epoch + wallSecond * 1000).toISOString()};
}
function match(a = 7, b = 7, overrides = {}) {
  return {
    policy_id: 'field-sr-season0-v2', status: 'completed', winner: 'A', scheduled_seconds: 3600, played_seconds: 3600,
    roster: ['A', 'B'].flatMap(team => Array.from({length: team === 'A' ? a : b}, (_, i) => ({
      id: `${team}${i + 1}`, team, sr_before: 1000, games_before: 10, initial_active: true,
    }))), events: [], ...overrides,
  };
}
function person(input, id) { return input.roster.find(p => p.id === id); }
function near(actual, expected, label = '') { assert.ok(Math.abs(actual - expected) < 1e-9, `${label}: ${actual} != ${expected}`); }
async function scalar(sql, values = []) { return Object.values((await db.query(sql, values)).rows[0])[0]; }
async function normalize(input) { return scalar(`select ${prefix}normalize_season_zero_sr($1::jsonb)`, [JSON.stringify(input)]); }
async function evaluate(input) {
  const {rows} = await db.query(`with n as materialized (select ${prefix}normalize_season_zero_sr($1::jsonb) normalized)
    select normalized, ${prefix}calculate_season_zero_sr(normalized->'core') result from n`, [JSON.stringify(input)]);
  return {...rows[0].normalized, result: rows[0].result};
}
async function scenario(name, input, check) {
  try {
    const before = JSON.stringify(input);
    const result = await evaluate(input);
    await check(result);
    assert.equal(JSON.stringify(input), before, 'Caller input not mutated');
    scenarios++;
  } catch (error) { error.message = `${name}: ${error.message}`; throw error; }
}
async function invalid(name, mutate, base = match()) {
  mutate(base);
  await assert.rejects(normalize(base), error => error.code === '22023', name);
  invalidChecks++;
}

try {
  await db.exec('create schema fieldrush_rating_private; create role anon; create role authenticated; create role service_role;');
  for (const file of ['20261014001000_season_zero_sr_calculator.sql', '20261014001200_season_zero_sr_timeline.sql']) {
    await db.exec(await readFile(new URL(`../migrations/${file}`, import.meta.url), 'utf8'));
  }
  for (const size of [5, 6, 7]) await scenario(`equal ${size}v${size}`, match(size, size), ({core, audit, result}) => {
    assert.equal(core.average_count_difference_a, 0);
    assert.deepEqual(core.team_strengths, {A: 1000, B: 1000});
    assert.equal(audit.intervals.length, 1);
    assert.equal(audit.team_rating_weights.A, size * 3600);
    for (const p of Object.values(result.players)) assert.equal(Math.abs(p.delta), 20);
  });
  for (const [a, b, win, loss] of [[6, 7, 26, -2], [5, 6, 26, -2], [5, 7, 30, -1]]) {
    await scenario(`${a}v${b} smaller win`, match(a, b), ({core, audit, result}) => {
      assert.equal(core.average_count_difference_a, a - b);
      assert.equal(audit.players.A1.protected_seconds, 3600);
      assert.equal(result.players.A1.delta, win);
      assert.equal(result.players.B1.delta, -win);
    });
    await scenario(`${a}v${b} larger win`, match(a, b, {winner: 'B'}), ({result}) => {
      assert.equal(result.players.A1.delta, loss);
      assert.equal(result.players.A1.loss_multiplier, 0.15);
    });
  }
  const moved = match();
  person(moved, 'A6').initial_active = false;
  person(moved, 'A7').initial_active = false;
  person(moved, 'B7').team = 'A';
  person(moved, 'A7').team = 'B';
  moved.events = [event('JOIN', 1800, 'A6'), event('JOIN', 1800, 'A7')];
  await scenario('pre-kickoff transfer and absent slot exchange', moved, ({audit, core}) => {
    assert.deepEqual(audit.assigned_players, {A: 7, B: 7});
    assert.deepEqual(audit.intervals.map(i => i.actual), [{A: 6, B: 6}, {A: 7, B: 7}]);
    assert.equal(core.average_count_difference_a, 0);
  });
  const noShow = match();
  Object.assign(person(noShow, 'A7'), {initial_active: false, sr_before: 1000000});
  await scenario('no-show has no weight, SR or count', noShow, ({core, audit, result}) => {
    assert.equal(core.team_strengths.A, 1000);
    assert.equal(audit.players.A7.rating_weight, 0);
    assert.equal(result.players.A7.delta, 0);
    assert.equal(result.players.A7.counted, false);
  });
  for (const seconds of [599, 600]) {
    const late = match();
    Object.assign(person(late, 'A7'), {initial_active: false, sr_before: 2000});
    late.events = [event('JOIN', 3600 - seconds, 'A7')];
    await scenario(`late ${seconds} seconds`, late, ({core, audit, result}) => {
      assert.equal(audit.players.A7.actual_seconds, seconds);
      assert.equal(audit.players.A7.protected_seconds, 0);
      near(core.team_strengths.A, (21600000 + 2000 * seconds) / (21600 + seconds));
      assert.equal(result.players.A7.counted, seconds === 600);
      if (seconds === 599) assert.equal(result.players.A7.delta, 0);
    });
    const accumulated = match();
    accumulated.events = [event('EXCUSED_LEAVE', 300, 'A7'), event('RETURN', 900, 'A7'), event('EXCUSED_LEAVE', 900 + seconds - 300, 'A7')];
    await scenario(`cumulative excused participation ${seconds}`, accumulated, ({audit, result}) => {
      assert.equal(audit.players.A7.actual_seconds, seconds);
      assert.equal(result.players.A7.counted, seconds === 600);
    });
  }
  for (const [seconds, loss] of [[600, -16], [1800, -10], [3600, -2]]) {
    const partial = match(7, 7, {winner: 'B'});
    person(partial, 'A7').initial_active = false;
    if (seconds < 3600) partial.events = [event('JOIN', seconds, 'A7')];
    await scenario(`partial disadvantage ${seconds}`, partial, ({core, audit, result}) => {
      near(core.average_count_difference_a, -seconds / 3600);
      assert.equal(audit.players.A1.protected_seconds, seconds);
      assert.equal(result.players.A1.delta, loss);
    });
  }
  const injuryEqual = match(6, 7, {winner: 'B', events: [event('EXCUSED_LEAVE', 1800, 'B7')]});
  await scenario('6v7 becomes 6v6 through injury', injuryEqual, ({core, audit}) => {
    assert.equal(core.average_count_difference_a, -0.5);
    assert.equal(audit.players.A1.protected_seconds, 1800);
    assert.equal(audit.players.B7.retained_seconds, 0);
  });
  const switching = match();
  person(switching, 'A7').initial_active = false;
  switching.events = [event('EXCUSED_LEAVE', 1200, 'B7'), event('JOIN', 2400, 'A7')];
  await scenario('advantage switches sides without erasing exposure', switching, ({core, audit, result}) => {
    assert.equal(core.average_count_difference_a, 0);
    assert.equal(audit.players.A1.protected_seconds, 1200);
    assert.equal(audit.players.B1.protected_seconds, 1200);
    assert.equal(result.players.A1.delta, 20);
    assert.equal(result.players.B1.delta, -14);
  });
  const switchedLabels = structuredClone(switching);
  switchedLabels.winner = 'B';
  for (const p of switchedLabels.roster) p.team = p.team === 'A' ? 'B' : 'A';
  await scenario('team-label symmetry', switchedLabels, async ({core, result}) => {
    const original = await evaluate(switching);
    near(core.average_count_difference_a, -original.core.average_count_difference_a);
    for (const id of Object.keys(result.players)) assert.equal(result.players[id].delta, original.result.players[id].delta);
  });
  await scenario('injury and return', match(7, 7, {winner: 'B', events: [event('EXCUSED_LEAVE', 1200, 'A7'), event('RETURN', 2400, 'A7')]}), ({core, audit, result}) => {
    near(core.average_count_difference_a, -1 / 3);
    assert.equal(audit.players.A7.actual_seconds, 2400);
    assert.equal(audit.players.A7.protected_seconds, 0);
    assert.equal(result.players.A7.delta, -18);
    assert.equal(result.players.A1.delta, -13);
  });
  for (const winner of ['A', 'B']) await scenario(`quit team ${winner === 'A' ? 'win' : 'loss'}`, match(7, 7, {winner, events: [event('QUIT', 1800, 'A7')]}), ({core, audit, result}) => {
    assert.equal(core.average_count_difference_a, 0);
    assert.equal(audit.players.A7.actual_seconds, 1800);
    assert.equal(audit.players.A7.retained_seconds, 1800);
    assert.equal(audit.players.A1.protected_seconds, 0);
    assert.equal(result.players.A7.delta, winner === 'A' ? 0 : -20);
    assert.equal(result.players.A7.counted, true);
  });
  for (const rating of [0, 2000]) {
    const quitter = match(7, 7, {events: [event('QUIT', 1800, 'A7')]});
    person(quitter, 'A7').sr_before = rating;
    await scenario(`${rating === 0 ? 'weak' : 'strong'} quitter retained in mean`, quitter, async ({core}) => {
      near(core.team_strengths.A, (6000 + rating) / 7);
      const staying = structuredClone(quitter); staying.events = [];
      near(core.team_strengths.A, (await evaluate(staying)).core.team_strengths.A);
    });
  }
  await scenario('opponent quit stops actual exposure but preserves accounting', match(6, 7, {winner: 'B', events: [event('QUIT', 1800, 'B7')]}), ({core, audit, result}) => {
    assert.equal(core.average_count_difference_a, -1);
    assert.equal(audit.players.A1.protected_seconds, 1800);
    assert.equal(result.players.A1.delta, -8);
    assert.equal(result.players.B1.delta, 14);
    assert.equal(result.players.B7.delta, 0);
  });
  await scenario('own quit preserves prior disadvantage only', match(6, 7, {winner: 'B', events: [event('QUIT', 1800, 'A6')]}), ({core, audit, result}) => {
    assert.equal(core.average_count_difference_a, -1);
    assert.equal(audit.players.A1.protected_seconds, 3600);
    assert.equal(audit.players.A6.protected_seconds, 1800);
    assert.equal(result.players.A1.delta, -2);
    assert.equal(result.players.A6.delta, -14);
    assert.equal(result.players.A6.loss_multiplier, 1);
  });
  for (const type of ['RED_CARD', 'BLUE_CARD']) {
    await scenario(`${type} eligible prior exposure`, match(6, 7, {winner: 'B', events: [event(type, 1800, 'A6')]}), ({result}) => {
      assert.equal(result.players.A6.delta, -8);
      assert.equal(result.players.A6.counted, true);
    });
    await scenario(`${type} eligible win`, match(7, 7, {events: [event(type, 1800, 'A7')]}), ({result}) => {
      assert.equal(result.players.A7.delta, 20);
      assert.equal(result.players.A7.counted, true);
    });
    for (const winner of ['A', 'B']) await scenario(`${type} short ${winner}`, match(7, 7, {winner, events: [event(type, 599, 'A7')]}), ({result}) => {
      assert.equal(result.players.A7.delta, winner === 'A' ? 0 : -20);
      assert.equal(result.players.A7.counted, false);
    });
  }
  await scenario('ordinary short injury is not conduct penalty', match(7, 7, {winner: 'B', events: [event('EXCUSED_LEAVE', 599, 'A7')]}), ({result}) => {
    assert.equal(result.players.A7.delta, 0);
    assert.equal(result.players.A7.counted, false);
  });
  const preEntryRed = match();
  person(preEntryRed, 'A7').initial_active = false;
  preEntryRed.events = [event('RED_CARD', 600, 'A7')];
  await scenario('pre-entry red card never creates a ghost', preEntryRed, ({audit, result}) => {
    assert.equal(audit.players.A7.rating_weight, 0);
    assert.equal(result.players.A7.delta, 0);
    assert.equal(result.players.A7.counted, false);
  });
  await scenario('kickoff conduct before any actual play never creates a ghost', match(7, 7, {events: [event('QUIT', 0, 'A7')]}), ({core, audit, result}) => {
    assert.equal(core.average_count_difference_a, -1);
    assert.equal(audit.players.A7.rating_weight, 0);
    assert.equal(result.players.A7.delta, 0);
  });
  for (const seconds of [599, 600, 1800]) {
    const forfeit = match(5, 7, {status: 'forfeit_confirmed', winner: 'B', played_seconds: seconds,
      events: [event('QUIT', seconds, 'A5'), event('PAUSE', seconds)]});
    await scenario(`conduct forfeit ${seconds}s`, forfeit, ({audit, result}) => {
      assert.equal(audit.intervals.length, 1);
      assert.equal(audit.final_clock_state, 'PAUSED');
      assert.equal(result.settlement, seconds < 600 ? 'NOT_RATED' : 'RATED');
      if (seconds >= 600) {
        assert.equal(result.protection_denominator, 3600);
        near(result.players.A1.q, seconds / 3600);
        assert.equal(result.players.A5.loss_multiplier, 1);
      } else for (const p of Object.values(result.players)) assert.equal(p.counted, false);
    });
  }
  for (const status of ['no_contest', 'cancelled', 'unranked', 'pending_review']) {
    await scenario(`interrupted ${status} no rating`, match(5, 7, {status, played_seconds: 600,
      events: [event('EXCUSED_LEAVE', 600, 'A5'), event('PAUSE', 600)]}), ({result}) => {
      assert.equal(result.settlement, status === 'pending_review' ? 'HELD' : 'NOT_RATED');
      for (const p of Object.values(result.players)) { assert.equal(p.delta, 0); assert.equal(p.counted, false); }
    });
    const neverStarted = match(7, 7, {status, played_seconds: 0});
    for (const p of neverStarted.roster) p.initial_active = false;
    await scenario(`never started ${status}`, neverStarted, ({core, audit, result}) => {
      assert.deepEqual(core.team_strengths, {A: 0, B: 0});
      assert.equal(audit.intervals.length, 0);
      assert.equal(result.settlement, status === 'pending_review' ? 'HELD' : 'NOT_RATED');
    });
  }
  const simultaneous = match(6, 7);
  person(simultaneous, 'A6').initial_active = false;
  simultaneous.events = [event('EXCUSED_LEAVE', 600, 'A5'), event('JOIN', 600, 'A6')];
  await scenario('same-second departure and arrival never creates 4v7 interval', simultaneous, ({audit, core}) => {
    assert.equal(audit.intervals.length, 2);
    assert.ok(audit.intervals.every(i => i.actual.A === 5));
    assert.equal(core.average_count_difference_a, -2);
  });
  await scenario('halftime pause adds no participation time', match(7, 7, {events: [event('PAUSE', 1800), event('RESUME', 1800, null, 2400)]}), ({audit}) => {
    assert.equal(audit.players.A1.actual_seconds, 3600);
    assert.equal(audit.players.A1.rating_weight, 3600);
  });
  await scenario('blue card while running retains rating only', match(7, 7, {events: [event('BLUE_CARD', 1200, 'A7'), event('BLUE_RETURN', 1320, 'A7')]}), ({core, audit, result}) => {
    assert.equal(core.average_count_difference_a, 0);
    assert.equal(audit.players.A7.actual_seconds, 3480);
    assert.equal(audit.players.A7.retained_seconds, 120);
    assert.equal(audit.players.A7.rating_weight, 3600);
    assert.equal(audit.players.A1.protected_seconds, 0);
    assert.equal(audit.players.A7.exit_reason, 'BLUE_CARD');
    assert.equal(audit.players.A7.final_state, 'ACTIVE');
    assert.equal(result.players.A7.delta, 20);
  });
  await scenario('4v7 blue-card pause and confirmed wall-clock return', match(5, 7, {events: [
    event('BLUE_CARD', 600, 'A5'), event('PAUSE', 600), event('BLUE_RETURN', 600, 'A5', 720), event('RESUME', 600, null, 720),
  ]}), ({audit, core}) => {
    assert.equal(audit.players.A5.actual_seconds, 3600);
    assert.equal(audit.players.A5.retained_seconds, 0);
    assert.equal(audit.players.A5.exit_reason, 'BLUE_CARD');
    assert.ok(audit.intervals.every(i => i.actual.A === 5));
    assert.equal(core.average_count_difference_a, -2);
  });
  for (const [join, card, returned, actual] of [[3001, 3300, 3420, 479], [2880, 3180, 3300, 600]]) {
    const input = match(7, 7, {winner: 'B'});
    person(input, 'A7').initial_active = false;
    input.events = [event('JOIN', join, 'A7'), event('BLUE_CARD', card, 'A7'), event('BLUE_RETURN', returned, 'A7')];
    await scenario(`blue history after return with ${actual} actual seconds`, input, ({audit, result}) => {
      assert.equal(audit.players.A7.actual_seconds, actual);
      assert.equal(audit.players.A7.exit_reason, 'BLUE_CARD');
      assert.equal(audit.players.A7.final_state, 'ACTIVE');
      assert.equal(result.players.A7.counted, actual >= 600);
      assert.ok(result.players.A7.delta < 0);
    });
  }
  await scenario('existing disadvantage excludes blue off-field exposure', match(6, 7, {events: [event('BLUE_CARD', 1200, 'A6'), event('BLUE_RETURN', 1320, 'A6')]}), ({core, audit}) => {
    assert.equal(core.average_count_difference_a, -1);
    assert.equal(audit.players.A1.protected_seconds, 3600);
    assert.equal(audit.players.A6.protected_seconds, 3480);
  });
  await scenario('integer duration boundary uses numeric aggregate weights', match(7, 7, {scheduled_seconds: 2147483647, played_seconds: 2147483647}), ({audit}) => {
    assert.equal(audit.players.A1.actual_seconds, 2147483647);
    assert.equal(audit.team_rating_weights.A, 7 * 2147483647);
  });

  const mutations = [
    ['bad policy', x => x.policy_id = 'old'], ['unknown status', x => x.status = 'unknown'],
    ['missing winner', x => delete x.winner],
    ['missing roster', x => delete x.roster], ['nonarray events', x => x.events = {}],
    ['duplicate player', x => x.roster.push({...x.roster[0]})],
    ['dual-team player', x => x.roster.push({...x.roster[0], team: 'B'})],
    ['eight assigned players', x => x.roster.push({...x.roster[0], id: 'A8', initial_active: false})],
    ['missing snapshot', x => delete x.roster[0].sr_before],
    ['unknown final team', x => x.roster[0].team = 'C'],
    ['implicit initial presence', x => delete x.roster[0].initial_active],
    ['string initial presence', x => x.roster[0].initial_active = 'true'],
    ['unknown event', x => x.events = [event('UNKNOWN', 600, 'A7')]],
    ['external replacement', x => x.events = [event('JOIN', 600, 'outsider')]],
    ['negative event clock', x => x.events = [event('QUIT', -1, 'A7')]],
    ['fractional event clock', x => x.events = [event('QUIT', 1.5, 'A7')]],
    ['beyond final clock', x => x.events = [event('QUIT', 3601, 'A7')]],
    ['decreasing clock', x => x.events = [event('EXCUSED_LEAVE', 600, 'A7'), event('RETURN', 599, 'A7', 601)]],
    ['decreasing wall time', x => x.events = [event('EXCUSED_LEAVE', 600, 'A7'), event('RETURN', 601, 'A7', 599)]],
    ['duplicate event ID', x => {const e = event('EXCUSED_LEAVE', 600, 'A7'); x.events = [e, {...e}];}],
    ['missing event ID', x => {const e = event('QUIT', 600, 'A7'); delete e.id; x.events = [e];}],
    ['invalid date', x => x.events = [{...event('QUIT', 600, 'A7'), recorded_at: '2026-02-30T12:00:00Z'}]],
    ['no timestamp timezone', x => x.events = [{...event('QUIT', 600, 'A7'), recorded_at: '2026-10-14T12:10:00'}]],
    ['untrusted relative timestamp', x => x.events = [{...event('QUIT', 600, 'A7'), recorded_at: 'now'}]],
    ['missing timestamp', x => {const e = event('QUIT', 600, 'A7'); delete e.recorded_at; x.events = [e];}],
    ['return before absence', x => x.events = [event('RETURN', 600, 'A7')]],
    ['join while active', x => x.events = [event('JOIN', 600, 'A7')]],
    ['join after injury', x => x.events = [event('EXCUSED_LEAVE', 600, 'A7'), event('JOIN', 900, 'A7')]],
    ['ordinary return after red', x => x.events = [event('RED_CARD', 600, 'A7'), event('RETURN', 900, 'A7')]],
    ['ordinary return after quit', x => x.events = [event('QUIT', 600, 'A7'), event('RETURN', 900, 'A7')]],
    ['ordinary return during blue', x => x.events = [event('BLUE_CARD', 600, 'A7'), event('RETURN', 900, 'A7')]],
    ['double departure', x => x.events = [event('QUIT', 600, 'A7'), event('RED_CARD', 900, 'A7')]],
    ['midgame transfer', x => x.events = [event('MOVE', 600, 'A7')]],
    ['event team override', x => x.events = [{...event('QUIT', 600, 'A7'), team: 'B'}]],
    ['clock with player', x => x.events = [event('PAUSE', 600, 'A7')]],
    ['duplicate pause', x => x.events = [event('PAUSE', 600), event('PAUSE', 600)]],
    ['resume running clock', x => x.events = [event('RESUME', 600)]],
    ['positive time while paused', x => x.events = [event('PAUSE', 600), event('RESUME', 720)]],
    ['blue return too early', x => x.events = [event('BLUE_CARD', 600, 'A7'), event('BLUE_RETURN', 719, 'A7')]],
    ['blue return before card', x => x.events = [event('BLUE_RETURN', 600, 'A7')]],
    ['blue return after red', x => x.events = [event('RED_CARD', 600, 'A7'), event('BLUE_RETURN', 900, 'A7')]],
    ['pre-entry blue', x => {person(x, 'A7').initial_active = false; x.events = [event('BLUE_CARD', 600, 'A7')];}],
    ['pre-entry quit', x => {person(x, 'A7').initial_active = false; x.events = [event('QUIT', 600, 'A7')];}],
    ['below minimum at kickoff', x => {for (const id of ['A5', 'A6', 'A7']) person(x, id).initial_active = false;}],
    ['no fabricated completion', x => x.played_seconds = 600],
  ];
  for (const [name, mutate] of mutations) await invalid(name, mutate);
  for (const type of ['EXCUSED_LEAVE', 'QUIT', 'RED_CARD', 'BLUE_CARD']) {
    await invalid(`retained contribution cannot satisfy minimum (${type})`, x => x.events = [event(type, 600, 'A5')], match(5, 7));
  }
  for (const input of [null, [], true]) {
    await assert.rejects(normalize(input), error => error.code === '22023'); invalidChecks++;
  }
  for (const name of [`${prefix}normalize_season_zero_sr(jsonb)`, `${prefix}season_zero_sr_interval(jsonb,integer,integer,boolean)`]) {
    for (const role of ['anon', 'authenticated', 'service_role']) {
      assert.equal(await scalar("select has_function_privilege($1,$2,'EXECUTE')", [role, name]), false);
      permissions++;
    }
    const meta = (await db.query('select provolatile, proparallel, prosecdef from pg_proc where oid=$1::regprocedure', [name])).rows[0];
    assert.deepEqual(meta, {provolatile: 'i', proparallel: 's', prosecdef: false});
  }
  console.log(`PASS: ${scenarios} timeline/calculator scenarios; ${invalidChecks} invalid timeline checks; ${permissions} role-permission checks.`);
  console.log('NOT TESTED: server event/roster authority, live clock capture, settlement/rollback/replay, full migration replay, or app UI. This module cannot authenticate client-supplied snapshots.');
} finally { await db.close(); }

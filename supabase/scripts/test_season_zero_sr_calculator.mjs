// Isolated real PostgreSQL/PGlite checks. No network/database connection and no
// production runtime dependency. This applies ONLY the pure calculator migration.
// PGLITE_MODULE=/tmp/fieldrush-market-sql-tools/node_modules/@electric-sql/pglite \
//   node supabase/scripts/test_season_zero_sr_calculator.mjs
// The fixture JSON is the unmodified October 14, 2026 product handoff bundle.
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';

const require = createRequire(import.meta.url);
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const fixtureSource = await readFile(new URL('./fixtures/season_zero_sr_calculation.json', import.meta.url), 'utf8');
assert.equal(createHash('sha256').update(fixtureSource).digest('hex'),
  'a379d1fad23c4d3347cb8b0ecffb8a63acb16c12fd89c86c4254dbc25f3d2f59', 'Original handoff fixtures remain unmodified');
const bundle = JSON.parse(fixtureSource);
const migration = await readFile(new URL('../migrations/20261014001000_season_zero_sr_calculator.sql', import.meta.url), 'utf8');
const prefix = 'fieldrush_rating_private.';
let helperChecks = 0;
let invalidChecks = 0;
let permissionChecks = 0;
let edgeChecks = 0;
let blueCardChecks = 0;
const integerFields = new Set(['k', 'delta', 'sr_after', 'games_after', 'public_sr', 'protection_denominator']);

function equalResult(actual, expected, path) {
  if (expected !== null && typeof expected === 'object') {
    assert.equal(typeof actual, 'object', path);
    assert.notEqual(actual, null, path);
    assert.deepEqual(Object.keys(actual).sort(), Object.keys(expected).sort(), `${path}: exact fields`);
    for (const [key, value] of Object.entries(expected)) equalResult(actual[key], value, `${path}.${key}`);
  } else if (typeof expected === 'number' && !integerFields.has(path.split('.').at(-1))) {
    assert.equal(typeof actual, 'number', path);
    assert.ok(Number.isFinite(actual), `${path}: finite`);
    assert.ok(Math.abs(actual - expected) <= Math.max(1e-9, 1e-11 * Math.max(Math.abs(actual), Math.abs(expected))),
      `${path}: ${actual} != ${expected}`);
  } else {
    assert.deepEqual(actual, expected, path);
  }
}
async function scalar(sql, parameters = []) {
  const { rows } = await db.query(sql, parameters);
  return Object.values(rows[0])[0];
}
async function calculate(input) {
  return scalar(`select ${prefix}calculate_season_zero_sr($1::jsonb)`, [JSON.stringify(input)]);
}
async function rejectsInput(label, mutate) {
  const input = structuredClone(bundle.cases[0].input);
  mutate(input);
  await assert.rejects(calculate(input), error => error.code === '22023', label);
  invalidChecks++;
}

try {
  await db.exec('create schema fieldrush_rating_private; create role anon; create role authenticated; create role service_role;');
  await db.exec(migration);
  assert.equal(bundle.cases.length, 71, 'Keep all supplied fixtures');
  for (const fixture of bundle.cases) {
    const inputBefore = JSON.stringify(fixture.input);
    equalResult(await calculate(fixture.input), fixture.expected, fixture.id);
    assert.equal(JSON.stringify(fixture.input), inputBefore, `${fixture.id}: caller input unchanged`);
  }

  // User-approved extension, separate from the unchanged original 71 cases.
  // BLUE_CARD is conduct history, not a terminal exit: it remains applicable
  // after the referee confirms a return and cumulative participation resumes.
  for (const fixture of bundle.cases.filter(f => f.input.players.some(p => p.exit_reason === 'RED_CARD'))) {
    const input = structuredClone(fixture.input);
    for (const player of input.players) if (player.exit_reason === 'RED_CARD') player.exit_reason = 'BLUE_CARD';
    equalResult(await calculate(input), fixture.expected, `blue_card_${fixture.id}`);
    blueCardChecks++;
  }
  for (const [seconds, winner, expectedDelta, counted] of [
    [0, 'B', 0, false], [599, 'A', 0, false], [599, 'B', -40, false],
    [600, 'A', 40, true], [600, 'B', -40, true], [1200, 'A', 40, true],
  ]) {
    const input = structuredClone(bundle.cases[0].input);
    input.winner = winner;
    input.players = [{...input.players[0], exit_reason: 'BLUE_CARD', actual_seconds: seconds}];
    const result = (await calculate(input)).players['A-K80'];
    assert.equal(result.delta, expectedDelta, `blue card ${seconds}s ${winner} winner`);
    assert.equal(result.counted, counted);
    assert.equal(result.games_after, counted ? 2 : 1);
    blueCardChecks++;
  }

  for (const [n, expected] of [[0, 80], [1, 80], [5, 80], [6, 60], [9, 60], [10, 40], [500, 40]]) {
    assert.equal(await scalar(`select ${prefix}season_zero_sr_k($1)`, [n]), expected);
    helperChecks++;
  }
  for (const [value, expected] of [[0, 0], ['-0.0', 0], [0.5, 1], [-0.5, -1], [1.5, 2], [-1.5, -2], [2.49, 2], [-2.49, -2]]) {
    assert.equal(await scalar(`select ${prefix}season_zero_sr_round($1::numeric)`, [value]), expected);
    helperChecks++;
  }
  for (const [assessment, seed] of Object.entries({beginner: 800, casual: 900, intermediate: 1000, advanced: 1100, highly_competitive: 1200, not_sure: 1000})) {
    assert.equal(await scalar(`select ${prefix}season_zero_sr_seed($1)`, [assessment]), seed);
    helperChecks++;
  }
  for (const [games, visible, provisional] of [[0, false, false], [1, false, false], [2, true, true], [9, true, true], [10, true, false]]) {
    assert.deepEqual(await scalar(`select ${prefix}season_zero_sr_public_state(1050,$1)`, [games]), {
      visible, public_sr: visible ? 1050 : null, provisional,
    });
    helperChecks++;
  }
  for (const difference of [-100000, -200, -100, 0, 100, 200, 100000]) {
    assert.equal(await scalar(`select e between 0 and 1 and abs(e + ${prefix}season_zero_sr_expected(-$1::numeric) - 1) < 1e-12
      from (select ${prefix}season_zero_sr_expected($1::numeric) e) x`, [difference]), true);
    helperChecks++;
  }

  const invalidMutations = [
    ['unsupported policy', x => x.policy_id = 'old-policy'],
    ['unknown status', x => x.status = 'mystery'],
    ['missing status', x => delete x.status],
    ['short schedule', x => x.scheduled_seconds = 599],
    ['negative played', x => x.played_seconds = -1],
    ['short completed match', x => x.played_seconds = 1800],
    ['bad winner', x => x.winner = 'C'],
    ['missing winner', x => delete x.winner],
    ['numeric winner', x => x.winner = 1],
    ['excess manpower', x => x.average_count_difference_a = 3],
    ['negative excess manpower', x => x.average_count_difference_a = -3],
    ['nonfinite strength', x => x.team_strengths.A = 'NaN'],
    ['infinite strength', x => x.team_strengths.A = 'Infinity'],
    ['string strength', x => x.team_strengths.A = '1000'],
    ['boolean manpower', x => x.average_count_difference_a = true],
    ['missing strength', x => delete x.team_strengths.A],
    ['negative games', x => x.players[0].games_before = -1],
    ['boolean games', x => x.players[0].games_before = true],
    ['fractional rating', x => x.players[0].sr_before = 1000.5],
    ['string rating', x => x.players[0].sr_before = '1000'],
    ['null rating', x => x.players[0].sr_before = null],
    ['rating overflow', x => x.players[0].sr_before = 2147483648],
    ['rating underflow', x => x.players[0].sr_before = -2147483649],
    ['count overflow', x => x.players[0].games_before = 2147483648],
    ['count result overflow', x => x.players[0].games_before = 2147483647],
    ['positive result overflow', x => x.players[0].sr_before = 2147483647],
    ['negative result overflow', x => x.players[3].sr_before = -2147483648],
    ['time overflow', x => x.played_seconds = 2147483648],
    ['fractional time', x => x.players[0].actual_seconds = 600.5],
    ['too much participation', x => x.players[0].actual_seconds = 3601],
    ['too much protection', x => x.players[0].protected_seconds = 3601],
    ['protection exceeds participation', x => {x.players[0].actual_seconds = 600; x.players[0].protected_seconds = 601;}],
    ['negative protection', x => x.players[0].protected_seconds = -1],
    ['unknown departure', x => x.players[0].exit_reason = 'UNKNOWN'],
    ['missing departure', x => delete x.players[0].exit_reason],
    ['unknown team', x => x.players[0].team = 'C'],
    ['empty ID', x => x.players[0].id = ''],
    ['numeric ID', x => x.players[0].id = 1],
    ['duplicate ID', x => x.players.push(structuredClone(x.players[0]))],
    ['duplicate ID across teams', x => {const p = structuredClone(x.players[0]); p.team = 'B'; x.players.push(p);}],
    ['null player', x => x.players[0] = null],
    ['players object', x => x.players = {}],
    ['missing players', x => delete x.players],
    ['forfeit draw', x => {x.status = 'forfeit_confirmed'; x.winner = null;}],
    ['invalid unrated snapshot', x => {x.status = 'no_contest'; x.players[0].games_before = -1;}],
  ];
  for (const [label, mutate] of invalidMutations) await rejectsInput(label, mutate);
  for (const input of [null, [], true, 'invalid']) {
    await assert.rejects(calculate(input), error => error.code === '22023');
    invalidChecks++;
  }
  for (const value of ['NaN', 'Infinity', '-Infinity', null, '2147483648', '-2147483649']) {
    await assert.rejects(scalar(`select ${prefix}season_zero_sr_round($1::numeric)`, [value]), error => error.code === '22023');
    invalidChecks++;
  }
  for (const sql of [
    `select ${prefix}season_zero_sr_seed('elite')`,
    `select ${prefix}season_zero_sr_seed(null)`,
    `select ${prefix}season_zero_sr_k(-1)`,
    `select ${prefix}season_zero_sr_k(null)`,
    `select ${prefix}season_zero_sr_public_state(1000,-1)`,
    `select ${prefix}season_zero_sr_public_state(null,2)`,
    `select ${prefix}season_zero_sr_expected('NaN'::numeric)`,
    `select ${prefix}season_zero_sr_expected('Infinity'::numeric)`,
    `select ${prefix}season_zero_sr_expected(null)`,
    `select ${prefix}season_zero_sr_number('1e309'::jsonb,'strength')`,
  ]) {
    await assert.rejects(scalar(sql), error => error.code === '22023');
    invalidChecks++;
  }

  // Storage safety is not a policy clamp: negative SR is allowed to fall further.
  const belowZero = structuredClone(bundle.cases[0].input);
  belowZero.players = [{...belowZero.players[3], sr_before: -100}];
  assert.equal((await calculate(belowZero)).players['B-K80'].sr_after, -140);
  edgeChecks++;
  // A zero-point no-show may safely remain at the highest stored count/rating.
  const atLimit = structuredClone(bundle.cases[0].input);
  atLimit.players = [{...atLimit.players[0], sr_before: 2147483647, games_before: 2147483647, actual_seconds: 0}];
  assert.equal((await calculate(atLimit)).players['A-K80'].games_after, 2147483647);
  edgeChecks++;
  // Both extreme signs and subnormal expectations avoid power overflow/underflow.
  for (const difference of ['-1e308', '-129600', '-129599', '129599', '129600', '1e308']) {
    assert.equal(await scalar(`select ${prefix}season_zero_sr_expected($1::numeric) between 0 and 1`, [difference]), true);
    edgeChecks++;
  }
  // Explicit half-ties verify the one final rounding step after forgiveness.
  const tie = structuredClone(bundle.cases[0].input);
  tie.players = [{...tie.players[3], games_before: 10, protected_seconds: 1800}];
  const tieResult = (await calculate(tie)).players['B-K80'];
  assert.equal(tieResult.adjusted_raw, -11.5);
  assert.equal(tieResult.delta, -12);
  edgeChecks++;
  // A recurring q must not perturb an exact half tie before final rounding.
  const rationalTie = structuredClone(tie);
  rationalTie.scheduled_seconds = 2040;
  rationalTie.played_seconds = 2040;
  rationalTie.players[0].actual_seconds = 2040;
  rationalTie.players[0].protected_seconds = 300;
  const rationalTieResult = (await calculate(rationalTie)).players['B-K80'];
  assert.equal(rationalTieResult.adjusted_raw, -17.5);
  assert.equal(rationalTieResult.delta, -18);
  edgeChecks++;

  const functions = (await db.query(`select oid::regprocedure::text name, provolatile, proparallel, prosecdef
    from pg_proc where pronamespace = 'fieldrush_rating_private'::regnamespace`)).rows;
  assert.equal(functions.length, 8);
  for (const fn of functions) {
    assert.equal(fn.provolatile, 'i', `${fn.name}: immutable`);
    assert.equal(fn.proparallel, 's', `${fn.name}: parallel safe`);
    assert.equal(fn.prosecdef, false, `${fn.name}: no privilege escalation`);
    for (const role of ['anon', 'authenticated', 'service_role']) {
      assert.equal(await scalar('select has_function_privilege($1,$2,\'EXECUTE\')', [role, fn.name]), false, `${role}: ${fn.name}`);
      permissionChecks++;
    }
  }
  console.log(`PASS: ${bundle.cases.length} fixture cases; ${blueCardChecks} approved blue-card checks; ${helperChecks} helper/boundary checks; ${invalidChecks} invalid-input checks; ${edgeChecks} arithmetic edges; ${permissionChecks} role-permission checks.`);
  console.log('NOT TESTED: live event normalization, authentication, settlement, full migration replay, existing rating integration, or app UI. No policy activation or data mutation occurred.');
} finally {
  await db.close();
}

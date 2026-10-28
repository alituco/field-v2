import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const verifier = readFileSync(new URL('../../supabase/scripts/verify_season_zero_rating_initialization.sql', import.meta.url), 'utf8');

test('legacy initialization fixtures leave Supabase-managed Auth ownership and triggers intact', () => {
  assert.doesNotMatch(verifier, /\b(?:alter\s+table|drop\s+table|truncate(?:\s+table)?)\s+auth\.users\b/i);
  assert.doesNotMatch(verifier, /\b(?:disable|enable)\s+trigger\b/i);
  assert.doesNotMatch(verifier, /session_replication_role/i);
  const removal = verifier.match(/delete from fieldrush_rating_private\.season_zero_initialization_eligibility\s+where user_id in \(([^;]+)\);/);
  assert.ok(removal, 'Legacy fixtures must remove only their application-owned enrollment markers');
  const ids = [...removal[1].matchAll(/'([^']+)'/g)].map(match => match[1]);
  assert.deepEqual(ids, [
    'fb011000-0000-4000-8000-000000000001',
    'fb011000-0000-4000-8000-000000000002',
  ]);
  const triggerAssertion = verifier.indexOf('real Auth enrollment trigger creates both synthetic markers');
  assert.ok(triggerAssertion >= 0 && triggerAssertion < removal.index,
    'The actual enrollment trigger must be checked before removing fixture markers');
  assert.match(verifier, /new identity requires assessment, regardless of editable auth metadata/);
  assert.match(verifier, /existing completed account SR, counts, stats and audit remain unchanged/);
  assert.match(verifier, /existing unfinished signup completes without reseeding/);
  assert.match(verifier, /\bbegin;/i);
  assert.match(verifier, /rollback;\s*$/i);
});

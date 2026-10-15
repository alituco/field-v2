import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

// Both reviewed action.yml files declare runs.using: node24. Keep immutable
// release pins without changing the app's Node 22 or explicit npm cache inputs.
// https://github.com/actions/checkout/releases/tag/v5.1.0
// https://github.com/actions/setup-node/releases/tag/v6.5.0
const pins = {
  checkout: 'fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09',
  'setup-node': '249970729cb0ef3589644e2896645e5dc5ba9c38',
};
const workflows = ['ci.yml', 'android-emulator-preflight.yml'].map(name => ({
  name,
  source: readFileSync(new URL(`../workflows/${name}`, import.meta.url), 'utf8'),
}));

test('CI and Android preflight pin the reviewed native Node 24 checkout/setup actions', () => {
  for (const { name, source } of workflows) {
    const actions = [...source.matchAll(/uses: actions\/(checkout|setup-node)@([^\s]+)/g)];
    assert.ok(actions.some(([, action]) => action === 'checkout'), `${name} must check out the repository`);
    for (const [, action, sha] of actions) {
      assert.match(sha, /^[a-f0-9]{40}$/, `${name} ${action} must be SHA-pinned`);
      assert.equal(sha, pins[action], `${name} ${action} must use the reviewed Node 24 release`);
    }
    assert.doesNotMatch(source, /ACTIONS_ALLOW_USE_UNSECURE_NODE_VERSION|ACTIONS_RUNNER_FORCE_ACTIONS_NODE_VERSION|allow-unsafe-pr-checkout:/);
  }
});

test('the Node action runtime upgrade preserves Node 22 and explicit per-project npm caches', () => {
  const ci = workflows.find(({ name }) => name === 'ci.yml').source;
  const setupSteps = ci.split(/(?=^ {6}- name:)/m)
    .filter(step => step.includes('uses: actions/setup-node@'));
  assert.ok(setupSteps.length > 0);
  for (const step of setupSteps) {
    assert.match(step, /^ {10}node-version: 22$/m);
    assert.match(step, /^ {10}cache: npm$/m);
    assert.match(step, /^ {10}cache-dependency-path: (?:referee|broadcaster)\/package-lock\.json$/m);
    assert.doesNotMatch(step, /^ {10}(?:always-auth|registry-url|scope|token|package-manager-cache):/m);
  }
});

test('checkout retains existing credential defaults and does not opt into unsafe PR checkout', () => {
  for (const { source } of workflows) {
    const checkoutSteps = source.split(/(?=^ {6}- name:)/m)
      .filter(step => step.includes('uses: actions/checkout@'));
    for (const step of checkoutSteps) {
      assert.doesNotMatch(step, /^ {10}(?:persist-credentials|token|ssh-key|allow-unsafe-pr-checkout):/m);
    }
  }
});

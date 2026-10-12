import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { CI_OUTPUTS, createCiPlan } from "./ci-plan.mjs";

const workflow = readFileSync(new URL("../workflows/ci.yml", import.meta.url), "utf8");
const emulator = readFileSync(new URL("../actions/staging-android-emulator/action.yml", import.meta.url), "utf8");
const preflight = readFileSync(new URL("../workflows/android-emulator-preflight.yml", import.meta.url), "utf8");
const cleanupAction = readFileSync(new URL("../actions/cleanup-staging-e2e/action.yml", import.meta.url), "utf8");

// Syntax is checked separately with actionlint. These contracts prevent future
// refactors from moving compilation back beside the emulator or weakening gates.
function job(id) {
  const start = workflow.indexOf(`\n  ${id}:\n`);
  assert.notEqual(start, -1, `Missing job ${id}`);
  const rest = workflow.slice(start + 1);
  const next = rest.slice(1).search(/^  [a-z][a-z0-9-]*:\s*$/m);
  return next === -1 ? rest : rest.slice(0, next + 1);
}

function needs(id) {
  const match = job(id).match(/^    needs: (.+)$/m);
  assert.ok(match, `Missing needs for ${id}`);
  return match[1].replace(/^\[|\]$/g, "").split(",").map(value => value.trim());
}

function stepContaining(source, text, indentation = 6) {
  const index = source.indexOf(text);
  assert.notEqual(index, -1, `Missing step containing ${text}`);
  const boundary = `${" ".repeat(indentation)}- name:`;
  const start = source.lastIndexOf(boundary, index);
  assert.notEqual(start, -1, `Missing step boundary before ${text}`);
  const end = source.indexOf(boundary, start + 1);
  return source.slice(start, end === -1 ? undefined : end);
}

const baselineJobs = {
  flutter: "flutter", android: "android-builds", ios: "flutter-ios",
  referee: "referee", broadcaster: "broadcaster", database: "database",
};
const jobFlags = {
  ...Object.fromEntries(Object.entries(baselineJobs).map(([flag, id]) => [id, flag])),
  "backend-staging": "backend", "prepare-staging-e2e": "player",
  "android-staging-e2e": "player", "browser-staging-e2e": "browser",
};

test("credential-free preflight runs contracts before selecting expensive checks", () => {
  const source = job("preflight");
  assert.match(source, /timeout-minutes: 5/);
  assert.match(source, /fetch-depth: 0/);
  assert.match(source, /run: bash \.github\/scripts\/check-ci\.sh/);
  assert.match(source, /run: node \.github\/scripts\/ci-plan\.mjs/);
  assert.ok(source.indexOf("check-ci.sh") < source.indexOf("ci-plan.mjs"));
  assert.doesNotMatch(source, /secrets\.|^    (?:needs|environment):/m);
  for (const flag of CI_OUTPUTS) {
    assert.ok(source.includes(`${flag}: \${{ steps.plan.outputs.${flag} }}`));
  }
  assert.match(source, /PR_BASE_SHA: \$\{\{ github\.event\.pull_request\.base\.sha \}\}/);
  assert.match(source, /PR_HEAD_SHA: \$\{\{ github\.event\.pull_request\.head\.sha \}\}/);
  for (const mode of ["full", "backend", "player", "journey"]) {
    assert.match(workflow, new RegExp(`^          - ${mode}$`, "m"));
  }
});

test("all six baseline checks are independently plan-gated after preflight", () => {
  for (const [flag, id] of Object.entries(baselineJobs)) {
    assert.deepEqual(needs(id), ["preflight"]);
    assert.match(job(id), new RegExp(`if: needs\\.preflight\\.outputs\\.${flag} == 'true'`));
  }
  const flutter = job("flutter");
  assert.match(flutter, /run: flutter analyze/);
  assert.match(flutter, /run: flutter test/);
  assert.doesNotMatch(flutter, /flutter build|Set up Java|cache: gradle/);
  assert.match(job("android-builds"), /flutter build apk/);
  assert.match(job("flutter-ios"), /flutter build ios/);
});

test("the shared admin inbox navigation is verified before hosted deployments", () => {
  const source = job("referee");
  const browser = stepContaining(source, "npm run test:ui -- admin-inbox-navigation.spec.ts --project=chromium");
  assert.match(source, /npx playwright install --with-deps chromium/);
  assert.ok(source.indexOf("Check admin inbox navigation") < source.indexOf("Build referee app"));
  assert.doesNotMatch(browser, /continue-on-error:|\|\|\s*true|secrets\./);
  assert.doesNotMatch(source, /^    environment:|secrets\./m);
  const hosted = readFileSync(new URL("../../referee/e2e/staging-referee-admin.spec.ts", import.meta.url), "utf8");
  const isolated = readFileSync(new URL("../../referee/ui-tests/admin-inbox-navigation.spec.ts", import.meta.url), "utf8");
  assert.match(hosted, /verifyAdminRequestInboxes\(page, manifest\.markers\)/);
  assert.match(isolated, /verifyAdminRequestInboxes/);
});

test("saved field permissions and location snapshots are checked before full schema replay", () => {
  const source = job("database");
  const check = stepContaining(source, "node supabase/scripts/test_saved_fields.mjs");
  assert.match(check, /set -euo pipefail/);
  assert.match(check, /PGLITE_MODULE=/);
  assert.doesNotMatch(check, /continue-on-error:|\|\|\s*true|secrets\./);
  assert.ok(source.indexOf("test_saved_fields.mjs") < source.indexOf("Replay migrations on a fresh local Supabase stack"));
});

test("recurring schedule permissions, idempotency and pitch conflicts are checked before full schema replay", () => {
  const source = job("database");
  const check = stepContaining(source, "node supabase/scripts/test_game_schedules.mjs");
  assert.match(check, /set -euo pipefail/);
  assert.match(check, /PGLITE_MODULE=/);
  assert.doesNotMatch(check, /continue-on-error:|\|\|\s*true|secrets\./);
  assert.ok(source.indexOf("test_game_schedules.mjs") < source.indexOf("Replay migrations on a fresh local Supabase stack"));
});

test("price edits preserve captured quotes, paid bookings and refunds before full schema replay", () => {
  const source = job("database");
  const check = stepContaining(source, "node supabase/scripts/test_game_prices.mjs");
  assert.match(check, /set -euo pipefail/);
  assert.match(check, /PGLITE_MODULE=/);
  assert.doesNotMatch(check, /continue-on-error:|\|\|\s*true|secrets\./);
  assert.ok(source.indexOf("test_game_prices.mjs") < source.indexOf("Replay migrations on a fresh local Supabase stack"));
});

test("single-game registration and private activity dismissals are checked before full schema replay", () => {
  const source = job("database");
  for (const script of ["test_single_active_game.mjs", "test_home_activity_dismissals.mjs"]) {
    const check = stepContaining(source, `node supabase/scripts/${script}`);
    assert.match(check, /set -euo pipefail/);
    assert.match(check, /PGLITE_MODULE=/);
    assert.doesNotMatch(check, /continue-on-error:|\|\|\s*true|secrets\./);
    assert.ok(source.indexOf(script) < source.indexOf("Replay migrations on a fresh local Supabase stack"));
  }
});

test("Flutter golden comparisons remain part of the mandatory unfiltered test run", () => {
  const source = job("flutter");
  const run = stepContaining(source, "name: Run Flutter tests");
  assert.match(run, /^        id: flutter-tests$/m);
  assert.match(run, /^        run: flutter test$/m);
  assert.doesNotMatch(run, /^        (?:if|continue-on-error):|--update-goldens|\|\|\s*true/m);
  assert.doesNotMatch(source, /^    continue-on-error:/m);
});

test("Flutter golden failure diagnostics upload only generated PNGs without masking test failures", () => {
  const source = job("flutter");
  const run = stepContaining(source, "name: Run Flutter tests");
  const upload = stepContaining(source, "name: Upload Flutter golden failure images");
  assert.ok(source.indexOf(run) < source.indexOf(upload));
  assert.match(upload, /^        if: failure\(\) && steps\.flutter-tests\.outcome == 'failure'$/m);
  assert.match(upload, /^        uses: actions\/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02(?: #.*)?$/m);
  assert.match(upload, /^        continue-on-error: true$/m);
  assert.match(upload, /^          name: flutter-golden-failures-\$\{\{ runner\.os \}\}$/m);
  // LocalFileComparator writes relative to the test, not the golden image path.
  assert.match(upload, /^          path: mobile\/test\/failures\/\*\.png$/m);
  assert.match(upload, /^          if-no-files-found: ignore$/m);
  assert.match(upload, /^          retention-days: 7$/m);
  assert.doesNotMatch(upload, /secrets\.|include-hidden-files:\s*true/);
});

test("backend deploy starts after fast app and database checks, not native builds", () => {
  const backend = job("backend-staging");
  assert.deepEqual(needs("backend-staging"), ["preflight", "flutter", "database"]);
  assert.match(backend, /always\(\) && !cancelled\(\)/);
  assert.match(backend, /needs\.preflight\.result == 'success'/);
  assert.match(backend, /needs\.preflight\.outputs\.backend == 'true'/);
  for (const id of ["flutter", "database"]) {
    assert.match(backend, new RegExp(`needs\\.${id}\\.result == 'success' \\|\\|\\s*\\(inputs\\.mode == 'backend' && needs\\.${id}\\.result == 'skipped'\\)`));
  }
  assert.match(backend, /deploy-supabase\.sh staging/);
  assert.match(backend, /smoke-supabase\.mjs/);
  assert.match(backend, /\$GITHUB_REF.*refs\/heads\/staging/);
  assert.deepEqual(needs("prepare-staging-e2e"), ["preflight", "backend-staging"]);
  assert.match(job("prepare-staging-e2e"), /if: needs\.preflight\.outputs\.player == 'true'/);
});

test("each Supabase caller installs the CLI on its own runner before first use", () => {
  for (const [id, firstUse] of [
    ["database", "supabase start"],
    ["backend-staging", ".github/scripts/deploy-supabase.sh staging"],
    ["prepare-staging-e2e", ".github/scripts/configure-staging-e2e-auth.sh"],
  ]) {
    const source = job(id);
    const setup = stepContaining(source, "uses: supabase/setup-cli@");
    assert.match(setup, /version: 2\.105\.0/);
    assert.doesNotMatch(setup, /if:|continue-on-error/);
    assert.ok(source.indexOf(setup) < source.indexOf(firstUse), `${id} must install its own CLI before ${firstUse}`);
  }
  const prepare = job("prepare-staging-e2e");
  assert.ok(prepare.indexOf("run: supabase --version") > prepare.indexOf("uses: supabase/setup-cli@"));
  assert.ok(prepare.indexOf("run: supabase --version") < prepare.indexOf("uses: actions/setup-java@"));
});

test("every planned journey has successful planned prerequisites despite skipped native jobs", () => {
  const cases = [
    { eventName: "push", ref: "refs/heads/staging" },
    { eventName: "push", ref: "refs/heads/prod" },
    ...["full", "backend", "player", "journey"].map(mode => ({ eventName: "workflow_dispatch", ref: "refs/heads/staging", mode })),
    ...["docs/guide.md", "mobile/test/example_test.dart", "supabase/migrations/example.sql"].map(filename => ({ eventName: "pull_request", ref: "refs/pull/1/merge", changedPaths: [filename] })),
  ];
  for (const scenario of cases) {
    const plan = createCiPlan(scenario);
    for (const [id, flag] of Object.entries(jobFlags)) {
      if (plan[flag] !== "true") continue;
      for (const dependency of needs(id)) {
        if (dependency === "preflight") continue;
        if (id === "backend-staging" && scenario.mode === "backend") continue;
        assert.equal(plan[jobFlags[dependency]], "true", `${JSON.stringify(scenario)}: ${id} would depend on skipped ${dependency}`);
      }
    }
  }
});

test("APK compilation is isolated from browser dependencies and emulator", () => {
  const prepare = job("prepare-staging-e2e");
  assert.match(prepare, /run-staging-android-e2e\.sh build-only/);
  assert.doesNotMatch(prepare, /playwright install|npm ci|uses: .*staging-android-emulator|deploy-supabase\.sh/);
});

test("Android build and E2E preparation share dependency-only Gradle caching", () => {
  for (const id of ["android-builds", "prepare-staging-e2e"]) {
    const source = job(id);
    assert.match(source, /cache: gradle/);
    assert.match(source, /mobile\/android\/\*\*\/\*\.gradle\*/);
    assert.match(source, /mobile\/android\/gradle\/wrapper\/gradle-wrapper\.properties/);
  }
});

test("fresh Android job only executes the encrypted prebuilt binary", () => {
  const android = job("android-staging-e2e");
  assert.deepEqual(needs("android-staging-e2e"), ["preflight", "prepare-staging-e2e"]);
  assert.match(android, /runs-on: ubuntu-24\.04/);
  assert.match(android, /run-staging-android-e2e\.sh.*run-prebuilt/);
  assert.match(android, /staging-e2e-handoff\.mjs unpack/);
  assert.doesNotMatch(android, /flutter build|build-only|npm ci|playwright install|deploy-supabase\.sh/);
});

test("preflight and protected Android job share late-guarded 2 GiB emulator", () => {
  assert.match(job("android-staging-e2e"), /uses: \.\/\.github\/actions\/staging-android-emulator/);
  assert.match(preflight, /uses: \.\/\.github\/actions\/staging-android-emulator/);
  assert.match(preflight, /script: bash .*check-android-emulator\.sh/);
  assert.doesNotMatch(preflight, /script: \|/);
  assert.match(emulator, /disk-size: 2048M/);
  assert.match(emulator, /pre-emulator-launch-script: .*prepare-android-emulator\.sh/);
  assert.ok(emulator.indexOf("sudo udevadm settle") < emulator.indexOf("test -r /dev/kvm"));
  assert.ok(emulator.indexOf("sudo chmod 666 /dev/kvm") < emulator.indexOf("test -r /dev/kvm"));
  assert.doesNotMatch(preflight, /secrets\.|environment:\s*staging|deploy-supabase/);
});

test("browser journey runs only after player journey", () => {
  const browser = job("browser-staging-e2e");
  assert.deepEqual(needs("browser-staging-e2e"), ["preflight", "prepare-staging-e2e", "android-staging-e2e"]);
  assert.match(browser, /if: needs\.preflight\.outputs\.browser == 'true'/);
  assert.match(browser, /npm run test:e2e/);
  assert.match(browser, /--phase=complete/);
});

test("fixture owners clean up failures and player-only diagnostics in their own jobs", () => {
  const prepare = stepContaining(job("prepare-staging-e2e"), "cleanup_staging.ts");
  assert.match(prepare, /if: failure\(\) \|\| cancelled\(\)/);
  assert.doesNotMatch(prepare, /handoff-upload\.outcome/);
  const android = stepContaining(job("android-staging-e2e"), "uses: ./.github/actions/cleanup-staging-e2e");
  assert.match(android, /if: always\(\) && \(failure\(\) \|\| cancelled\(\) \|\| needs\.preflight\.outputs\.browser != 'true'\)/);
  const browser = stepContaining(job("browser-staging-e2e"), "uses: ./.github/actions/cleanup-staging-e2e");
  assert.match(browser, /if: always\(\)/);
  for (const source of [prepare, android, browser]) {
    assert.match(source, /SUPABASE_SERVICE_ROLE_KEY: \$\{\{ secrets\.SUPABASE_SERVICE_ROLE_KEY \}\}/);
    assert.doesNotMatch(source, /continue-on-error/);
  }
  assert.match(prepare, /\$E2E_MANIFEST_PATH/);
  for (const source of [android, browser]) {
    assert.match(source, /handoff-artifact-id: \$\{\{ needs\.prepare-staging-e2e\.outputs\.handoff-artifact-id \}\}/);
    assert.match(source, /STAGING_E2E_HANDOFF_KEY: \$\{\{ secrets\.SUPABASE_SERVICE_ROLE_KEY \}\}/);
  }
  assert.match(job("android-staging-e2e"), /echo "E2E_MANIFEST_PATH=.*manifest\.json" >>"\$GITHUB_ENV"/);
});

test("cleanup recovers encrypted state after early setup failure and requires a manifest", () => {
  const download = stepContaining(cleanupAction, "uses: actions/download-artifact", 4);
  assert.match(download, /if: always\(\) && env\.E2E_MANIFEST_PATH == ''/);
  assert.match(download, /artifact-ids: \$\{\{ inputs\.handoff-artifact-id \}\}/);
  const restore = stepContaining(cleanupAction, "staging-e2e-handoff.mjs unpack", 4);
  assert.match(restore, /if: always\(\) && env\.E2E_MANIFEST_PATH == ''/);
  assert.match(restore, /field-e2e-handoff\.bin/);
  assert.match(restore, /echo "E2E_MANIFEST_PATH=.*manifest\.json" >>"\$GITHUB_ENV"/);
  const runtime = stepContaining(cleanupAction, "uses: denoland/setup-deno@", 4);
  assert.match(runtime, /if: always\(\)/);
  const clean = stepContaining(cleanupAction, "cleanup_staging.ts", 4);
  assert.match(clean, /test -s "\$E2E_MANIFEST_PATH"/);
  assert.match(clean, /if: always\(\)/);
  assert.doesNotMatch(cleanupAction, /continue-on-error|\|\| true/);
  const androidRestore = stepContaining(job("android-staging-e2e"), "staging-e2e-handoff.mjs unpack");
  assert.ok(androidRestore.indexOf("E2E_MANIFEST_PATH=") < androidRestore.indexOf('test -s "$RUNNER_TEMP/field-e2e-restored/player-journey.apk"'));
  const browserRestore = stepContaining(job("browser-staging-e2e"), "staging-e2e-handoff.mjs unpack");
  assert.ok(browserRestore.indexOf("E2E_MANIFEST_PATH=") < browserRestore.indexOf('password="$(cat'));
});

test("secret-free always-run gate requires the complete declared plan", () => {
  const gate = job("deploy-staging");
  assert.deepEqual(needs("deploy-staging").sort(), ["preflight", ...Object.keys(jobFlags)].sort());
  assert.match(gate, /^    if: always\(\)$/m);
  assert.doesNotMatch(gate, /^    environment:|secrets\.|cleanup_staging\.ts|deployments: write|gh api/m);
  assert.match(gate, /permissions:\n      contents: read/);
  const check = stepContaining(gate, "ci-results.mjs");
  assert.match(check, /CI_PLAN: \$\{\{ toJSON\(needs\.preflight\.outputs\) \}\}/);
  assert.match(check, /CI_RESULTS: \$\{\{ toJSON\(needs\) \}\}/);
  assert.match(check, /run: node \.github\/scripts\/ci-results\.mjs/);
  assert.doesNotMatch(check, /continue-on-error|if:/);
});

test("only verified automatic staging releases receive a deployment-write token", () => {
  const record = job("record-staging");
  assert.deepEqual(needs("record-staging"), ["preflight", "deploy-staging"]);
  assert.match(record, /github\.event_name == 'push'/);
  assert.match(record, /github\.ref == 'refs\/heads\/staging'/);
  assert.match(record, /needs\.preflight\.outputs\.release == 'true'/);
  assert.match(record, /needs\.deploy-staging\.result == 'success'/);
  assert.match(record, /deployments: write/);
  assert.match(record, /GH_TOKEN: \$\{\{ github\.token \}\}/);
  assert.doesNotMatch(record, /always\(\)|continue-on-error|actions\/checkout|uses: \.\/|secrets\.|run: (?:bash|node) \.github/);
});

test("TestFlight and PWA remain behind the complete E2E gate", () => {
  for (const id of ["upload-testflight-staging", "deploy-referee-staging"]) {
    assert.deepEqual(needs(id), ["record-staging"]);
    assert.match(job(id), /needs\.record-staging\.result == 'success'/);
    assert.match(job(id), /github\.event_name == 'push'/);
    assert.match(job(id), /github\.ref == 'refs\/heads\/staging'/);
  }
});

test("cross-job handoff only uploads ciphertext with short retention", () => {
  const prepare = job("prepare-staging-e2e");
  assert.match(prepare, /staging-e2e-handoff\.mjs pack/);
  assert.match(prepare, /path: \$\{\{ runner\.temp \}\}\/field-e2e-handoff\.bin/);
  assert.match(prepare, /retention-days: 1/);
  assert.doesNotMatch(prepare, /path:.*(?:password\.txt|manifest\.json|\.apk)/);
});

test("public E2E failure artifacts only upload authenticated ciphertext", () => {
  for (const [id, purpose] of [["android-staging-e2e", "android"], ["browser-staging-e2e", "browser"]]) {
    const source = job(id);
    assert.match(source, /STAGING_DIAGNOSTICS_KEY: \$\{\{ secrets\.SUPABASE_SERVICE_ROLE_KEY \}\}/);
    assert.match(source, /staging-diagnostics\.mjs encrypt/);
    assert.match(source, new RegExp(`--context "\\$GITHUB_RUN_ID:${purpose}"`));
    assert.match(source, /umask 077/);
    assert.match(source, /trap 'rm -f "\$archive"' EXIT/);
    const upload = source.slice(source.indexOf(`      - name: Upload encrypted`));
    assert.match(upload, /if: always\(\) && steps\.[a-z-]+\.outputs\.created == 'true'/);
    assert.match(upload, new RegExp(`path: \\$\\{\\{ runner\\.temp \\}\\}/field-${purpose}-diagnostics\\.bin`));
    assert.doesNotMatch(upload, /path:.*(?:e2e-artifacts|test-results|playwright-report|tar\.gz)/);
    assert.match(upload, /retention-days: 7/);
  }
});

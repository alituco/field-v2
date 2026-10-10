import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import test from "node:test";

const workflow = readFileSync(new URL("../workflows/ci.yml", import.meta.url), "utf8");
const emulator = readFileSync(new URL("../actions/staging-android-emulator/action.yml", import.meta.url), "utf8");
const preflight = readFileSync(new URL("../workflows/android-emulator-preflight.yml", import.meta.url), "utf8");

// Syntax is checked separately with actionlint. These contracts prevent future
// refactors from moving compilation back beside the emulator or weakening gates.
function job(id) {
  const start = workflow.indexOf(`\n  ${id}:\n`);
  assert.notEqual(start, -1, `Missing job ${id}`);
  const rest = workflow.slice(start + 1);
  const next = rest.slice(1).search(/^  [a-z][a-z0-9-]*:\s*$/m);
  return next === -1 ? rest : rest.slice(0, next + 1);
}

test("all five base checks gate staging preparation", () => {
  const prepare = job("prepare-staging-e2e");
  for (const id of ["flutter", "flutter-ios", "referee", "broadcaster", "database"]) {
    job(id);
    assert.match(prepare, new RegExp(`      - ${id}\\n`));
  }
  assert.match(prepare, /github\.event_name == 'push' && github\.ref == 'refs\/heads\/staging'/);
});

test("APK compilation is isolated from browser dependencies and emulator", () => {
  const prepare = job("prepare-staging-e2e");
  assert.match(prepare, /run-staging-android-e2e\.sh build-only/);
  assert.doesNotMatch(prepare, /playwright install|npm ci|uses: .*staging-android-emulator/);
});

test("Android build and E2E preparation share dependency-only Gradle caching", () => {
  for (const id of ["flutter", "prepare-staging-e2e"]) {
    const source = job(id);
    assert.match(source, /cache: gradle/);
    assert.match(source, /mobile\/android\/\*\*\/\*\.gradle\*/);
    assert.match(source, /mobile\/android\/gradle\/wrapper\/gradle-wrapper\.properties/);
  }
});

test("fresh Android job only executes the encrypted prebuilt binary", () => {
  const android = job("android-staging-e2e");
  assert.match(android, /needs: prepare-staging-e2e/);
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
  assert.match(browser, /needs: \[prepare-staging-e2e, android-staging-e2e\]/);
  assert.match(browser, /npm run test:e2e/);
  assert.match(browser, /--phase=complete/);
});

test("fixture cleanup survives failed or skipped journeys", () => {
  const gate = job("deploy-staging");
  assert.match(gate, /needs: \[prepare-staging-e2e, android-staging-e2e, browser-staging-e2e\]/);
  assert.match(gate, /if: always\(\) && github\.event_name == 'push'/);
  assert.match(gate, /cleanup_staging\.ts/);
  assert.match(job("prepare-staging-e2e"), /if: \(failure\(\) \|\| cancelled\(\)\) && steps\.handoff-upload\.outcome != 'success'/);
  assert.ok(gate.indexOf("cleanup_staging.ts") < gate.indexOf("Require every staging E2E stage to pass"));
});

test("green cleanup cannot conceal a failed, cancelled, or skipped journey", () => {
  const gate = job("deploy-staging");
  const check = gate.slice(gate.indexOf("      - name: Require every staging E2E stage to pass"), gate.indexOf("      - name: Record successful staging deployment"));
  const script = check.split("        run: |\n")[1].replace(/^          /gm, "");
  for (const result of ["failure", "cancelled", "skipped"]) {
    for (const key of ["PREPARE_RESULT", "ANDROID_RESULT", "BROWSER_RESULT"]) {
      const env = { PREPARE_RESULT: "success", ANDROID_RESULT: "success", BROWSER_RESULT: "success", [key]: result };
      assert.notEqual(spawnSync("bash", ["-c", script], { env, encoding: "utf8" }).status, 0);
    }
  }
  assert.equal(spawnSync("bash", ["-c", script], {
    env: { PREPARE_RESULT: "success", ANDROID_RESULT: "success", BROWSER_RESULT: "success" },
  }).status, 0);
});

test("TestFlight and PWA remain behind the complete E2E gate", () => {
  for (const id of ["upload-testflight-staging", "deploy-referee-staging"]) {
    assert.match(job(id), /needs: deploy-staging/);
    assert.match(job(id), /needs\.deploy-staging\.result == 'success'/);
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

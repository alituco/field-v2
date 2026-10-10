import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const rootGradle = readFileSync(new URL("../../mobile/android/build.gradle.kts", import.meta.url), "utf8");
const appGradle = readFileSync(new URL("../../mobile/android/app/build.gradle.kts", import.meta.url), "utf8");

test("payment-only Stripe excludes only its restricted optional Google artifact", () => {
  assert.match(rootGradle, /if \(name == "stripe_android"\)\s*\{[\s\S]*?configurations\.configureEach\s*\{[\s\S]*?exclude\(\s*group = "com\.google\.android\.gms",\s*module = "play-services-tapandpay",/);
  assert.doesNotMatch(rootGradle, /module = "stripe-android-issuing-push-provisioning"/);
  assert.doesNotMatch(rootGradle, /module = "play-services-wallet"/);
});

test("the optional dependency workaround never disables release lint", () => {
  for (const source of [rootGradle, appGradle]) {
    assert.doesNotMatch(source, /(?:checkReleaseBuilds|isCheckReleaseBuilds|abortOnError|isAbortOnError)\s*(?:=\s*)?false/);
    assert.doesNotMatch(source, /(?:lintVital|lint)[\s\S]{0,100}enabled\s*=\s*false/);
  }
});

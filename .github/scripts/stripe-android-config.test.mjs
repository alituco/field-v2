import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const rootGradle = readFileSync(new URL("../../mobile/android/build.gradle.kts", import.meta.url), "utf8");
const appGradle = readFileSync(new URL("../../mobile/android/app/build.gradle.kts", import.meta.url), "utf8");
const manifest = readFileSync(new URL("../../mobile/android/app/src/main/AndroidManifest.xml", import.meta.url), "utf8");

test("Android enables the Google Pay API at the application level", () => {
  const application = manifest.match(/<application\b[^>]*>([\s\S]*?)<\/application>/)?.[1];
  assert.ok(application, "Android application configuration must exist");
  // Activity-only metadata does not enable the wallet API for the application.
  const applicationMetadata = application.replace(/<activity\b[\s\S]*?<\/activity>/g, "");
  assert.match(applicationMetadata, /<meta-data\s+android:name="com\.google\.android\.gms\.wallet\.api\.enabled"\s+android:value="true"\s*\/>/);
});

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

import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const read=(path)=>readFileSync(new URL(`../../${path}`,import.meta.url),'utf8');
test('push-only iOS plist retains the complete base config and adds required background modes',()=>{
  const base=read('mobile/ios/Runner/Info.plist');
  const push=read('mobile/ios/Runner/Info-staging-push.plist');
  const modes=push.match(/\t<key>UIBackgroundModes<\/key>\n\t<array>\n\t\t<string>fetch<\/string>\n\t\t<string>remote-notification<\/string>\n\t<\/array>\n/);
  assert.ok(modes,'The opt-in push plist needs fetch and remote-notification');
  assert.equal(push.replace(modes[0],''),base,'All base permissions, callbacks and SDK defaults must stay synchronized');
  assert.doesNotMatch(base,/UIBackgroundModes/);
  assert.doesNotMatch(base,/<key>FirebaseAppDelegateProxyEnabled<\/key>\s*<false\/>/);
  assert.match(push,/<key>FirebaseMessagingAutoInitEnabled<\/key>\s*<false\/>/);
});
test('push entitlements and plist are an explicit staging opt-in, not a default profile change',()=>{
  const example=read('mobile/ios/Flutter/Push-staging.xcconfig.example');
  assert.match(example,/CODE_SIGN_ENTITLEMENTS = Runner\/Runner-staging-push\.entitlements/);
  assert.match(example,/INFOPLIST_FILE = Runner\/Info-staging-push\.plist/);
  assert.match(example,/FIELDRUSH_APNS_ENVIRONMENT = production/);
  assert.match(read('mobile/ios/Runner/Runner-staging-push.entitlements'),/<key>aps-environment<\/key>\s*<string>\$\(FIELDRUSH_APNS_ENVIRONMENT\)<\/string>/);
  assert.doesNotMatch(read('mobile/ios/Runner/Runner-staging.entitlements'),/aps-environment/);
  assert.doesNotMatch(read('mobile/ios/Runner.xcodeproj/project.pbxproj'),/Runner-staging-push|Info-staging-push/);
  assert.match(read('mobile/ios/Runner/Runner-staging-push.entitlements'),/merchant.com.alialtaraif.fieldrush/);
  for(const flavor of ['staging','production']) for(const mode of ['Debug','Profile','Release']){
    assert.doesNotMatch(read(`mobile/ios/Flutter/${mode}-${flavor}.xcconfig`),/Info-staging-push|Runner-staging-push|Push-staging\.xcconfig/);
  }
});
test('native SDK auto-init and the app feature flag default off without changing Android identity',()=>{
  const android=read('mobile/android/app/src/main/AndroidManifest.xml');
  assert.match(android,/POST_NOTIFICATIONS/);
  assert.match(android,/firebase_messaging_auto_init_enabled" android:value="false"/);
  assert.match(read('mobile/android/app/build.gradle.kts'),/applicationId = "com\.field\.field"/);
  assert.match(read('mobile/android/app/build.gradle.kts'),/applicationIdSuffix = "\.staging"/);
  const options=read('mobile/lib/src/notifications/firebase_staging_options.dart');
  assert.match(options,/Android: com.field.field.staging/);
  assert.doesNotMatch(options,/BEGIN PRIVATE KEY|private_key|service_account/);
  assert.match(read('mobile/.env.example'),/^PUSH_NOTIFICATIONS_ENABLED=false$/m);
});

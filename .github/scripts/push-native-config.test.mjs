import assert from 'node:assert/strict';
import {mkdtempSync,readFileSync,mkdirSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
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
  assert.match(example,/FIELDRUSH_IOS_ENTITLEMENTS_FILE = Runner\/Runner-staging-push\.entitlements/);
  assert.match(example,/FIELDRUSH_IOS_INFOPLIST_FILE = Runner\/Info-staging-push\.plist/);
  assert.match(example,/FIELDRUSH_APNS_ENVIRONMENT = production/);
  assert.match(read('mobile/ios/Runner/Runner-staging-push.entitlements'),/<key>aps-environment<\/key>\s*<string>\$\(FIELDRUSH_APNS_ENVIRONMENT\)<\/string>/);
  assert.doesNotMatch(read('mobile/ios/Runner/Runner-staging.entitlements'),/aps-environment/);
  assert.doesNotMatch(read('mobile/ios/Runner.xcodeproj/project.pbxproj'),/Runner-staging-push|Info-staging-push/);
  assert.match(read('mobile/ios/Runner/Runner-staging-push.entitlements'),/merchant.com.alialtaraif.fieldrush/);
  for(const flavor of ['staging','production']) for(const mode of ['Debug','Profile','Release']){
    assert.doesNotMatch(read(`mobile/ios/Flutter/${mode}-${flavor}.xcconfig`),/Info-staging-push|Runner-staging-push|Push-staging\.xcconfig/);
  }
});
test('the staging TestFlight archive keeps its explicit push override without changing Pods signing settings',()=>{
  const upload=read('.github/scripts/upload-staging-testflight.sh');
  assert.match(upload,/readonly expected_ref="refs\/heads\/staging"/);
  assert.match(upload,/--dart-define=APP_ENV=staging/);
  assert.match(upload,/--dart-define=PUSH_NOTIFICATIONS_ENABLED=true/);
  assert.match(upload,/FIELDRUSH_IOS_INFOPLIST_FILE=Runner\/Info-staging-push\.plist/);
  assert.match(upload,/FIELDRUSH_IOS_ENTITLEMENTS_FILE=Runner\/Runner-staging-push\.entitlements/);
  assert.match(upload,/FIELDRUSH_APNS_ENVIRONMENT=production/);
  assert.doesNotMatch(upload,/(?:^|\s)(?:INFOPLIST_FILE|CODE_SIGN_ENTITLEMENTS)=/);
  assert.match(upload,/profile_apns_environment.*\nif \[\[ "\$profile_apns_environment" != production \]\]/);
  const release=read('mobile/ios/Flutter/Release-staging.xcconfig');
  assert.match(release,/FIELDRUSH_IOS_INFOPLIST_FILE = Runner\/Info.plist/);
  assert.match(release,/FIELDRUSH_IOS_ENTITLEMENTS_FILE = Runner\/Runner-staging.entitlements/);
  assert.match(release,/CODE_SIGN_ENTITLEMENTS = \$\(FIELDRUSH_IOS_ENTITLEMENTS_FILE\)/);
  const project=read('mobile/ios/Runner.xcodeproj/project.pbxproj');
  const configurations=[...project.matchAll(/\t\t[0-9A-F]+ \/\* ([^*]+) \*\/ = \{\n\t\t\tisa = XCBuildConfiguration;[\s\S]*?\n\t\t\};/g)];
  const optedIn=configurations.filter(([source])=>source.includes('$(FIELDRUSH_IOS_INFOPLIST_FILE)'));
  assert.equal(optedIn.length,2);
  const staging=optedIn.find(([,name])=>name==='Release-staging');
  const production=optedIn.find(([,name])=>name==='Release-production');
  assert.ok(staging);
  assert.ok(production);
  assert.match(staging[0],/baseConfigurationReference = .*\/\* Release-staging.xcconfig \*\//);
  assert.match(production[0],/baseConfigurationReference = .*\/\* Release-production.xcconfig \*\//);
  assert.ok(upload.indexOf('verify_push_app "$archive_path/')<upload.indexOf('-exportArchive'));
  assert.ok(upload.indexOf('verify_push_app "$signing_root/exported-ipa/')<upload.indexOf('--upload-app'));
});
test('signed app validation rejects missing push, Apple Pay, background modes, or consent gating',()=>{
  const upload=read('.github/scripts/upload-staging-testflight.sh');
  const functionSource=upload.match(/verify_push_app\(\) \{[\s\S]*?\n\}/)?.[0];
  assert.ok(functionSource);
  const root=mkdtempSync(join(tmpdir(),'fieldrush-push-signing-'));
  try{
    const bin=join(root,'bin');
    const app=join(root,'Runner.app');
    const signing=join(root,'signing');
    for(const directory of [bin,app,signing]) mkdirSync(directory);
    const plistBuddy=join(bin,'PlistBuddy');
    writeFileSync(plistBuddy,`#!/usr/bin/env python3
import plistlib,sys
try:
    with open(sys.argv[3], 'rb') as source: value=plistlib.load(source)
    for key in sys.argv[2].removeprefix('Print :').split(':'): value=value[key]
    if isinstance(value, list):
        print('Array {')
        for item in value: print('    '+str(item))
        print('}')
    else: print(str(value).lower() if isinstance(value,bool) else value)
except (KeyError, FileNotFoundError): sys.exit(1)
`,{mode:0o755});
    writeFileSync(join(bin,'codesign'),'#!/usr/bin/env bash\ncat "$TEST_ENTITLEMENTS"\n',{mode:0o755});
    const info=read('mobile/ios/Runner/Info-staging-push.plist').replaceAll('$(PRODUCT_BUNDLE_IDENTIFIER)','com.alialtaraif.field.staging');
    const entitlementXml=(aps='production',merchant=true)=>`<?xml version="1.0"?><plist version="1.0"><dict>
<key>application-identifier</key><string>69B646V2WM.com.alialtaraif.field.staging</string>
${aps?`<key>aps-environment</key><string>${aps}</string>`:''}
${merchant?'<key>com.apple.developer.in-app-payments</key><array><string>merchant.com.alialtaraif.fieldrush</string></array>':''}
</dict></plist>`;
    const scenarios=[
      {name:'valid',info,entitlements:entitlementXml(),success:true},
      {name:'missing push',info,entitlements:entitlementXml(''),error:/production APNs/},
      {name:'sandbox signing',info,entitlements:entitlementXml('development'),error:/production APNs/},
      {name:'wrong app',info:info.replace('com.alialtaraif.field.staging','com.alialtaraif.field'),entitlements:entitlementXml(),error:/Field Staging/},
      {name:'missing Apple Pay',info,entitlements:entitlementXml('production',false),error:/Apple Pay entitlement/},
      {name:'missing background mode',info:info.replace('<string>remote-notification</string>',''),entitlements:entitlementXml(),error:/remote-notification.*background mode/},
      {name:'premature auto-init',info:info.replace(/(<key>FirebaseMessagingAutoInitEnabled<\/key>\s*)<false\/>/,'$1<true/>'),entitlements:entitlementXml(),error:/auto-init off until in-app consent/}
    ];
    const entitlements=join(root,'entitlements.plist');
    for(const scenario of scenarios){
      writeFileSync(join(app,'Info.plist'),scenario.info);
      writeFileSync(entitlements,scenario.entitlements);
      const result=spawnSync('bash',['-c',`${functionSource.replaceAll('/usr/libexec/PlistBuddy','"$TEST_PLIST_BUDDY"')}\nverify_push_app "$TEST_APP" archive`],{
        encoding:'utf8',env:{...process.env,PATH:`${bin}:${process.env.PATH}`,TEST_PLIST_BUDDY:plistBuddy,TEST_APP:app,TEST_ENTITLEMENTS:entitlements,
          signing_root:signing,expected_team_id:'69B646V2WM',expected_bundle_id:'com.alialtaraif.field.staging',APPLE_MERCHANT_ID:'merchant.com.alialtaraif.fieldrush'}
      });
      if(scenario.success) assert.equal(result.status,0,`${scenario.name}: ${result.stdout}${result.stderr}`);
      else{
        assert.equal(result.status,1,scenario.name);
        assert.match(result.stdout,scenario.error,scenario.name);
      }
    }
  }finally{rmSync(root,{recursive:true,force:true});}
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

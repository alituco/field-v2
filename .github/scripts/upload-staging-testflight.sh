#!/usr/bin/env bash

set -euo pipefail

readonly expected_ref="refs/heads/staging"
readonly expected_supabase_url="https://nfdkdhdevpstfspazbfn.supabase.co"
readonly expected_team_id="69B646V2WM"
readonly expected_bundle_id="com.alialtaraif.field.staging"
readonly expected_profile_name="Field Staging App Store"

required_variables=(
  APP_STORE_CONNECT_ISSUER_ID
  APP_STORE_CONNECT_KEY_ID
  APP_STORE_CONNECT_PRIVATE_KEY
  IOS_DISTRIBUTION_CERTIFICATE_BASE64
  IOS_DISTRIBUTION_CERTIFICATE_PASSWORD
  IOS_STAGING_PROVISIONING_PROFILE_BASE64
  SUPABASE_URL
  SUPABASE_PUBLISHABLE_KEY
  APPLE_TEAM_ID
  IOS_STAGING_BUNDLE_ID
  STRIPE_PUBLISHABLE_KEY
  APPLE_MERCHANT_ID
  GITHUB_REF
  GITHUB_RUN_NUMBER
  GITHUB_RUN_ATTEMPT
  RUNNER_TEMP
  GITHUB_WORKSPACE
)

for variable_name in "${required_variables[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "::error::Missing required TestFlight value: $variable_name"
    exit 1
  fi
done

if [[ "$GITHUB_REF" != "$expected_ref" ]]; then
  echo "::error::TestFlight uploads are restricted to the staging branch."
  exit 1
fi
if [[ "$SUPABASE_URL" != "$expected_supabase_url" ]]; then
  echo "::error::The staging TestFlight build is not targeting Field Staging."
  exit 1
fi
if [[ "$APPLE_TEAM_ID" != "$expected_team_id" ]]; then
  echo "::error::The configured Apple team is not Field's Apple team."
  exit 1
fi
if [[ "$IOS_STAGING_BUNDLE_ID" != "$expected_bundle_id" ]]; then
  echo "::error::The configured bundle ID is not Field Staging."
  exit 1
fi
if [[ "$STRIPE_PUBLISHABLE_KEY" != pk_test_* || "$APPLE_MERCHANT_ID" != merchant.com.alialtaraif.fieldrush ]]; then
  echo "::error::Staging requires a Stripe test publishable key and the Fieldrush Apple Pay merchant ID."
  exit 1
fi

readonly signing_root="$RUNNER_TEMP/field-testflight-signing"
readonly certificate_path="$signing_root/FieldDistribution.p12"
readonly profile_source_path="$signing_root/FieldStaging.mobileprovision"
readonly profile_plist_path="$signing_root/FieldStaging.plist"
readonly api_keys_path="$signing_root/private_keys"
readonly api_key_path="$api_keys_path/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
readonly keychain_path="$RUNNER_TEMP/field-testflight.keychain-db"
readonly archive_path="$RUNNER_TEMP/FieldStaging.xcarchive"
readonly export_path="$RUNNER_TEMP/field-testflight-export"
readonly export_options_path="$signing_root/ExportOptions.plist"
readonly artifact_path="$GITHUB_WORKSPACE/mobile/build/testflight-artifacts"

mkdir -p "$signing_root" "$api_keys_path" "$export_path" "$artifact_path"

installed_profile_path=""
keychain_created=false
cleanup() {
  if [[ -n "$installed_profile_path" ]]; then
    rm -f "$installed_profile_path"
  fi
  if [[ "$keychain_created" == true ]]; then
    security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
  fi
  rm -rf "$signing_root"
}
trap cleanup EXIT

printf '%s' "$IOS_DISTRIBUTION_CERTIFICATE_BASE64" \
  | base64 --decode >"$certificate_path"
printf '%s' "$IOS_STAGING_PROVISIONING_PROFILE_BASE64" \
  | base64 --decode >"$profile_source_path"
printf '%s\n' "$APP_STORE_CONNECT_PRIVATE_KEY" >"$api_key_path"
chmod 600 "$certificate_path" "$profile_source_path" "$api_key_path"

if ! grep -q "BEGIN PRIVATE KEY" "$api_key_path" \
  || ! grep -q "END PRIVATE KEY" "$api_key_path"; then
  echo "::error::APP_STORE_CONNECT_PRIVATE_KEY is not the downloaded .p8 file contents."
  exit 1
fi

keychain_password="$(openssl rand -hex 32)"
echo "::add-mask::$keychain_password"
security create-keychain -p "$keychain_password" "$keychain_path"
keychain_created=true
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$certificate_path" \
  -k "$keychain_path" \
  -P "$IOS_DISTRIBUTION_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security
security set-key-partition-list \
  -S apple-tool:,apple: \
  -s \
  -k "$keychain_password" \
  "$keychain_path" >/dev/null
security list-keychains -d user -s "$keychain_path"

if ! security find-identity -v -p codesigning "$keychain_path" \
  | grep -q "Apple Distribution: Ali Altaraif ($expected_team_id)"; then
  echo "::error::The imported .p12 does not contain Field's Apple Distribution identity."
  exit 1
fi

security cms -D -i "$profile_source_path" >"$profile_plist_path"
profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$profile_plist_path")"
profile_uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$profile_plist_path")"
profile_team_id="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$profile_plist_path")"
profile_app_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$profile_plist_path")"
profile_expiration="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$profile_plist_path")"
profile_expiration_without_zone="$(awk '{print $1, $2, $3, $4, $6}' <<<"$profile_expiration")"

if [[ "$profile_name" != "$expected_profile_name" ]]; then
  echo "::error::Expected provisioning profile '$expected_profile_name', found '$profile_name'."
  exit 1
fi
if [[ "$profile_team_id" != "$expected_team_id" ]]; then
  echo "::error::The provisioning profile belongs to a different Apple team."
  exit 1
fi
if [[ "$profile_app_identifier" != "$expected_team_id.$expected_bundle_id" ]]; then
  echo "::error::The provisioning profile does not belong to Field Staging."
  exit 1
fi
if ! /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.in-app-payments' "$profile_plist_path" \
  | awk '{$1=$1; print}' | grep -Fxq "$APPLE_MERCHANT_ID"; then
  echo "::error::Regenerate the staging App Store profile with the Fieldrush Apple Pay merchant enabled."
  exit 1
fi
profile_apns_environment="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:aps-environment' "$profile_plist_path" 2>/dev/null || true)"
if [[ "$profile_apns_environment" != production ]]; then
  echo "::error::Regenerate the staging App Store profile with production APNs and the Fieldrush Apple Pay merchant enabled."
  exit 1
fi
if [[ "$(date -j -f '%a %b %d %T %Y' "$profile_expiration_without_zone" '+%s')" -le "$(date '+%s')" ]]; then
  echo "::error::The staging provisioning profile has expired."
  exit 1
fi

profiles_path="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$profiles_path"
installed_profile_path="$profiles_path/$profile_uuid.mobileprovision"
cp "$profile_source_path" "$installed_profile_path"

build_name="$(awk '/^version:/ {print $2; exit}' "$GITHUB_WORKSPACE/mobile/pubspec.yaml")"
build_name="${build_name%%+*}"
build_number="$((GITHUB_RUN_NUMBER * 100 + GITHUB_RUN_ATTEMPT))"
if [[ ! "$build_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::Could not derive an iOS version from mobile/pubspec.yaml."
  exit 1
fi

cat >"$export_options_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>method</key>
  <string>app-store-connect</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>$expected_bundle_id</key>
    <string>$profile_name</string>
  </dict>
  <key>signingCertificate</key>
  <string>Apple Distribution</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>teamID</key>
  <string>$expected_team_id</string>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
EOF

echo "Building Field Staging $build_name ($build_number) for TestFlight."
cd "$GITHUB_WORKSPACE/mobile"
flutter pub get
flutter build ios \
  --release \
  --no-codesign \
  --config-only \
  --flavor staging \
  --build-name "$build_name" \
  --build-number "$build_number" \
  --dart-define=APP_ENV=staging \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_PUBLISHABLE_KEY="$SUPABASE_PUBLISHABLE_KEY" \
  --dart-define=STRIPE_PUBLISHABLE_KEY="$STRIPE_PUBLISHABLE_KEY" \
  --dart-define=APPLE_MERCHANT_ID="$APPLE_MERCHANT_ID" \
  --dart-define=DEV=false \
  --dart-define=EMAIL_DELIVERY_ENABLED=true \
  --dart-define=PROFILE_SWITCHER_ENABLED=true \
  --dart-define=PUSH_NOTIFICATIONS_ENABLED=true

(
  cd ios
  pod install
  set -o pipefail
  xcodebuild \
    -workspace Runner.xcworkspace \
    -scheme staging \
    -configuration Release-staging \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive_path" \
    FIELDRUSH_IOS_INFOPLIST_FILE=Runner/Info-staging-push.plist \
    FIELDRUSH_IOS_ENTITLEMENTS_FILE=Runner/Runner-staging-push.entitlements \
    FIELDRUSH_APNS_ENVIRONMENT=production \
    archive \
    2>&1 | tee "$artifact_path/archive.log"
)

verify_push_app() {
  local app_path="$1"
  local stage="$2"
  local info_path="$app_path/Info.plist"
  local entitlements_path="$signing_root/$stage-entitlements.plist"
  if [[ ! -d "$app_path" ]]; then
    echo "::error::The $stage is missing the Field Staging app."
    exit 1
  fi
  if ! codesign --display --entitlements :- "$app_path" >"$entitlements_path" 2>"$signing_root/$stage-codesign.log"; then
    echo "::error::Could not inspect the signed $stage entitlements."
    exit 1
  fi
  local app_identifier apns_environment bundle_id auto_init
  app_identifier="$(/usr/libexec/PlistBuddy -c 'Print :application-identifier' "$entitlements_path" 2>/dev/null || true)"
  apns_environment="$(/usr/libexec/PlistBuddy -c 'Print :aps-environment' "$entitlements_path" 2>/dev/null || true)"
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_path" 2>/dev/null || true)"
  auto_init="$(/usr/libexec/PlistBuddy -c 'Print :FirebaseMessagingAutoInitEnabled' "$info_path" 2>/dev/null || true)"
  if [[ "$app_identifier" != "$expected_team_id.$expected_bundle_id" || "$bundle_id" != "$expected_bundle_id" || "$apns_environment" != production ]]; then
    echo "::error::The $stage must be signed for Field Staging with production APNs."
    exit 1
  fi
  if ! /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.in-app-payments' "$entitlements_path" \
    | awk '{$1=$1; print}' | grep -Fxq "$APPLE_MERCHANT_ID"; then
    echo "::error::The $stage is missing the Fieldrush Apple Pay entitlement."
    exit 1
  fi
  for mode in fetch remote-notification; do
    if ! /usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes' "$info_path" \
      | awk '{$1=$1; print}' | grep -Fxq "$mode"; then
      echo "::error::The $stage is missing the '$mode' background mode."
      exit 1
    fi
  done
  if [[ "$auto_init" != false ]]; then
    echo "::error::The $stage must keep Firebase Messaging auto-init off until in-app consent."
    exit 1
  fi
}

verify_push_app "$archive_path/Products/Applications/Runner.app" archive

set -o pipefail
xcodebuild \
  -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options_path" \
  2>&1 | tee "$artifact_path/export.log"

ipa_count="$(find "$export_path" -maxdepth 1 -type f -name '*.ipa' | wc -l | tr -d ' ')"
if [[ "$ipa_count" -ne 1 ]]; then
  echo "::error::Expected one exported IPA, found $ipa_count."
  exit 1
fi
ipa_path="$(find "$export_path" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
unzip -q "$ipa_path" -d "$signing_root/exported-ipa"
verify_push_app "$signing_root/exported-ipa/Payload/Runner.app" exported-ipa

export API_PRIVATE_KEYS_DIR="$api_keys_path"
set -o pipefail
xcrun altool \
  --upload-app \
  --type ios \
  --file "$ipa_path" \
  --apiKey "$APP_STORE_CONNECT_KEY_ID" \
  --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID" \
  2>&1 | tee "$artifact_path/upload.log"

echo "Field Staging $build_name ($build_number) was accepted by App Store Connect."
echo "Apple will process it, then TestFlight will distribute it to the '${TESTFLIGHT_INTERNAL_GROUP:-admins}' internal group."

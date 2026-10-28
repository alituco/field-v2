#!/usr/bin/env bash
# Upload a production binary to App Store Connect; never submit or release it.
set -euo pipefail
umask 077

readonly expected_ref="refs/heads/prod"
readonly expected_supabase_url="https://zjsjuuhborxrlmdcpvlj.supabase.co"
readonly expected_team_id="69B646V2WM"
readonly expected_bundle_id="com.alialtaraif.field"
readonly expected_profile_name="Fieldrush Production App Store"
readonly expected_merchant_id="merchant.com.alialtaraif.fieldrush.production"

fail() { echo "::error::$1" >&2; exit 1; }
if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != --check-inputs ) ]]; then
  fail "The only supported option is --check-inputs."
fi

required_variables=(
  APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_PRIVATE_KEY
  IOS_DISTRIBUTION_CERTIFICATE_BASE64 IOS_DISTRIBUTION_CERTIFICATE_PASSWORD
  IOS_PRODUCTION_PROVISIONING_PROFILE_BASE64
  SUPABASE_URL SUPABASE_PUBLISHABLE_KEY STRIPE_PUBLISHABLE_KEY
  APPLE_TEAM_ID IOS_PRODUCTION_BUNDLE_ID APPLE_MERCHANT_ID
  PRODUCTION_EMAIL_DELIVERY_ENABLED PRODUCTION_PUSH_NOTIFICATIONS_ENABLED
  PRODUCTION_RELEASE_CONFIRMATION PRODUCTION_BACKEND_CONFIRMATION
  GITHUB_EVENT_NAME GITHUB_REF GITHUB_RUN_NUMBER GITHUB_RUN_ATTEMPT
  RUNNER_TEMP GITHUB_WORKSPACE
)
for variable_name in "${required_variables[@]}"; do
  [[ -n "${!variable_name:-}" ]] || fail "Missing required production iOS value: $variable_name"
done

[[ "$GITHUB_EVENT_NAME" == workflow_dispatch && "$GITHUB_REF" == "$expected_ref" ]] \
  || fail "Production iOS uploads require a manual dispatch from prod."
[[ "$PRODUCTION_RELEASE_CONFIRMATION" == BUILD_PRODUCTION_IOS ]] \
  || fail "Confirm the production iOS build with BUILD_PRODUCTION_IOS."
[[ "$PRODUCTION_BACKEND_CONFIRMATION" == PRODUCTION_BACKEND_READY_FOR_TESTFLIGHT ]] \
  || fail "Confirm production backend configuration and health are ready for internal TestFlight qualification with PRODUCTION_BACKEND_READY_FOR_TESTFLIGHT."
[[ "$SUPABASE_URL" == "$expected_supabase_url" ]] \
  || fail "The production app must target Field Production."
[[ "$APPLE_TEAM_ID" == "$expected_team_id" && "$IOS_PRODUCTION_BUNDLE_ID" == "$expected_bundle_id" ]] \
  || fail "The Apple team and Bundle ID must identify Field Production."
[[ "$STRIPE_PUBLISHABLE_KEY" == pk_live_* && "$APPLE_MERCHANT_ID" == "$expected_merchant_id" ]] \
  || fail "Production requires a Stripe live publishable key and the Fieldrush Apple Pay merchant."
[[ "$SUPABASE_PUBLISHABLE_KEY" == sb_publishable_* || "$SUPABASE_PUBLISHABLE_KEY" == eyJ* ]] \
  || fail "Use the production Supabase publishable/anon key in the mobile build."
python3 - <<'PY'
import base64, json, os, sys
key = os.environ["SUPABASE_PUBLISHABLE_KEY"]
if not key.startswith("sb_publishable_"):
    try:
        payload = key.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        if claims.get("role") != "anon" or claims.get("ref") != "zjsjuuhborxrlmdcpvlj":
            raise ValueError("wrong mobile key")
    except (ValueError, IndexError, TypeError, AttributeError):
        print("::error::Legacy mobile keys must be production anon keys, never service-role keys.", file=sys.stderr)
        sys.exit(1)
PY
for flag in PRODUCTION_EMAIL_DELIVERY_ENABLED PRODUCTION_PUSH_NOTIFICATIONS_ENABLED; do
  [[ "${!flag}" == true || "${!flag}" == false ]] || fail "$flag must be explicitly true or false."
done
[[ "$GITHUB_RUN_NUMBER" =~ ^[1-9][0-9]*$ && "$GITHUB_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]] \
  || fail "GitHub run number and attempt must be positive integers."
[[ "$GITHUB_RUN_ATTEMPT" -lt 100 ]] || fail "Use a new workflow run after 99 attempts to keep build numbers unique."
[[ "$APP_STORE_CONNECT_KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "The App Store Connect key ID is invalid."
[[ "$APP_STORE_CONNECT_PRIVATE_KEY" == *"BEGIN PRIVATE KEY"* && "$APP_STORE_CONNECT_PRIVATE_KEY" == *"END PRIVATE KEY"* ]] \
  || fail "APP_STORE_CONNECT_PRIVATE_KEY must contain the downloaded .p8 private key."

if [[ "$PRODUCTION_PUSH_NOTIFICATIONS_ENABLED" == true ]]; then
  for variable_name in PUSH_FIREBASE_API_KEY PUSH_FIREBASE_PROJECT_ID PUSH_FIREBASE_SENDER_ID PUSH_FIREBASE_IOS_APP_ID PUSH_FIREBASE_IOS_BUNDLE_ID; do
    [[ -n "${!variable_name:-}" ]] || fail "Production push requires $variable_name."
  done
  [[ "$PUSH_FIREBASE_API_KEY" == AIza* && "$PUSH_FIREBASE_PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,62}$ ]] \
    || fail "Production push requires valid public Firebase client configuration."
  [[ "$PUSH_FIREBASE_SENDER_ID" =~ ^[0-9]+$ && "$PUSH_FIREBASE_IOS_APP_ID" =~ ^1:[0-9]+:ios:[a-f0-9]+$ ]] \
    || fail "Production push has invalid Firebase sender/app identifiers."
  [[ "$PUSH_FIREBASE_IOS_APP_ID" == "1:$PUSH_FIREBASE_SENDER_ID:ios:"* && "$PUSH_FIREBASE_IOS_BUNDLE_ID" == "$expected_bundle_id" ]] \
    || fail "Production push Firebase sender and iOS Bundle ID must match the app."
  [[ "$PUSH_FIREBASE_IOS_APP_ID" != "1:756208653017:ios:9a38da8f44901e98f7a4c8" ]] \
    || fail "The staging Firebase iOS app cannot be used for production."
fi

if [[ "${1:-}" == --check-inputs ]]; then
  echo "Production iOS input checks passed; no credentials were imported and no build/upload ran."
  exit 0
fi

readonly script_root="$(cd "$(dirname "$0")" && pwd)"
readonly signing_root="$(mktemp -d "$RUNNER_TEMP/field-production-signing.XXXXXX")"
readonly certificate_path="$signing_root/FieldDistribution.p12"
readonly profile_source_path="$signing_root/FieldProduction.mobileprovision"
readonly profile_plist_path="$signing_root/FieldProduction.plist"
readonly api_keys_path="$signing_root/private_keys"
readonly api_key_path="$api_keys_path/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
readonly keychain_path="$signing_root/field-production.keychain-db"
readonly archive_path="$RUNNER_TEMP/FieldProduction.xcarchive"
readonly export_path="$signing_root/export"
readonly export_options_path="$signing_root/ExportOptions.plist"
readonly artifact_path="$GITHUB_WORKSPACE/mobile/build/production-testflight-artifacts"

installed_profile_path=""
keychain_created=false
previous_keychains=()
cleanup() {
  if [[ -n "$installed_profile_path" ]]; then
    if [[ -f "$signing_root/previous.mobileprovision" ]]; then
      cp "$signing_root/previous.mobileprovision" "$installed_profile_path" \
        || echo "::warning::Could not restore the previous installed provisioning profile." >&2
    else
      rm -f "$installed_profile_path"
    fi
  fi
  if [[ "$keychain_created" == true ]]; then
    security list-keychains -d user -s ${previous_keychains[@]+"${previous_keychains[@]}"} >/dev/null 2>&1 || true
    security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
  fi
  rm -rf "$signing_root"
}
trap cleanup EXIT
mkdir -p "$api_keys_path" "$export_path" "$artifact_path"

printf '%s' "$IOS_DISTRIBUTION_CERTIFICATE_BASE64" | base64 --decode >"$certificate_path"
printf '%s' "$IOS_PRODUCTION_PROVISIONING_PROFILE_BASE64" | base64 --decode >"$profile_source_path"
printf '%s\n' "$APP_STORE_CONNECT_PRIVATE_KEY" >"$api_key_path"
security cms -D -i "$profile_source_path" >"$profile_plist_path"
python3 "$script_root/validate-production-ios.py" profile "$profile_plist_path" "$PRODUCTION_PUSH_NOTIFICATIONS_ENABLED"
profile_uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$profile_plist_path")"

previous_keychain_listing="$(security list-keychains -d user)" \
  || fail "Could not read the original keychain search list."
while IFS= read -r keychain; do
  keychain="${keychain#*\"}"
  keychain="${keychain%\"*}"
  [[ -z "$keychain" ]] || previous_keychains+=("$keychain")
done <<<"$previous_keychain_listing"
keychain_password="$(openssl rand -hex 32)"
echo "::add-mask::$keychain_password"
security create-keychain -p "$keychain_password" "$keychain_path"
keychain_created=true
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$certificate_path" -k "$keychain_path" -P "$IOS_DISTRIBUTION_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain_path" >/dev/null
security list-keychains -d user -s "$keychain_path" ${previous_keychains[@]+"${previous_keychains[@]}"}
security find-identity -v -p codesigning "$keychain_path" | grep -q "Apple Distribution: Ali Altaraif ($expected_team_id)" \
  || fail "The certificate does not contain Field's Apple Distribution identity."

profiles_path="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$profiles_path"
profile_target_path="$profiles_path/$profile_uuid.mobileprovision"
if [[ -f "$profile_target_path" ]]; then
  # Do not let cleanup touch the original unless a complete backup exists.
  cp "$profile_target_path" "$signing_root/previous.mobileprovision.pending"
  mv "$signing_root/previous.mobileprovision.pending" "$signing_root/previous.mobileprovision"
fi
installed_profile_path="$profile_target_path"
cp "$profile_source_path" "$installed_profile_path"

build_name="$(awk '/^version:/ {print $2; exit}' "$GITHUB_WORKSPACE/mobile/pubspec.yaml")"
build_name="${build_name%%+*}"
build_number="$((GITHUB_RUN_NUMBER * 100 + GITHUB_RUN_ATTEMPT))"
[[ "$build_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Could not derive an iOS version from mobile/pubspec.yaml."

cat >"$export_options_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>destination</key><string>export</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>method</key><string>app-store-connect</string>
  <key>provisioningProfiles</key><dict><key>$expected_bundle_id</key><string>$expected_profile_name</string></dict>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>signingStyle</key><string>manual</string>
  <key>stripSwiftSymbols</key><true/>
  <key>teamID</key><string>$expected_team_id</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
EOF

push_arguments=()
plist_path=Runner/Info.plist
entitlements_path=Runner/Runner-production.entitlements
if [[ "$PRODUCTION_PUSH_NOTIFICATIONS_ENABLED" == true ]]; then
  plist_path=Runner/Info-production-push.plist
  entitlements_path=Runner/Runner-production-push.entitlements
  for variable_name in PUSH_FIREBASE_API_KEY PUSH_FIREBASE_PROJECT_ID PUSH_FIREBASE_SENDER_ID PUSH_FIREBASE_IOS_APP_ID PUSH_FIREBASE_IOS_BUNDLE_ID; do
    push_arguments+=("--dart-define=$variable_name=${!variable_name}")
  done
fi

echo "Building Field Production $build_name ($build_number); email=$PRODUCTION_EMAIL_DELIVERY_ENABLED, push=$PRODUCTION_PUSH_NOTIFICATIONS_ENABLED."
cd "$GITHUB_WORKSPACE/mobile"
flutter pub get
flutter build ios --release --no-codesign --config-only --flavor production \
  --build-name "$build_name" --build-number "$build_number" \
  --dart-define=APP_ENV=production \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_PUBLISHABLE_KEY="$SUPABASE_PUBLISHABLE_KEY" \
  --dart-define=STRIPE_PUBLISHABLE_KEY="$STRIPE_PUBLISHABLE_KEY" \
  --dart-define=APPLE_MERCHANT_ID="$APPLE_MERCHANT_ID" \
  --dart-define=DEV=false --dart-define=PROFILE_SWITCHER_ENABLED=false \
  --dart-define=EMAIL_DELIVERY_ENABLED="$PRODUCTION_EMAIL_DELIVERY_ENABLED" \
  --dart-define=PUSH_NOTIFICATIONS_ENABLED="$PRODUCTION_PUSH_NOTIFICATIONS_ENABLED" \
  ${push_arguments[@]+"${push_arguments[@]}"}
(
  cd ios
  pod install
  xcodebuild -workspace Runner.xcworkspace -scheme production -configuration Release-production \
    -destination 'generic/platform=iOS' -archivePath "$archive_path" \
    FIELDRUSH_IOS_INFOPLIST_FILE="$plist_path" \
    FIELDRUSH_IOS_ENTITLEMENTS_FILE="$entitlements_path" \
    archive 2>&1 | tee "$artifact_path/archive.log"
)

verify_app() {
  local app_path="$1"
  local stage="$2"
  [[ -d "$app_path" ]] || fail "The $stage is missing the Field Production app."
  codesign --verify --deep --strict "$app_path" 2>"$signing_root/$stage-verify.log" \
    || fail "The $stage failed signature validation."
  codesign --display --entitlements :- "$app_path" >"$signing_root/$stage-entitlements.plist" 2>"$signing_root/$stage-codesign.log" \
    || fail "Could not inspect the signed $stage entitlements."
  python3 "$script_root/validate-production-ios.py" app "$signing_root/$stage-entitlements.plist" \
    "$app_path/Info.plist" "$PRODUCTION_PUSH_NOTIFICATIONS_ENABLED" "$build_name" "$build_number"
}
verify_app "$archive_path/Products/Applications/Runner.app" archive
xcodebuild -exportArchive -archivePath "$archive_path" -exportPath "$export_path" \
  -exportOptionsPlist "$export_options_path" 2>&1 | tee "$artifact_path/export.log"
ipa_count="$(find "$export_path" -maxdepth 1 -type f -name '*.ipa' | wc -l | tr -d ' ')"
[[ "$ipa_count" -eq 1 ]] || fail "Expected exactly one exported production IPA."
ipa_path="$(find "$export_path" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
unzip -q "$ipa_path" -d "$signing_root/exported-ipa"
verify_app "$signing_root/exported-ipa/Payload/Runner.app" exported-ipa

export API_PRIVATE_KEYS_DIR="$api_keys_path"
xcrun altool --upload-app --type ios --file "$ipa_path" \
  --apiKey "$APP_STORE_CONNECT_KEY_ID" --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID" \
  2>&1 | tee "$artifact_path/upload.log"
echo "Field Production $build_name ($build_number) was accepted for App Store Connect processing (app 6827873998)."
echo "This upload does not submit the app to App Review or publish it."

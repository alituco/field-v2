#!/usr/bin/env bash
# Prepare a signed production AAB for a manual Play Console upload; never publish.
set -euo pipefail
umask 077

fail() { echo "::error::$1" >&2; exit 1; }
[[ "$#" -eq 0 || ( "$#" -eq 1 && "$1" == --check-inputs ) ]] \
  || fail "The only supported option is --check-inputs."

required_variables=(
  ANDROID_UPLOAD_KEYSTORE_BASE64 ANDROID_UPLOAD_STORE_PASSWORD
  ANDROID_UPLOAD_KEY_ALIAS ANDROID_UPLOAD_KEY_PASSWORD ANDROID_UPLOAD_CERTIFICATE_SHA256
  ANDROID_PRODUCTION_PACKAGE_ID SUPABASE_URL SUPABASE_PUBLISHABLE_KEY STRIPE_PUBLISHABLE_KEY
  PRODUCTION_EMAIL_DELIVERY_ENABLED PRODUCTION_ANDROID_PUSH_NOTIFICATIONS_ENABLED
  PRODUCTION_RELEASE_CONFIRMATION PRODUCTION_BACKEND_CONFIRMATION
  GITHUB_EVENT_NAME GITHUB_REF GITHUB_REPOSITORY GITHUB_SHA GITHUB_RUN_NUMBER GITHUB_RUN_ATTEMPT
  RUNNER_TEMP GITHUB_WORKSPACE ANDROID_HOME RUNNER_OS RUNNER_ENVIRONMENT
)
for variable_name in "${required_variables[@]}"; do
  [[ -n "${!variable_name:-}" ]] || fail "Missing required production Android value: $variable_name"
done

[[ "$GITHUB_EVENT_NAME" == workflow_dispatch && "$GITHUB_REF" == refs/heads/prod && "$GITHUB_REPOSITORY" == alituco/field-v2 ]] \
  || fail "Production Android signing requires a manual prod dispatch in alituco/field-v2."
[[ "$RUNNER_ENVIRONMENT" == github-hosted && "$RUNNER_OS" == Linux ]] \
  || fail "Production Android builds require a disposable GitHub-hosted Linux runner."
[[ "$PRODUCTION_RELEASE_CONFIRMATION" == BUILD_PRODUCTION_ANDROID && "$PRODUCTION_BACKEND_CONFIRMATION" == PRODUCTION_BACKEND_READY_FOR_ANDROID ]] \
  || fail "Confirm BUILD_PRODUCTION_ANDROID and PRODUCTION_BACKEND_READY_FOR_ANDROID."
[[ "$ANDROID_PRODUCTION_PACKAGE_ID" == gg.fieldrush.app && "$SUPABASE_URL" == https://zjsjuuhborxrlmdcpvlj.supabase.co ]] \
  || fail "The production bundle must identify Field Production and gg.fieldrush.app."
[[ "$STRIPE_PUBLISHABLE_KEY" == pk_live_* ]] || fail "Production requires a live Stripe publishable key."
[[ "$PRODUCTION_EMAIL_DELIVERY_ENABLED" == true || "$PRODUCTION_EMAIL_DELIVERY_ENABLED" == false ]] \
  || fail "Production email delivery must be explicitly true or false."
[[ "$PRODUCTION_ANDROID_PUSH_NOTIFICATIONS_ENABLED" == false ]] \
  || fail "Android push must remain off until its separate production qualification."
[[ "$ANDROID_UPLOAD_KEY_ALIAS" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ && "$GITHUB_SHA" =~ ^[a-f0-9]{40}$ ]] \
  || fail "Invalid Android signing alias or source revision."

# Reject server keys, mixed projects, invalid signing encodings and overflowing
# version codes without writing credentials or invoking any native/build tool.
python3 - <<'PY'
import base64, json, os, re, sys
def require(condition):
    if not condition:
        raise ValueError('invalid configuration')
try:
    env = os.environ
    key = env['SUPABASE_PUBLISHABLE_KEY']
    if not re.fullmatch(r'sb_publishable_[A-Za-z0-9_-]+', key):
        claims = json.loads(base64.urlsafe_b64decode(key.split('.')[1] + '=' * (-len(key.split('.')[1]) % 4)))
        require(key.startswith('eyJ') and claims.get('role') == 'anon' and claims.get('ref') == 'zjsjuuhborxrlmdcpvlj')
    encoded = ''.join(env['ANDROID_UPLOAD_KEYSTORE_BASE64'].split())
    require(encoded and 0 < len(base64.b64decode(encoded, validate=True)) <= 65536)
    require(all('\n' not in env[name] and '\r' not in env[name] for name in ('ANDROID_UPLOAD_STORE_PASSWORD', 'ANDROID_UPLOAD_KEY_PASSWORD')))
    require(re.fullmatch(r'(?:[A-Fa-f0-9]{64}|[A-Fa-f0-9]{2}(?::[A-Fa-f0-9]{2}){31})', env['ANDROID_UPLOAD_CERTIFICATE_SHA256']))
    for value in ('GITHUB_RUN_NUMBER', 'GITHUB_RUN_ATTEMPT'):
        require(re.fullmatch(r'[1-9][0-9]{0,9}', env[value]))
    run, attempt = int(env['GITHUB_RUN_NUMBER']), int(env['GITHUB_RUN_ATTEMPT'])
    require(attempt <= 99 and run * 100 + attempt <= 2100000000)
except (ValueError, IndexError, KeyError, TypeError, AttributeError):
    print('::error::Invalid production client/signing configuration or Android version code.', file=sys.stderr)
    sys.exit(1)
PY

if [[ "${1:-}" == --check-inputs ]]; then
  echo "Production Android input checks passed; no signing files, build or upload were created."
  exit 0
fi

readonly script_root="$(cd "$(dirname "$0")" && pwd)"
readonly signing_root="$(mktemp -d "$RUNNER_TEMP/field-production-android.XXXXXX")"
readonly artifact_path="$GITHUB_WORKSPACE/mobile/build/production-android-artifacts"
readonly bundletool_version=1.18.3
readonly bundletool_sha256=a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29
readonly bundletool_path="$signing_root/bundletool.jar"
readonly build_tools_version=36.0.0
readonly build_tools="$ANDROID_HOME/build-tools/$build_tools_version"
readonly bundle_path="$GITHUB_WORKSPACE/mobile/build/app/outputs/bundle/productionRelease/app-production-release.aab"
export ANDROID_UPLOAD_KEYSTORE_PATH="$signing_root/upload.p12"

cleanup() { rm -rf -- "$signing_root"; }
trap cleanup EXIT

# Raw logs stay private; a bounded failure tail masks known credentials before
# output and neutralizes workflow command syntax in compiler/dependency output.
show_failure_tail() {
  python3 - "$signing_root/command.log" <<'PY'
import base64, json, os, re, sys
from urllib.parse import quote
try:
    with open(sys.argv[1], 'rb') as source:
        source.seek(0, 2)
        if source.tell() > 1024 * 1024:
            source.seek(-1024 * 1024, 2)
            source.readline()  # Discard a partial line, including partial secrets.
        else:
            source.seek(0)
        text = source.read().decode('utf8', errors='replace')
    secrets = set()
    for name, value in os.environ.items():
        if value and re.search(r'PASSWORD|TOKEN|SECRET|PRIVATE|KEYSTORE|KEY_ALIAS|PUBLISHABLE_KEY', name):
            secrets.update((value, quote(value, safe=''), json.dumps(value)[1:-1], base64.b64encode(value.encode()).decode()))
    for value in sorted(secrets, key=len, reverse=True):
        text = text.replace(value, '[REDACTED]')
    text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', text)
    text = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]', '', text)
    text = '\n'.join(text.splitlines()[-60:])[-12000:]
    if text:
        print('Sanitized command diagnostics:')
        print(text.replace('::', ': :'))
except (OSError, UnicodeError, ValueError):
    print('Sanitized command diagnostics unavailable.')
PY
}

# GitHub receives only the final validated store artifact, never raw logs.
private_command() {
  local operation="$1"
  shift
  if ! "$@" >"$signing_root/command.log" 2>&1; then
    show_failure_tail
    fail "$operation failed; no Android artifact was published."
  fi
}

python3 - <<'PY'
import base64, os
with open(os.environ['ANDROID_UPLOAD_KEYSTORE_PATH'], 'wb') as target:
    target.write(base64.b64decode(''.join(os.environ['ANDROID_UPLOAD_KEYSTORE_BASE64'].split()), validate=True))
PY
unset ANDROID_UPLOAD_KEYSTORE_BASE64

private_command 'Upload certificate export' keytool -exportcert -storetype PKCS12 \
  -keystore "$ANDROID_UPLOAD_KEYSTORE_PATH" -storepass:env ANDROID_UPLOAD_STORE_PASSWORD \
  -alias "$ANDROID_UPLOAD_KEY_ALIAS" -file "$signing_root/upload-certificate.der"
certificate_sha256="$(sha256sum "$signing_root/upload-certificate.der" | cut -d ' ' -f 1)"
expected_certificate="$(printf '%s' "$ANDROID_UPLOAD_CERTIFICATE_SHA256" | tr -d ':' | tr '[:upper:]' '[:lower:]')"
[[ "$certificate_sha256" == "$expected_certificate" ]] \
  || fail "The upload certificate does not match the pinned production fingerprint."

private_command 'Pinned Android build tools installation' "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
  --install "build-tools;$build_tools_version"
private_command 'Official bundletool download' curl --fail --location --silent --show-error \
  --proto '=https' --tlsv1.2 --retry 2 --max-time 120 \
  "https://github.com/google/bundletool/releases/download/$bundletool_version/bundletool-all-$bundletool_version.jar" \
  --output "$bundletool_path"
printf '%s  %s\n' "$bundletool_sha256" "$bundletool_path" | sha256sum --check --status \
  || fail "The official bundletool download failed its pinned SHA-256 check."

build_name="$(awk '/^version:/ {print $2; exit}' "$GITHUB_WORKSPACE/mobile/pubspec.yaml")"
build_name="${build_name%%+*}"
build_number="$((GITHUB_RUN_NUMBER * 100 + GITHUB_RUN_ATTEMPT))"
[[ "$build_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Could not derive the production version from mobile/pubspec.yaml."
echo "Building Fieldrush Android $build_name ($build_number); Android push is off."

cd "$GITHUB_WORKSPACE/mobile"
# Do not persist signing input values in the Gradle configuration cache or leave
# a daemon holding those values after the protected signing step has finished.
export GRADLE_OPTS="${GRADLE_OPTS:-} -Dorg.gradle.daemon=false -Dorg.gradle.configuration-cache=false"
private_command 'Flutter dependency resolution' flutter pub get
private_command 'Production Android bundle build' flutter build appbundle --release --flavor production \
  --build-name "$build_name" --build-number "$build_number" \
  --dart-define=APP_ENV=production \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_PUBLISHABLE_KEY="$SUPABASE_PUBLISHABLE_KEY" \
  --dart-define=STRIPE_PUBLISHABLE_KEY="$STRIPE_PUBLISHABLE_KEY" \
  --dart-define=DEV=false --dart-define=PROFILE_SWITCHER_ENABLED=false \
  --dart-define=FIELD_E2E_PAYMENT_BYPASS=false \
  --dart-define=EMAIL_DELIVERY_ENABLED="$PRODUCTION_EMAIL_DELIVERY_ENABLED" \
  --dart-define=PUSH_NOTIFICATIONS_ENABLED=false
[[ -s "$bundle_path" ]] || fail "The production App Bundle was not produced."

private_command 'App Bundle signature verification' jarsigner -verify -strict \
  -keystore "$ANDROID_UPLOAD_KEYSTORE_PATH" -storetype PKCS12 \
  -storepass:env ANDROID_UPLOAD_STORE_PASSWORD "$bundle_path"
keytool -printcert -jarfile "$bundle_path" -rfc >"$signing_root/bundle-certificates.pem" 2>"$signing_root/command.log" \
  || fail "Could not inspect the App Bundle signer."
python3 - "$signing_root/bundle-certificates.pem" "$expected_certificate" <<'PY'
import base64, hashlib, re, sys
try:
    with open(sys.argv[1], 'rb') as source:
        certificates = re.findall(rb'-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----', source.read(), re.S)
    if len(certificates) != 1 or hashlib.sha256(base64.b64decode(certificates[0])).hexdigest() != sys.argv[2]:
        raise ValueError('wrong signer')
except (ValueError, OSError):
    print('::error::The App Bundle signer does not match the production upload certificate.', file=sys.stderr)
    sys.exit(1)
PY
private_command 'App Bundle format validation' java -jar "$bundletool_path" validate --bundle="$bundle_path"
java -jar "$bundletool_path" dump manifest --bundle="$bundle_path" --module=base \
  >"$signing_root/manifest.xml" 2>"$signing_root/command.log" || fail "Could not inspect the final bundle manifest."
java -jar "$bundletool_path" dump config --bundle="$bundle_path" \
  >"$signing_root/bundle-config.json" 2>"$signing_root/command.log" || fail "Could not inspect bundle alignment configuration."

# Password files are private temporary files, never command-line password values.
printf '%s' "$ANDROID_UPLOAD_STORE_PASSWORD" >"$signing_root/store-password"
printf '%s' "$ANDROID_UPLOAD_KEY_PASSWORD" >"$signing_root/key-password"
private_command 'Universal APK generation from the signed bundle' java -jar "$bundletool_path" build-apks \
  --bundle="$bundle_path" --output="$signing_root/production.apks" --mode=universal \
  --ks="$ANDROID_UPLOAD_KEYSTORE_PATH" --ks-key-alias="$ANDROID_UPLOAD_KEY_ALIAS" \
  --ks-pass="file:$signing_root/store-password" --key-pass="file:$signing_root/key-password"
unzip -p "$signing_root/production.apks" universal.apk >"$signing_root/universal.apk" \
  || fail "The generated universal APK is missing."
"$build_tools/apksigner" verify --verbose --print-certs "$signing_root/universal.apk" \
  >"$signing_root/apk-signature.txt" 2>"$signing_root/command.log" || fail "Generated APK signature verification failed."
python3 - "$signing_root/apk-signature.txt" "$expected_certificate" <<'PY'
import re, sys
try:
    with open(sys.argv[1], encoding='utf8') as source:
        signers = re.findall(r'Signer #[0-9]+ certificate SHA-256 digest: ([A-Fa-f0-9:]+)', source.read())
    if len(signers) != 1 or signers[0].replace(':', '').lower() != sys.argv[2]:
        raise ValueError('wrong signer')
except (ValueError, OSError, UnicodeError):
    print('::error::The generated APK signer does not match the production upload certificate.', file=sys.stderr)
    sys.exit(1)
PY
private_command 'Generated APK 16 KB ZIP alignment verification' "$build_tools/zipalign" \
  -c -P 16 -v 4 "$signing_root/universal.apk"
"$build_tools/aapt2" dump badging "$signing_root/universal.apk" \
  >"$signing_root/apk-badging.txt" 2>"$signing_root/command.log" || fail "Could not resolve final app metadata."
python3 "$script_root/validate-production-android.py" "$signing_root/manifest.xml" "$bundle_path" \
  "$build_name" "$build_number" --apk-badging "$signing_root/apk-badging.txt" \
  --bundle-config "$signing_root/bundle-config.json" >"$signing_root/validation.json"

# Publish only after every check succeeds; temporary keys, APKs and logs stay out.
mkdir -p "$artifact_path"
readonly output_name="fieldrush-$build_name-$build_number.aab"
cp "$bundle_path" "$artifact_path/$output_name"
(
  cd "$artifact_path"
  sha256sum "$output_name" >SHA256SUMS
)
python3 - "$artifact_path/release.json" "$artifact_path/$output_name" "$build_name" "$build_number" "$expected_certificate" <<'PY'
import hashlib, json, os, sys
with open(sys.argv[2], 'rb') as source:
    digest = hashlib.file_digest(source, 'sha256').hexdigest()
record = {
    'package': 'gg.fieldrush.app', 'versionName': sys.argv[3], 'versionCode': int(sys.argv[4]),
    'sourceSha': os.environ['GITHUB_SHA'], 'sha256': digest,
    'uploadCertificateSha256': sys.argv[5], 'minimumTargetSdkValidated': 36,
    'native16KbLayoutValidated': True, 'generatedApkZipAlignmentValidated': True,
    'androidPushEnabled': False, 'deviceQualificationCompleted': False,
    'googlePlayUploadCompleted': False,
}
with open(sys.argv[1], 'w', encoding='utf8') as target:
    json.dump(record, target, indent=2)
    target.write('\n')
PY
echo "Validated production Android bundle prepared. No Google Play upload, review submission or release occurred."

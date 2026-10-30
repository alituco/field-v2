#!/usr/bin/env python3
"""Read-only cold-start diagnostic for immutable production Android build 201.

Runs only on disposable hosted Linux. Derives a runtime-only APK from the exact
AAB, uses a temporary diagnostic signer, and never signs in or touches payments.
Only public metadata, bounded redacted app-UID logs and native PNGs are retained.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import secrets
import struct
import subprocess
import sys
import time
import unittest
from unittest import mock
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
import zlib

SOURCE_SHA = "0f98a7d3c43ab1eb7eab4fcb7292da6d0e85c42e"
AAB_SHA = "bba536c667751c95b6e40f37fc109d2e9f674c4740cbf4feb56523ec8813b57c"
BUNDLETOOL_SHA = "a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
BUNDLETOOL_URL = "https://github.com/google/bundletool/releases/download/1.18.3/bundletool-all-1.18.3.jar"
PACKAGE = "gg.fieldrush.app"
BUNDLE_NAME = "fieldrush-1.0.0-201.aab"
LIMITATIONS = [
    "Runtime APK is derived from the exact AAB, not rebuilt source.",
    "Ephemeral APK signer differs from Google Play app signing.",
    "Google Play injected installer protection is not reproduced.",
    "Linux Android Emulator is not BlueStacks or physical-device qualification.",
    "No login, OTP, booking, payment, account creation or backend mutation.",
]


def sanitize(text):
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", str(text))
    text = re.sub(r"(?i)(Bearer\s+)\S+", r"\1[REDACTED]", text)
    text = re.sub(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b", "[REDACTED JWT]", text)
    text = re.sub(r"\b(?:sk|rk|pk)_live_[A-Za-z0-9_]+\b|GOCSPX[-_][A-Za-z0-9_-]+|\bsb_(?:publishable|secret)_[A-Za-z0-9_-]+", "[REDACTED KEY]", text)
    text = re.sub(r"(?i)([?&](?:code|token|access_token|refresh_token|apikey|key)=)[^&\s]+", r"\1[REDACTED]", text)
    text = re.sub(r"(?i)((?:access_token|refresh_token|password|authorization)\s*[:=]\s*)[^\s,}]+", r"\1[REDACTED]", text)
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", text)
    return text.replace("::", ": :")[-24000:]


def verify_release(record, digest):
    expected = {"package": PACKAGE, "versionName": "1.0.0", "versionCode": 201,
                "sourceSha": SOURCE_SHA, "sha256": AAB_SHA,
                "native16KbLayoutValidated": True, "androidPushEnabled": False}
    if digest != AAB_SHA or any(record.get(k) != v for k, v in expected.items()):
        raise ValueError("Artifact identity/hash/source/version does not match pinned production 201.")


def verify_manifest(xml):
    root = ET.fromstring(xml)
    android = "{http://schemas.android.com/apk/res/android}"
    sdk = root.find("uses-sdk")
    app = root.find("application")
    if (root.get("package") != PACKAGE or root.get(android + "versionCode") != "201"
            or root.get(android + "versionName") != "1.0.0" or sdk is None
            or sdk.get(android + "minSdkVersion") != "24"
            or sdk.get(android + "targetSdkVersion") != "36"
            or app is None or app.get(android + "debuggable", "false") != "false"):
        raise ValueError("Production manifest identity/SDK/release-mode validation failed.")
    if any(node.get(android + "name") == "io.flutter.embedding.android.EnableImpeller"
           for node in app.findall("meta-data")):
        raise ValueError("Expected untouched production default renderer; found an Impeller override.")


def screenshot_stats(png):
    """Inspect RGB/RGBA adb PNGs without editing them or adding dependencies."""
    if not png.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("Invalid native PNG.")
    offset, data, info = 8, bytearray(), None
    while offset + 12 <= len(png):
        size = struct.unpack(">I", png[offset:offset + 4])[0]
        kind = png[offset + 4:offset + 8]
        payload = png[offset + 8:offset + 8 + size]
        if len(payload) != size:
            raise ValueError("Truncated PNG.")
        if kind == b"IHDR":
            info = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            data.extend(payload)
        elif kind == b"IEND":
            break
        offset += size + 12
    if info is None:
        raise ValueError("PNG has no IHDR.")
    width, height, depth, color, compression, filtering, interlace = info
    if not (32 <= width <= 4096 and 32 <= height <= 4096 and depth == 8
            and color in (2, 6) and compression == filtering == interlace == 0):
        raise ValueError("Unsupported native PNG format/dimensions.")
    channels = 3 if color == 2 else 4
    stride = width * channels
    expected = height * (stride + 1)
    decoder = zlib.decompressobj()
    raw = decoder.decompress(bytes(data), expected + 1)
    if len(raw) != expected or not decoder.eof:
        raise ValueError("PNG decompression size mismatch.")
    previous = bytearray(stride)
    colors = {}
    sampled = 0
    for y in range(height):
        start = y * (stride + 1)
        mode = raw[start]
        row = bytearray(raw[start + 1:start + 1 + stride])
        if mode not in (0, 1, 2, 3, 4):
            raise ValueError("Invalid PNG filter.")
        for i in range(stride):
            left = row[i - channels] if i >= channels else 0
            up = previous[i]
            upper_left = previous[i - channels] if i >= channels else 0
            if mode == 1:
                prediction = left
            elif mode == 2:
                prediction = up
            elif mode == 3:
                prediction = (left + up) // 2
            elif mode == 4:
                p = left + up - upper_left
                distances = (abs(p - left), abs(p - up), abs(p - upper_left))
                prediction = (left, up, upper_left)[distances.index(min(distances))]
            else:
                prediction = 0
            row[i] = (row[i] + prediction) & 255
        # Ignore Android status/navigation bars; inspect the actual app surface.
        if height // 10 <= y < height * 9 // 10 and y % 8 == 0:
            for x in range(width // 10, width * 9 // 10, 8):
                i = x * channels
                rgb = tuple(v // 8 for v in row[i:i + 3])
                colors[rgb] = colors.get(rgb, 0) + 1
                sampled += 1
        previous = row
    if not sampled:
        raise ValueError("Native screenshot has no sampled content.")
    uniform_fraction = max(colors.values()) / sampled
    return {"width": width, "height": height, "sampled_colors": len(colors),
            "dominant_color_fraction": round(uniform_fraction, 5),
            "appears_blank": uniform_fraction >= 0.985,
            "sha256": hashlib.sha256(png).hexdigest()}


def run(args, timeout=120, env=None, check=True):
    result = subprocess.run(args, capture_output=True, timeout=timeout, env=env)
    if check and result.returncode:
        raise RuntimeError(sanitize(result.stderr.decode(errors="replace") or "Command failed."))
    return result


def resolve_emulator_serial(selected=""):
    listing = run(["adb", "devices"], timeout=15).stdout.decode(errors="replace")
    online = re.findall(r"^(emulator-[0-9]+)\s+device(?:\s|$)", listing, re.M)
    if selected:
        if not re.fullmatch(r"emulator-[0-9]+", selected) or selected not in online:
            raise ValueError("Requested emulator is not online; refusing another device.")
        return selected
    if len(online) != 1:
        raise ValueError("Exactly one online emulator is required when ANDROID_SERIAL is unset.")
    return online[0]


def classify_observation(result):
    if result.get("ok"):
        return "SIGNED_OUT_WELCOME_CONFIRMED"
    if not result.get("app_process_alive", False):
        return "APP_START_OR_EARLY_PROCESS_FAILURE"
    if result.get("screenshots") and result["screenshots"][-1].get("appears_blank"):
        return "APP_SURFACE_APPEARS_BLANK"
    return "EXPECTED_WELCOME_NOT_CONFIRMED"


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")
    path.chmod(0o600)


def hosted_paths():
    if (os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"
            or os.environ.get("RUNNER_OS") != "Linux"):
        raise ValueError("Diagnostic is restricted to a disposable GitHub-hosted Linux runner.")
    runner = Path(os.environ["RUNNER_TEMP"]).resolve()
    work = runner / "fieldrush-startup-private"
    output = runner / "fieldrush-startup-results"
    work.mkdir(mode=0o700, exist_ok=True)
    output.mkdir(mode=0o700, exist_ok=True)
    return runner, work, output


def prepare():
    runner, work, output = hosted_paths()
    result = {"phase": "prepare", "ok": False, "source_sha": SOURCE_SHA,
              "version_code": 201, "aab_sha256": AAB_SHA, "limitations": LIMITATIONS}
    try:
        artifact = runner / "fieldrush-production-201"
        names = {p.name for p in artifact.iterdir()}
        if names != {BUNDLE_NAME, "release.json", "SHA256SUMS"}:
            raise ValueError("Unexpected downloaded artifact contents.")
        if any(p.is_symlink() or not p.is_file() for p in artifact.iterdir()):
            raise ValueError("Artifact must contain only regular files.")
        bundle = artifact / BUNDLE_NAME
        digest = hashlib.file_digest(bundle.open("rb"), "sha256").hexdigest()
        verify_release(json.loads((artifact / "release.json").read_text()), digest)
        if (artifact / "SHA256SUMS").read_text().strip() != AAB_SHA + "  " + BUNDLE_NAME:
            raise ValueError("Original SHA256SUMS does not match the pinned AAB.")
        jar = work / "bundletool.jar"
        with urllib.request.urlopen(BUNDLETOOL_URL, timeout=120) as response, jar.open("wb") as target:
            if not response.geturl().startswith("https://"):
                raise ValueError("Bundletool download must remain HTTPS.")
            while chunk := response.read(1024 * 1024):
                target.write(chunk)
        if hashlib.file_digest(jar.open("rb"), "sha256").hexdigest() != BUNDLETOOL_SHA:
            raise ValueError("Official bundletool SHA256 mismatch; will not execute.")
        xml = run(["java", "-jar", str(jar), "dump", "manifest",
                   "--bundle=" + str(bundle), "--module=base"]).stdout
        verify_manifest(xml)
        password = secrets.token_urlsafe(32)
        password_file = work / "ephemeral-password"
        password_file.write_text(password)
        password_file.chmod(0o600)
        signer = work / "ephemeral-diagnostic.p12"
        key_env = dict(os.environ, FIELDRUSH_DIAGNOSTIC_PASSWORD=password)
        run(["keytool", "-genkeypair", "-keystore", str(signer), "-storetype", "PKCS12",
             "-storepass:env", "FIELDRUSH_DIAGNOSTIC_PASSWORD",
             "-keypass:env", "FIELDRUSH_DIAGNOSTIC_PASSWORD",
             "-alias", "runtime-diagnostic-only", "-keyalg", "RSA", "-keysize", "2048",
             "-validity", "2", "-dname", "CN=Ephemeral Android Startup Diagnostic",
             "-noprompt"], env=key_env)
        apks = work / "runtime.apks"
        run(["java", "-jar", str(jar), "build-apks", "--bundle=" + str(bundle),
             "--output=" + str(apks), "--mode=universal", "--ks=" + str(signer),
             "--ks-key-alias=runtime-diagnostic-only",
             "--ks-pass=file:" + str(password_file), "--key-pass=file:" + str(password_file)],
            timeout=300)
        with zipfile.ZipFile(apks) as archive:
            if archive.namelist().count("universal.apk") != 1:
                raise ValueError("Expected one generated universal APK.")
            with archive.open("universal.apk") as source, (work / "runtime.apk").open("wb") as target:
                while chunk := source.read(1024 * 1024):
                    target.write(chunk)
        result["ok"] = True
        return 0
    except Exception as error:
        result["error"] = sanitize(error)
        return 1
    finally:
        write_json(output / "preparation.json", result)
        print(json.dumps({"phase": "prepare", "ok": result["ok"]}))


def capture():
    runner, work, output = hosted_paths()
    serial = os.environ.get("ANDROID_SERIAL", "")
    variant = os.environ.get("FIELDRUSH_RENDERER_DIAGNOSTIC", "")
    result = {"phase": "cold-start", "ok": False, "source_sha": SOURCE_SHA,
              "version_code": 201, "renderer_variant": variant,
              "production_manifest_renderer_override": False, "limitations": LIMITATIONS,
              "screenshots": [], "welcome_text_found": False}
    uid = None
    emulator_confirmed = False

    def adb(*args, timeout=25, check=True):
        return run(["adb", "-s", serial, *args], timeout=timeout, check=check)

    try:
        serial = resolve_emulator_serial(serial)
        result["emulator_serial"] = serial
        if variant not in ("default-vulkan", "opengl-fallback-control"):
            raise ValueError("Unexpected renderer diagnostic variant.")
        if adb("shell", "getprop", "ro.kernel.qemu").stdout.strip() != b"1":
            raise ValueError("Refusing to clear/launch on anything other than an emulator.")
        emulator_confirmed = True
        adb("install", str(work / "runtime.apk"), timeout=90)
        listing = adb("shell", "cmd", "package", "list", "packages", "-U", PACKAGE).stdout.decode()
        match = re.search(r"package:" + re.escape(PACKAGE) + r"\s+uid:(\d+)", listing)
        if not match:
            raise ValueError("Cannot determine the installed app UID; no broad logs will be collected.")
        uid = match.group(1)
        adb("shell", "pm", "clear", PACKAGE)
        adb("logcat", "-c")
        resolved = adb("shell", "cmd", "package", "resolve-activity", "--brief",
                       "-a", "android.intent.action.MAIN",
                       "-c", "android.intent.category.LAUNCHER", "-p", PACKAGE).stdout.decode()
        components = [line.strip() for line in resolved.splitlines()
                      if re.fullmatch(re.escape(PACKAGE) + r"/[A-Za-z0-9_.$]+", line.strip())]
        if len(components) != 1:
            raise ValueError("Could not resolve the exact installed launcher component.")
        result["launcher_component"] = components[0]
        launch = adb("shell", "am", "start", "-W", "-n", components[0],
                     timeout=40, check=False)
        result["launch_return_code"] = launch.returncode
        if launch.returncode:
            raise RuntimeError("Android activity launch failed: " + sanitize(launch.stderr.decode(errors="replace")))
        started = time.monotonic()
        for seconds in (5, 20, 60):
            time.sleep(max(0, seconds - (time.monotonic() - started)))
            png = adb("exec-out", "screencap", "-p").stdout
            if len(png) > 16 * 1024 * 1024:
                raise ValueError("Native screenshot exceeds diagnostic size bound.")
            path = output / ("frame-%02ds.png" % seconds)
            path.write_bytes(png)
            path.chmod(0o600)
            result["screenshots"].append({"at_seconds": seconds, "file": path.name,
                                           **screenshot_stats(png)})
        dump = adb("shell", "uiautomator", "dump", "/sdcard/fieldrush-startup.xml",
                   timeout=30, check=False)
        if dump.returncode == 0:
            tree = adb("shell", "cat", "/sdcard/fieldrush-startup.xml", check=False).stdout.decode(errors="replace")
            result["welcome_text_found"] = bool(re.search(r"Create\s+account", tree, re.I))
        pid = adb("shell", "pidof", PACKAGE, check=False).stdout.decode().strip()
        result["app_process_alive"] = bool(re.fullmatch(r"[0-9 ]+", pid))
        result["ok"] = (result["app_process_alive"] and result["welcome_text_found"]
                        and not result["screenshots"][-1]["appears_blank"])
        if not result["ok"]:
            result["error"] = "Expected signed-out welcome/first frame was not confirmed; inspect native frames and scoped logs."
    except Exception as error:
        result["error"] = sanitize(error)
        result["launch_or_capture_timed_out"] = isinstance(error, subprocess.TimeoutExpired)
    finally:
        if emulator_confirmed and uid is not None:
            try:
                pid = adb("shell", "pidof", PACKAGE, timeout=10, check=False).stdout.decode().strip()
                result["app_process_alive"] = bool(re.fullmatch(r"[0-9 ]+", pid))
            except Exception as error:
                result["process_observation_error"] = sanitize(error)
        if not result["screenshots"] and emulator_confirmed:
            try:
                png = adb("exec-out", "screencap", "-p", timeout=10).stdout
                if 0 < len(png) <= 16 * 1024 * 1024:
                    (output / "failure-frame.png").write_bytes(png)
                    result["screenshots"].append({"file": "failure-frame.png",
                                                   **screenshot_stats(png)})
            except Exception as error:
                result["failure_screenshot_error"] = sanitize(error)
        if uid is not None:
            result["log_scope"] = "Installed app UID only; includes early crash/restart, no whole-device log."
            try:
                logs = adb("logcat", "-d", "-v", "threadtime", "--uid=" + uid,
                           "-t", "1500", check=False).stdout.decode(errors="replace")
                safe_logs = sanitize(logs)
                (output / "app-startup.redacted.log").write_text(safe_logs)
                backends = re.findall(r"Using the Impeller rendering backend[^\r\n]*", safe_logs)
                result["observed_renderer_messages"] = backends[-5:]
                result["renderer_error_hint"] = bool(re.search(
                    r"(?:Vulkan|Impeller|EGL)[^\r\n]*(?:fail|error)", safe_logs, re.I))
                result["startup_exception_hint"] = bool(re.search(
                    r"MissingPluginException|PlatformException|Unhandled Exception|FATAL EXCEPTION|Fatal signal|UnsatisfiedLinkError",
                    safe_logs))
            except Exception as error:
                result["scoped_log_error"] = sanitize(error)
        result["classification"] = classify_observation(result)
        write_json(output / "result.json", result)
        print(json.dumps({"phase": "cold-start", "ok": result["ok"],
                          "variant": variant, "details": "Sanitized diagnostic artifacts only."}))
    return 0 if result["ok"] else 1


def finalize():
    _, _, output = hosted_paths()
    if not (output / "result.json").exists():
        preparation = json.loads((output / "preparation.json").read_text()) if (output / "preparation.json").exists() else {}
        classification = ("PREPARATION_FAILED" if not preparation.get("ok") else
                          "EMULATOR_BOOT_OR_CAPTURE_DID_NOT_COMPLETE")
        write_json(output / "result.json", {
            "ok": False, "classification": classification,
            "renderer_variant": os.environ.get("FIELDRUSH_RENDERER_DIAGNOSTIC"),
            "emulator_step_outcome": os.environ.get("FIELDRUSH_EMULATOR_STEP_OUTCOME"),
            "source_sha": SOURCE_SHA, "aab_sha256": AAB_SHA, "limitations": LIMITATIONS,
            "note": "No completed app observation exists; do not interpret an emulator failure as an app white screen.",
        })
    return 0


class GuardTests(unittest.TestCase):
    def record(self):
        return {"package": PACKAGE, "versionName": "1.0.0", "versionCode": 201,
                "sourceSha": SOURCE_SHA, "sha256": AAB_SHA,
                "native16KbLayoutValidated": True, "androidPushEnabled": False}

    def test_immutable_identity_and_each_tampered_claim(self):
        verify_release(self.record(), AAB_SHA)
        for key in self.record():
            record = self.record()
            record[key] = "tampered"
            with self.assertRaises(ValueError):
                verify_release(record, AAB_SHA)
        with self.assertRaises(ValueError):
            verify_release(self.record(), "0" * 64)

    def test_unset_serial_discovers_one_online_emulator_only(self):
        listing = subprocess.CompletedProcess([], 0, stdout=b"List of devices attached\nemulator-5554\tdevice\nphysical123\tdevice\n")
        with mock.patch(__name__ + ".run", return_value=listing):
            self.assertEqual(resolve_emulator_serial(""), "emulator-5554")
            with self.assertRaises(ValueError):
                resolve_emulator_serial("physical123")
        for body in (b"emulator-5554\toffline\n", b"emulator-5554\tdevice\nemulator-5556\tdevice\n"):
            with mock.patch(__name__ + ".run", return_value=subprocess.CompletedProcess([], 0, stdout=body)):
                with self.assertRaises(ValueError):
                    resolve_emulator_serial("")

    def test_live_white_frame_after_launch_timeout_is_not_process_failure(self):
        observed = {"ok": False, "launch_or_capture_timed_out": True,
                    "app_process_alive": True, "screenshots": [{"appears_blank": True}]}
        self.assertEqual(classify_observation(observed), "APP_SURFACE_APPEARS_BLANK")
        observed["app_process_alive"] = False
        self.assertEqual(classify_observation(observed), "APP_START_OR_EARLY_PROCESS_FAILURE")

    def test_redaction_and_workflow_command_neutralization(self):
        source = "Bearer private-value eyJabc.def.signature sk_live_secret GOCSPX-secret-value ?refresh_token=private ::error::unsafe"
        value = sanitize(source)
        for forbidden in ("private-value", "eyJabc.def.signature", "sk_live_secret", "GOCSPX-secret-value", "=private", "::error::"):
            self.assertNotIn(forbidden, value)
        self.assertLessEqual(len(sanitize("x" * 50000)), 24000)

    def test_manifest_rejects_debug_or_renderer_override(self):
        xml = ('<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="gg.fieldrush.app" '
               'android:versionCode="201" android:versionName="1.0.0"><uses-sdk android:minSdkVersion="24" '
               'android:targetSdkVersion="36"/><application/></manifest>')
        verify_manifest(xml)
        for changed in (xml.replace("<application/>", '<application android:debuggable="true"/>'),
                        xml.replace("<application/>", '<application><meta-data android:name="io.flutter.embedding.android.EnableImpeller" android:value="false"/></application>'),
                        xml.replace('minSdkVersion="24"', 'minSdkVersion="23"')):
            with self.assertRaises(ValueError):
                verify_manifest(changed)

    def test_native_blank_vs_drawn_pixels(self):
        def png(pattern):
            def chunk(kind, value):
                return struct.pack(">I", len(value)) + kind + value + struct.pack(">I", zlib.crc32(kind + value) & 0xffffffff)
            rows = b"".join(b"\x00" + b"".join(pattern(x, y) for x in range(64)) for y in range(64))
            return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 64, 8, 2, 0, 0, 0))
                    + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
        self.assertTrue(screenshot_stats(png(lambda x, y: b"\xff\xff\xff"))["appears_blank"])
        self.assertFalse(screenshot_stats(png(lambda x, y: b"\x10\x70\x40" if x < 32 else b"\xff\xff\xff"))["appears_blank"])
        with self.assertRaises(ValueError):
            screenshot_stats(b"not a PNG")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("prepare", "capture", "finalize", "self-test"))
    phase = parser.parse_args().phase
    if phase == "self-test":
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(GuardTests)
        sys.exit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
    sys.exit({"prepare": prepare, "capture": capture, "finalize": finalize}[phase]())

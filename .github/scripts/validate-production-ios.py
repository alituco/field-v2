#!/usr/bin/env python3
"""Validate decoded production signing plists without exposing their contents."""

import datetime
import plistlib
import re
import sys

TEAM = "69B646V2WM"
BUNDLE = "com.alialtaraif.field"
MERCHANT = "merchant.com.alialtaraif.fieldrush"
PROFILE = "Field Production App Store"


class ValidationError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def read_plist(path):
    with open(path, "rb") as source:
        return plistlib.load(source)


def validate_entitlements(entitlements, push, *, signed_app):
    require(entitlements.get("application-identifier") == f"{TEAM}.{BUNDLE}",
            "The signing entitlements do not belong to Field Production.")
    require(entitlements.get("com.apple.developer.team-identifier") == TEAM,
            "The signing entitlements belong to a different Apple team.")
    require(entitlements.get("get-task-allow", False) is False,
            "Production signing must not allow debugging.")
    require(MERCHANT in entitlements.get("com.apple.developer.in-app-payments", []),
            "The Fieldrush Apple Pay merchant entitlement is missing.")
    if push:
        require(entitlements.get("aps-environment") == "production",
                "Production push requires the production APNs entitlement.")
    elif signed_app:
        require("aps-environment" not in entitlements,
                "A push-disabled build must not request an APNs entitlement.")


def validate_profile(profile, push):
    require(profile.get("Name") == PROFILE,
            "The provisioning profile must be named Field Production App Store.")
    require(profile.get("TeamIdentifier") == [TEAM],
            "The provisioning profile belongs to a different Apple team.")
    require("ProvisionedDevices" not in profile and not profile.get("ProvisionsAllDevices"),
            "Production uploads require an App Store distribution profile.")
    require(isinstance(profile.get("UUID"), str) and
            re.fullmatch(r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}", profile["UUID"]),
            "The provisioning profile has no valid UUID.")
    expiration = profile.get("ExpirationDate")
    require(isinstance(expiration, datetime.datetime),
            "The provisioning profile has no valid expiration date.")
    expiration = expiration.replace(tzinfo=datetime.timezone.utc) if expiration.tzinfo is None else expiration
    require(expiration > datetime.datetime.now(datetime.timezone.utc),
            "The production provisioning profile has expired.")
    validate_entitlements(profile.get("Entitlements", {}), push, signed_app=False)


def validate_app(entitlements, info, push, version, build):
    validate_entitlements(entitlements, push, signed_app=True)
    require(info.get("CFBundleIdentifier") == BUNDLE,
            "The signed app has the wrong production Bundle ID.")
    require(info.get("CFBundleDisplayName") == "Fieldrush",
            "The signed app has the wrong production display name.")
    require(info.get("CFBundleShortVersionString") == version and info.get("CFBundleVersion") == build,
            "The signed app version/build differs from the requested production build.")
    require(info.get("FirebaseMessagingAutoInitEnabled") is False,
            "Firebase Messaging auto-init must remain off until in-app consent.")
    require(info.get("ITSAppUsesNonExemptEncryption") is False,
            "The signed app must preserve the reviewed export-compliance declaration.")
    schemes = [scheme for item in info.get("CFBundleURLTypes", [])
               for scheme in item.get("CFBundleURLSchemes", [])]
    require(BUNDLE in schemes and f"{BUNDLE}.staging" not in schemes,
            "The signed app must use the production authentication callback scheme.")
    if push:
        modes = info.get("UIBackgroundModes", [])
        require("fetch" in modes and "remote-notification" in modes,
                "Production push requires fetch and remote-notification background modes.")


def main(args):
    require(len(args) >= 3 and args[0] in ("profile", "app"),
            "Usage: validate-production-ios.py profile FILE PUSH | app ENTITLEMENTS INFO PUSH VERSION BUILD")
    if args[0] == "profile":
        require(len(args) == 3 and args[2] in ("true", "false"), "Invalid profile validation arguments.")
        validate_profile(read_plist(args[1]), args[2] == "true")
    else:
        require(len(args) == 6 and args[3] in ("true", "false"), "Invalid app validation arguments.")
        validate_app(read_plist(args[1]), read_plist(args[2]), args[3] == "true", args[4], args[5])
    print(f"Field Production {args[0]} validation passed.")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (ValueError, TypeError, AttributeError, OSError, plistlib.InvalidFileException):
        # Controlled validation errors are safe to report; parse/file errors may
        # include private paths or input and therefore get a generic message.
        exception = sys.exc_info()[1]
        message = str(exception) if isinstance(exception, ValidationError) else "Could not read the production signing plist."
        print(f"::error::{message}", file=sys.stderr)
        sys.exit(1)

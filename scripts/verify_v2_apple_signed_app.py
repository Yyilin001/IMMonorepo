#!/usr/bin/env python3
"""Verify an iOS app's signature and actual APNs environment before delivery.

Never prints certificate names, team IDs, provisioning contents or tokens.
Run on the signed app after build/export, since Xcode may change entitlements
to match its chosen profile. A valid signature alone is insufficient.
"""

import argparse
import datetime
import fnmatch
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys


class VerificationFailure(Exception):
    pass


def run(command, reason):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise VerificationFailure(reason)
    return result.stdout


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as data:
        for chunk in iter(lambda: data.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def verify(app, expected):
    run(["codesign", "--verify", "--deep", "--strict", str(app)], "invalid_signature")
    entitlements = plistlib.loads(run(["codesign", "-d", "--entitlements", ":-", str(app)],
                                     "entitlements_unavailable"))
    info = plistlib.loads((app / "Info.plist").read_bytes())
    configured = info.get("IMV2PushEnvironment")
    signed = entitlements.get("aps-environment")
    if signed not in {"development", "production"} or configured != signed:
        raise VerificationFailure("push_environment_mismatch")
    if expected is not None and signed != expected:
        raise VerificationFailure("unexpected_push_environment")
    profile = plistlib.loads(run(["security", "cms", "-D", "-i", str(app / "embedded.mobileprovision")],
                                "profile_unavailable"))
    profile_entitlements = profile.get("Entitlements", {})
    if profile_entitlements.get("aps-environment") != signed:
        raise VerificationFailure("profile_push_environment_mismatch")
    team = entitlements.get("com.apple.developer.team-identifier")
    if not team or team not in profile.get("TeamIdentifier", []):
        raise VerificationFailure("profile_team_mismatch")
    identifier = info.get("CFBundleIdentifier")
    application = entitlements.get("application-identifier", "")
    if not isinstance(identifier, str) or not identifier or not application.endswith("." + identifier):
        raise VerificationFailure("bundle_identity_mismatch")
    profile_application = profile_entitlements.get("application-identifier")
    if not isinstance(profile_application, str) or not fnmatch.fnmatchcase(application, profile_application):
        raise VerificationFailure("profile_application_mismatch")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, datetime.datetime):
        raise VerificationFailure("profile_expiration_missing")
    if expiry.replace(tzinfo=expiry.tzinfo or datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise VerificationFailure("profile_expired")
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or Path(executable).name != executable:
        raise VerificationFailure("invalid_executable")
    binary = (app / executable).resolve()
    if binary.parent != app:
        raise VerificationFailure("executable_outside_app")
    return {"status": "passed", "pushEnvironment": signed, "signatureVerified": True,
            "profileEnvironmentAndIdentityMatched": True, "binarySHA256": digest(binary),
            "infoPlistSHA256": digest(app / "Info.plist"),
            "profileSHA256": digest(app / "embedded.mobileprovision"),
            "installed": False, "uploaded": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--expected-push-environment", choices=["development", "production"])
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Verification requires macOS codesign and security tools")
    try:
        result = verify(args.app.resolve(), args.expected_push_environment)
        code = 0
    except VerificationFailure as error:
        result, code = {"status": "failed", "reason": str(error)}, 1
    except (OSError, ValueError, TypeError, AttributeError, plistlib.InvalidFileException):
        result, code = {"status": "failed", "reason": "invalid_app_metadata"}, 1
    print(json.dumps(result))
    return code


if __name__ == "__main__":
    raise SystemExit(main())

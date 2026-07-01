#!/usr/bin/env python3
from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]

REQUIRED_TEXT = {
    "app/src/main/java/com/xmtx/imappandroid/di/AndroidNetworkConfigurationPolicy.kt": [
        "object AndroidNetworkConfigurationPolicy",
        "fun validateRelease(",
        "apiURI.scheme == \"https\"",
        "apiURI.port == -1 || apiURI.port == 443",
        "validatePublicDNSHost(apiURI.host, \"IM_API_BASE_URL\")",
        "validatePublicDNSHost(environment.imTcpHost, \"IM_TCP_HOST\")",
        "environment.imTcpPort == 9000",
        "tcpRequiresTlsTermination",
        "placeholderHosts",
        "placeholderSuffixes",
        "stalePublicIPs",
        "47.106.103.10",
        "120.25.106.200",
        "isIPLiteral",
        "not a raw IP address",
        "not a placeholder domain",
    ],
    "app/src/main/java/com/xmtx/imappandroid/di/AppContainer.kt": [
        "if (!BuildConfig.DEBUG)",
        "AndroidNetworkConfigurationPolicy.validateRelease(",
        "tcpRequiresTlsTermination = BuildConfig.IM_TCP_REQUIRES_TLS_TERMINATION",
    ],
    "app/src/test/java/com/xmtx/imappandroid/di/AndroidNetworkConfigurationPolicyTests.kt": [
        "releaseAcceptsRealHttpsAndPublicTCPGateway",
        "releaseRejectsLocalApiURL",
        "releaseRejectsPlaceholderHost",
        "releaseRejectsRawTCPIPAddress",
        "releaseRejectsUnexpectedPortsAndMissingTLSTermination",
        "https://chat.prod-domain.com",
        "http://10.0.2.2:8080",
        "https://im.example.com",
        "47.106.103.10",
        "imTcpPort = 9443",
        "tcpRequiresTlsTermination = false",
    ],
}


def audit_repo(repo_root: Path) -> list[str]:
    errors: list[str] = []
    for relative_path, required_texts in REQUIRED_TEXT.items():
        path = repo_root / relative_path
        if not path.is_file():
            errors.append(f"{relative_path}:missing_file")
            continue
        text = path.read_text(encoding="utf-8")
        for required_text in required_texts:
            if required_text not in text:
                errors.append(f"{relative_path}:missing_text:{required_text}")
    return errors


def copy_required_files(source_root: Path, target_root: Path) -> None:
    for relative_path in REQUIRED_TEXT:
        source = source_root / relative_path
        target = target_root / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)


def run_self_test(repo_root: Path) -> int:
    with tempfile.TemporaryDirectory(prefix="android-network-config-audit-") as tmp:
        test_root = Path(tmp)
        copy_required_files(repo_root, test_root)

        errors = audit_repo(test_root)
        if errors:
            for error in errors:
                print(f"android-network-config-audit-self-test result=fail phase=positive reason={error}", file=sys.stderr)
            return 1

        policy = test_root / "app/src/main/java/com/xmtx/imappandroid/di/AndroidNetworkConfigurationPolicy.kt"
        broken = policy.read_text(encoding="utf-8").replace("stalePublicIPs", "temporaryIPs")
        policy.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any("AndroidNetworkConfigurationPolicy.kt:missing_text:stalePublicIPs" in error for error in errors):
            print(
                "android-network-config-audit-self-test result=fail phase=negative "
                "reason=missing_stale_public_ip_guard_not_detected",
                file=sys.stderr,
            )
            return 1

        copy_required_files(repo_root, test_root)
        app_container = test_root / "app/src/main/java/com/xmtx/imappandroid/di/AppContainer.kt"
        broken = app_container.read_text(encoding="utf-8").replace(
            "AndroidNetworkConfigurationPolicy.validateRelease(",
            "AndroidNetworkConfigurationPolicy.skipValidateRelease(",
            1,
        )
        app_container.write_text(broken, encoding="utf-8")
        errors = audit_repo(test_root)
        if not any("AppContainer.kt:missing_text:AndroidNetworkConfigurationPolicy.validateRelease(" in error for error in errors):
            print(
                "android-network-config-audit-self-test result=fail phase=negative "
                "reason=missing_app_container_release_validation_call_not_detected",
                file=sys.stderr,
            )
            return 1

    print("android-network-config-audit-self-test result=pass")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true", help="run positive and negative audit self-tests")
    args = parser.parse_args()

    if args.self_test:
        return run_self_test(REPO_ROOT)

    errors = audit_repo(REPO_ROOT)
    if errors:
        for error in errors:
            print(f"android-network-config-audit result=fail reason={error}", file=sys.stderr)
        return 1
    print("android-network-config-audit result=pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

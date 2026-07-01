#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ipaddress
import re
import sys
from urllib.parse import urlparse


class PolicyFailure(Exception):
    def __init__(self, reason: str, detail: str = "") -> None:
        super().__init__(reason)
        self.reason = reason
        self.detail = detail


DNS_LABEL_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")


def host_reason(host: str) -> str:
    value = host.lower()
    if not value:
        return "missing"
    if value.endswith("."):
        return "trailing_dot"
    if value.startswith("*."):
        return "wildcard"
    if value in {"localhost", "127.0.0.1", "::1", "0.0.0.0"}:
        return "local"
    try:
        ipaddress.ip_address(value)
        return "ip"
    except ValueError:
        pass
    if "." not in value:
        return "single_label"
    placeholder_hosts = {"example.com", "example.net", "example.org", "yourdomain.com"}
    placeholder_suffixes = (
        ".example",
        ".example.com",
        ".example.net",
        ".example.org",
        ".yourdomain.com",
        ".test",
        ".invalid",
    )
    if value in placeholder_hosts or any(value.endswith(suffix) for suffix in placeholder_suffixes):
        return "placeholder"
    if len(value) > 253:
        return "invalid_dns"
    if any(not DNS_LABEL_RE.match(label) for label in value.split(".")):
        return "invalid_dns"
    return ""


def validate_public_target(base_url: str, tcp_host: str, tcp_port: str) -> None:
    if not base_url:
        raise PolicyFailure("missing_env", "name=BASE_URL")
    if not tcp_host:
        raise PolicyFailure("missing_env", "name=TCP_HOST")
    if not tcp_port:
        raise PolicyFailure("missing_env", "name=TCP_PORT")
    if base_url != base_url.strip():
        raise PolicyFailure("base_url_format_invalid", "reason=surrounding_whitespace")
    if tcp_host != tcp_host.strip():
        raise PolicyFailure("tcp_host_format_invalid", "reason=surrounding_whitespace")

    parsed = urlparse(base_url)
    if parsed.scheme != "https":
        raise PolicyFailure("base_url_https_required", f"baseURL={base_url or '<empty>'}")
    if parsed.username or parsed.password:
        raise PolicyFailure("base_url_origin_required", "reason=userinfo")
    if parsed.path not in ("", "/") or parsed.params or parsed.query or parsed.fragment:
        raise PolicyFailure("base_url_origin_required", "reason=path_query_or_fragment")
    try:
        base_port = parsed.port or 443
    except ValueError:
        raise PolicyFailure("base_url_port_invalid", f"baseURL={base_url or '<empty>'}")
    if base_port != 443:
        raise PolicyFailure("base_url_default_https_port_required", f"baseURL={base_url or '<empty>'} port={base_port}")

    base_host = parsed.hostname or ""
    base_reason = host_reason(base_host)
    if base_reason:
        raise PolicyFailure("base_url_dns_required", f"host={base_host or '-'} hostReason={base_reason}")

    tcp_reason = host_reason(tcp_host)
    if tcp_reason:
        raise PolicyFailure("tcp_host_dns_required", f"tcpHost={tcp_host or '-'} hostReason={tcp_reason}")

    if tcp_port != "9000":
        if tcp_port.isdigit():
            raise PolicyFailure("tcp_port_required", f"tcpPort={tcp_port} expected=9000")
        raise PolicyFailure("tcp_port_invalid", f"tcpPort={tcp_port or '<empty>'}")


def run_self_test() -> None:
    validate_public_target("https://chat.myim-prod.com", "tcp.myim-prod.com", "9000")
    cases = [
        ("http://chat.myim-prod.com", "tcp.myim-prod.com", "9000", "base_url_https_required"),
        ("https://chat.myim-prod.com:8443", "tcp.myim-prod.com", "9000", "base_url_default_https_port_required"),
        ("https://127.0.0.1", "tcp.myim-prod.com", "9000", "base_url_dns_required"),
        ("https://chat.myim-prod.com", "127.0.0.1", "9000", "tcp_host_dns_required"),
        ("https://chat.yourdomain.com", "tcp.myim-prod.com", "9000", "base_url_dns_required"),
        ("https://chat.myim-prod.com", "tcp.example.net", "9000", "tcp_host_dns_required"),
        ("https://localhost.", "tcp.myim-prod.com", "9000", "base_url_dns_required"),
        ("https://chat.example.com.", "tcp.myim-prod.com", "9000", "base_url_dns_required"),
        ("https://127.0.0.1.", "tcp.myim-prod.com", "9000", "base_url_dns_required"),
        ("https://chat.myim-prod.com", "tcp.example.net.", "9000", "tcp_host_dns_required"),
        ("https://chat.myim-prod.com.", "tcp.myim-prod.com", "9000", "base_url_dns_required"),
        ("https://chat.myim-prod.com", "tcp.myim-prod.com.", "9000", "tcp_host_dns_required"),
        ("https://*.myim-prod.com", "tcp.myim-prod.com", "9000", "base_url_dns_required"),
        ("https://user:pass@chat.myim-prod.com", "tcp.myim-prod.com", "9000", "base_url_origin_required"),
        ("https://chat.myim-prod.com/api", "tcp.myim-prod.com", "9000", "base_url_origin_required"),
        ("https://chat.myim-prod.com?env=prod", "tcp.myim-prod.com", "9000", "base_url_origin_required"),
        ("https://chat.myim-prod.com#prod", "tcp.myim-prod.com", "9000", "base_url_origin_required"),
        ("https://chat.myim-prod.com", "tcp.myim-prod.com:9000", "9000", "tcp_host_dns_required"),
        ("https://chat.myim-prod.com", "tcp_host.myim-prod.com", "9000", "tcp_host_dns_required"),
        ("https://chat.myim-prod.com ", "tcp.myim-prod.com", "9000", "base_url_format_invalid"),
        ("https://chat.myim-prod.com", "tcp.myim-prod.com ", "9000", "tcp_host_format_invalid"),
        ("https://chat.myim-prod.com", "[tcp.myim-prod.com]", "9000", "tcp_host_dns_required"),
        ("https://chat.myim-prod.com", "tcp.myim-prod.com", "9443", "tcp_port_required"),
        ("https://chat.myim-prod.com", "tcp.myim-prod.com", "09000", "tcp_port_required"),
        ("https://chat.myim-prod.com", "tcp.myim-prod.com", "+9000", "tcp_port_invalid"),
        ("https://chat.myim-prod.com", "tcp.myim-prod.com", "9000 ", "tcp_port_invalid"),
        ("", "tcp.myim-prod.com", "9000", "missing_env"),
    ]
    for base_url, tcp_host, tcp_port, expected_reason in cases:
        try:
            validate_public_target(base_url, tcp_host, tcp_port)
        except PolicyFailure as exc:
            if exc.reason != expected_reason:
                raise SystemExit(
                    "production_target_policy_self_test result=fail "
                    f"reason=unexpected_failure expected={expected_reason} actual={exc.reason}"
                )
        else:
            raise SystemExit(
                "production_target_policy_self_test result=fail "
                f"reason=case_passed expected={expected_reason}"
            )
    print("production_target_policy_self_test result=pass")


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate the long-term production public target policy.")
    parser.add_argument("--base-url", default="")
    parser.add_argument("--tcp-host", default="")
    parser.add_argument("--tcp-port", default="")
    parser.add_argument("--result-prefix", default="production_target_policy")
    parser.add_argument("--reason-only", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return 0

    try:
        validate_public_target(args.base_url, args.tcp_host, args.tcp_port)
    except PolicyFailure as exc:
        suffix = f" {exc.detail}" if exc.detail else ""
        if args.reason_only:
            print(f"{exc.reason}{suffix}")
        else:
            print(f"{args.result_prefix} result=fail reason={exc.reason}{suffix}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

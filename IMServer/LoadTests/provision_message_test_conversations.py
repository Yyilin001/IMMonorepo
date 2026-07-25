#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import time
import urllib.error
import urllib.request
from pathlib import Path


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed < 2:
        raise argparse.ArgumentTypeError("must be at least 2")
    return parsed


def load_accounts(path: str) -> list[tuple[str, str]]:
    accounts: list[tuple[str, str]] = []
    with open(path, newline="") as file:
        for row in csv.reader(file):
            if not row or not row[0].strip() or row[0].lstrip().startswith("#"):
                continue
            if len(row) < 2 or not row[1].strip():
                raise SystemExit(f"account row is missing a password: {row!r}")
            accounts.append((row[0].strip(), row[1].strip()))
    if len(accounts) < 2:
        raise SystemExit("at least two accounts are required")
    return accounts


def request_json(
    url: str,
    method: str,
    payload: dict | None = None,
    token: str | None = None,
    extra_headers: dict[str, str] | None = None,
    timeout_seconds: int = 30,
) -> dict:
    body = json.dumps(payload, separators=(",", ":")).encode() if payload is not None else None
    headers = {"Accept": "application/json"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if extra_headers:
        headers.update(extra_headers)
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:1_000]
        raise SystemExit(f"HTTP {error.code} {method} {url}: {detail}") from error


def login(auth_base_url: str, email: str, password: str) -> dict:
    payload = {
        "email": email,
        "password": password,
        "device": {
            "deviceID": f"message-fixture-{int(time.time() * 1_000)}",
            "deviceName": "message-fixture",
            "platform": "load-test",
            "appVersion": "load-test",
        },
    }
    last_error: Exception | None = None
    for attempt in range(5):
        try:
            return request_json(f"{auth_base_url}/api/auth/login", "POST", payload)
        except urllib.error.HTTPError:
            raise
        except (TimeoutError, urllib.error.URLError, OSError) as error:
            last_error = error
            if attempt == 4:
                break
            time.sleep(1 << attempt)
    raise SystemExit(f"login failed after 5 attempts for {email}: {last_error}")


def create_conversation(
    command_base_url: str,
    token: str,
    kind: str,
    title: str | None,
    member_emails: list[str],
    timeout_seconds: int = 30,
) -> dict:
    return request_json(
        f"{command_base_url}/api/im/conversations",
        "POST",
        {"kind": kind, "title": title, "memberEmails": member_emails},
        token,
        {"Accept": "application/vnd.im.conversation-command-receipt+json"},
        timeout_seconds=timeout_seconds,
    )


def add_members(command_base_url: str, token: str, conversation_id: str, member_emails: list[str]) -> dict:
    return request_json(
        f"{command_base_url}/api/im/conversations/{conversation_id}/members",
        "POST",
        {"memberEmails": member_emails},
        token,
        {"Accept": "application/vnd.im.conversation-command-receipt+json"},
    )


def member_count(query_base_url: str, token: str, conversation_id: str) -> int:
    response = request_json(
        f"{query_base_url}/api/im/conversations/{conversation_id}/members?limit=100",
        "GET",
        token=token,
    )
    return int(response.get("total", 0))


def ensure_contacts(command_base_url: str, owner_auth: dict, peer_auth: dict, peer_email: str) -> None:
    owner_contacts = request_json(f"{command_base_url}/api/contacts", "GET", token=owner_auth["accessToken"])
    peer_id = peer_auth["user"]["id"]
    if any(contact.get("id") == peer_id for contact in owner_contacts):
        return
    request = request_json(
        f"{command_base_url}/api/contact-requests",
        "POST",
        {"email": peer_email, "message": "TCP message load fixture", "remark": "tcp-load"},
        owner_auth["accessToken"],
    )
    request_id = request.get("id")
    if not request_id:
        raise SystemExit(f"contact request did not return an id: {request}")
    request_json(
        f"{command_base_url}/api/contact-requests/{request_id}/accept",
        "POST",
        {"remark": "tcp-load"},
        peer_auth["accessToken"],
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Provision reproducible direct, small-group, and large-group TCP message-test fixtures.")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--auth-base-url")
    parser.add_argument("--command-base-url")
    parser.add_argument("--query-base-url")
    parser.add_argument("--account-file", required=True)
    parser.add_argument(
        "--account-offset",
        type=int,
        default=0,
        help="first account row used by this fixture; useful for non-overlapping multi-group fixtures",
    )
    parser.add_argument("--small-group-members", type=positive_int, default=50)
    parser.add_argument("--large-group-conversation-id")
    parser.add_argument("--large-group-members", type=positive_int)
    parser.add_argument("--large-group-bootstrap-timeout-seconds", type=positive_int, default=300)
    parser.add_argument("--output-file", required=True)
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")
    auth_base_url = (args.auth_base_url or base_url).rstrip("/")
    command_base_url = (args.command_base_url or base_url).rstrip("/")
    query_base_url = (args.query_base_url or base_url).rstrip("/")
    all_accounts = load_accounts(args.account_file)
    if args.account_offset < 0:
        raise SystemExit("account offset must not be negative")
    accounts = all_accounts[args.account_offset :]
    required_members = max(args.small_group_members, args.large_group_members or 0)
    if len(accounts) < required_members:
        raise SystemExit(
            f"largest requested group needs {required_members} accounts, but file has {len(accounts)}"
        )
    if args.large_group_members and args.large_group_conversation_id:
        raise SystemExit("use either --large-group-members or --large-group-conversation-id, not both")

    owner_email, owner_password = accounts[0]
    owner_auth = login(auth_base_url, owner_email, owner_password)
    peer_email, peer_password = accounts[1]
    peer_auth = login(auth_base_url, peer_email, peer_password)
    ensure_contacts(command_base_url, owner_auth, peer_auth, peer_email)
    token = owner_auth["accessToken"]
    stamp = int(time.time())

    direct = create_conversation(command_base_url, token, "direct", None, [peer_email])
    direct_id = direct["conversationID"]
    direct_members = member_count(query_base_url, token, direct_id)
    if direct_members != 2:
        raise SystemExit(f"direct member count mismatch: expected=2 actual={direct_members}")

    small_group = create_conversation(
        command_base_url,
        token,
        "group",
        f"TCP Small Group {args.small_group_members} {stamp}",
        [email for email, _ in accounts[1 : args.small_group_members]],
    )
    small_group_id = small_group["conversationID"]
    small_group_count = member_count(query_base_url, token, small_group_id)
    if small_group_count != args.small_group_members:
        raise SystemExit(
            f"small group member count mismatch: expected={args.small_group_members} actual={small_group_count}"
        )

    large_group: dict[str, int | str | None]
    if args.large_group_members:
        # A one-shot bootstrap emits one canonical membership event and avoids
        # O(n^2) summary refresh work from repeatedly expanding the same group.
        # 10,000 test emails are well below the production 1 MiB command body
        # limit; membership mutations after bootstrap use the normal endpoint.
        large_group_response = create_conversation(
            command_base_url,
            token,
            "group",
            f"TCP Large Group {args.large_group_members} {stamp}",
            [email for email, _ in accounts[1 : args.large_group_members]],
            timeout_seconds=args.large_group_bootstrap_timeout_seconds,
        )
        large_group_id = large_group_response["conversationID"]
        large_group_count = member_count(query_base_url, token, large_group_id)
        if large_group_count != args.large_group_members:
            raise SystemExit(
                f"large group member count mismatch: expected={args.large_group_members} actual={large_group_count}"
            )
        large_group = {
            "conversationID": large_group_id,
            "members": large_group_count,
            "accountOffset": args.account_offset,
        }
    else:
        large_group = {
            "conversationID": args.large_group_conversation_id,
            "members": None,
            "accountOffset": args.account_offset,
        }

    manifest = {
        "createdAt": int(time.time()),
        "accountOffset": args.account_offset,
        "ownerEmail": owner_email,
        "direct": {"conversationID": direct_id, "members": 2, "accountOffset": args.account_offset},
        "smallGroup": {
            "conversationID": small_group_id,
            "members": args.small_group_members,
            "accountOffset": args.account_offset,
        },
        "largeGroup": large_group,
    }
    output_path = Path(args.output_file)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(
        "message_test_fixtures result=pass "
        f"directConversationID={direct_id} directMembers={direct_members} "
        f"smallGroupConversationID={small_group_id} smallGroupMembers={small_group_count} "
        f"largeGroupConversationID={large_group['conversationID']} largeGroupMembers={large_group['members']} "
        f"output={output_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

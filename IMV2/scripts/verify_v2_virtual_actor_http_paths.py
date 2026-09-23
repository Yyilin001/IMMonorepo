#!/usr/bin/env python3
"""Exercise Account HTTP administration and media through a disposable Actor stack.

Required arguments identify the HTTPS Account URL and CA, the already-running
task-owned Compose file/project/env/context, a private registration recovery
directory, and the in-container IMV2LocalGatewayProbe binary. This script does
not start a stack. It rejects the default developer project/Compose file,
unexpected HTTP statuses, malformed signed targets, incomplete media state,
and missing SQL ownership. Credentials and signed media URLs stay in memory;
output contains only phase names.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
from pathlib import Path
import secrets
import ssl
import subprocess
import sys
import time
import urllib.parse
import uuid


ROOT = Path(__file__).resolve().parents[2]


class SmokeFailure(Exception):
    pass


def checked(condition: bool) -> None:
    if not condition:
        raise SmokeFailure()


def run_private(command: list[str], *, environment: dict[str, str] | None = None,
                input_text: str | None = None, timeout: int = 30) -> str:
    result = subprocess.run(command, input=input_text, text=True, capture_output=True,
                            env=environment, timeout=timeout, check=False)
    checked(result.returncode == 0)
    return result.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("account-url", "ca", "compose-file", "env-file", "project",
                   "context", "recovery-directory", "gateway-probe-path"):
        parser.add_argument("--" + option, required=True)
    args = parser.parse_args()
    phase = "preflight"
    try:
        compose_file = Path(args.compose_file).resolve(strict=True)
        env_file = Path(args.env_file).resolve(strict=True)
        ca = Path(args.ca).resolve(strict=True)
        recovery = Path(args.recovery_directory).resolve()
        checked(all(Path(value).is_absolute() for value in (
            args.ca, args.compose_file, args.env_file, args.recovery_directory)))
        checked(ca.is_file() and compose_file.is_file() and env_file.is_file())
        checked(args.project != "imv2localaccount" and args.project.startswith("imv2-va-"))
        checked(compose_file != ROOT / "IMV2/docker-compose.local-account.yml")
        checked(args.gateway_probe_path.startswith("/"))
        base = urllib.parse.urlsplit(args.account_url)
        checked(base.scheme == "https" and base.hostname is not None and base.port is not None)
        checked(not base.path.rstrip("/") and not base.query and not base.fragment)
        context = ssl.create_default_context(cafile=str(ca))
        compose = ["docker", "--context", args.context, "compose", "--project-name", args.project,
                   "--env-file", str(env_file), "--file", str(compose_file)]
        suffix = uuid.uuid4().hex[:20]
        room_id = str(uuid.uuid4())

        def http_request(method: str, path: str, *, body: dict | bytes | None = None,
                         identity: tuple[str, str] | None = None,
                         extra_headers: dict[str, str] | None = None,
                         expected: int = 200, signed_authority: str | None = None) -> dict | bytes:
            headers = dict(extra_headers or {})
            if identity is not None:
                headers["Authorization"] = "Bearer " + identity[0]
                headers["X-IM-Device-ID"] = identity[1]
            payload: bytes | None
            if isinstance(body, dict):
                payload = json.dumps(body, separators=(",", ":")).encode()
                headers["Content-Type"] = "application/json"
            else:
                payload = body
            if signed_authority is not None:
                headers["Host"] = signed_authority
            connection = http.client.HTTPSConnection(base.hostname, base.port, context=context, timeout=15)
            try:
                connection.request(method, path, body=payload, headers=headers)
                response = connection.getresponse()
                data = response.read(2_000_000)
                checked(response.status == expected)
                checked("no-store" in (response.getheader("Cache-Control") or "").lower())
                if response.getheader("Content-Type", "").startswith("application/json"):
                    return json.loads(data)
                return data
            finally:
                connection.close()

        def signed_path(target: dict, expected_prefix: str) -> tuple[str, str, dict[str, str]]:
            url = urllib.parse.urlsplit(target["url"])
            # Keep the signed URL's authority and query unchanged; only the TCP
            # destination is remapped to the random host port of this project.
            checked(url.scheme == "https" and url.hostname == base.hostname)
            checked(url.username is None and url.password is None and not url.fragment)
            checked(url.path.startswith(expected_prefix) and url.port == 8443)
            headers = target["headers"]
            checked(isinstance(headers, dict) and all(isinstance(k, str) and isinstance(v, str)
                                                      for k, v in headers.items()))
            return (url.path + ("?" + url.query if url.query else ""),
                    url.netloc, headers)

        def domain_id(value: object) -> str:
            # Core's Codable identifiers are objects with a rawValue field;
            # invitation HTTP DTOs use plain strings instead.
            raw = value.get("rawValue") if isinstance(value, dict) else value
            checked(isinstance(raw, str))
            return str(uuid.UUID(raw))

        def account(label: str) -> tuple[str, tuple[str, str]]:
            device_id = str(uuid.uuid4())
            operation_id = str(uuid.uuid4())
            password = secrets.token_urlsafe(24)
            registered = http_request("POST", "/v2/account-auth/password/register", body={
                "accountHandle": f"va-{label}-{suffix}", "publicHandle": f"va{label}{suffix}",
                "displayName": f"Actor {label}", "password": password, "deviceID": device_id,
            })
            checked(isinstance(registered, dict) and isinstance(registered.get("accountAssertion"), str))
            cancellation = json.loads(run_private([
                sys.executable, str(ROOT / "IMV2/scripts/prepare_v2_registration_cancellation.py"),
                device_id, operation_id, str(recovery),
            ]))
            issued = http_request("POST", "/v2/device-credentials", body={
                "accountAssertion": registered["accountAssertion"], "deviceID": device_id,
                "operationID": operation_id, "cancellation": cancellation,
            })
            checked(isinstance(issued, dict) and isinstance(issued.get("accessToken"), str))
            user_id = str(uuid.UUID(issued["userID"]))
            return user_id, (issued["accessToken"], device_id)

        phase = "register two isolated accounts"
        owner_id, owner = account("owner")
        peer_id, peer = account("peer")

        phase = "seed one owned group fixture"
        fixture = """
BEGIN;
INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id, capacity_class, membership_revision)
VALUES (:'room'::uuid, 'rooms-primary', 'standard', 'standard', 1);
INSERT INTO im_v2.room_owner_routes (room_id, room_shard_id, route_epoch, created_at, updated_at)
VALUES (:'room'::uuid, 'rooms-primary', 0, clock_timestamp(), clock_timestamp());
INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at)
VALUES (:'room'::uuid, :'owner'::uuid, 'Actor HTTP smoke', clock_timestamp());
INSERT INTO im_v2.room_admission
  (room_id, eligible_member_count, command_window_limit, shard_lease_id, shard_lease_generation)
SELECT :'room'::uuid, 1, command_window_limit, lease_id, generation
FROM im_v2.shard_admission_pools
WHERE room_shard_id = 'rooms-primary' AND capacity_profile_id = 'standard';
INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision)
VALUES (:'room'::uuid, :'owner'::uuid, 'owner', 1);
COMMIT;
"""
        run_private(compose + ["exec", "-T", "postgres", "psql", "-v", "ON_ERROR_STOP=1",
                               "-v", "room=" + room_id, "-v", "owner=" + owner_id,
                               "-U", "im_v2", "-d", "im_v2"], input_text=fixture)
        seeded = run_private(compose + ["exec", "-T", "postgres", "psql", "-tA", "-v", "ON_ERROR_STOP=1",
                                        "-v", "room=" + room_id, "-U", "im_v2", "-d", "im_v2"],
                             input_text="SELECT count(*) FROM im_v2.room_admission WHERE room_id = :'room'::uuid;\n")
        checked(seeded == "1")

        phase = "group nickname write and read"
        nickname = "Actor HTTP " + suffix[:8]
        updated = http_request("PUT", f"/v2/profile-presentations/groups/{room_id}/nickname",
                               identity=owner, body={"operation_id": str(uuid.uuid4()), "nickname": nickname})
        checked(isinstance(updated, dict) and updated["nickname"]["groupNickname"] == nickname)
        listed = http_request("GET", f"/v2/profile-presentations/groups/{room_id}/nicknames?limit=20",
                              identity=owner)
        checked(isinstance(listed, dict) and any(
            domain_id(item.get("userID")) == owner_id and item.get("groupNickname") == nickname
            for item in listed["nicknames"]))

        phase = "invitation create preview apply approve"
        invitation = http_request("POST", "/v2/group-invites", identity=owner, body={
            "room_id": room_id, "operation_id": str(uuid.uuid4()),
            "lifetime_seconds": 3600, "maximum_approved_uses": 1,
        })
        checked(isinstance(invitation, dict) and invitation["room_id"].lower() == room_id)
        checked(isinstance(invitation.get("token"), str))
        preview = http_request("POST", "/v2/group-invites/preview", identity=peer,
                               body={"token": invitation["token"]})
        checked(isinstance(preview, dict) and preview["room_id"].lower() == room_id)
        checked(preview["is_already_member"] is False)
        submission = http_request("POST", "/v2/group-join-requests", identity=peer, body={
            "token": invitation["token"], "operation_id": str(uuid.uuid4()), "note": "Actor smoke",
        })
        checked(isinstance(submission, dict) and submission["kind"] == "submitted")
        checked(submission["request"]["applicant"]["user_id"].lower() == peer_id)
        request_id = str(uuid.UUID(submission["request"]["request_id"]))
        decision = http_request("POST", f"/v2/group-join-requests/{request_id}/decision",
                                identity=owner, body={"room_id": room_id,
                                                      "operation_id": str(uuid.uuid4()),
                                                      "decision": "approve"})
        checked(isinstance(decision, dict) and decision["kind"] == "approved")
        peer_view = http_request("GET", f"/v2/profile-presentations/groups/{room_id}/nicknames?limit=20",
                                 identity=peer)
        checked(isinstance(peer_view, dict) and any(
            domain_id(item.get("userID")) == owner_id and item.get("groupNickname") == nickname
            for item in peer_view["nicknames"]))

        phase = "media upload target and signed object PUT"
        media_id = str(uuid.uuid4())
        payload = ("actor-http-media-" + suffix).encode()
        upload = http_request("POST", "/v2/media/uploads", identity=owner, body={
            "operationID": str(uuid.uuid4()), "mediaID": media_id,
            "contentType": "text/plain", "byteCount": len(payload),
        })
        checked(isinstance(upload, dict) and upload["expectedByteCount"] == len(payload))
        upload_path, upload_authority, upload_headers = signed_path(upload, "/v2/local-media/upload/")
        upload_headers.setdefault("Content-Type", "text/plain")
        upload_headers["Content-Length"] = str(len(payload))
        http_request("PUT", upload_path, body=payload, extra_headers=upload_headers,
                     signed_authority=upload_authority, expected=204)
        http_request("POST", f"/v2/media/{media_id}/complete", identity=owner, expected=204)
        deadline = time.monotonic() + 30
        while True:
            state = http_request("GET", f"/v2/media/{media_id}/upload-status", identity=owner)
            checked(isinstance(state, dict))
            if state["state"] == "available":
                break
            checked(state["state"] in ("pendingUpload", "scanning") and time.monotonic() < deadline)
            time.sleep(0.25)

        phase = "authenticated gateway media send"
        client_message_id = str(uuid.uuid4())
        probe_env = os.environ.copy()
        probe_env.update({
            "IM_V2_GATEWAY_PROBE_MODE": "sendRoomMediaMessage",
            "IM_V2_GATEWAY_PROBE_ACCESS_TOKEN": owner[0],
            "IM_V2_GATEWAY_PROBE_DEVICE_ID": owner[1],
            "IM_V2_GATEWAY_PROBE_EXPECTED_ROOM_ID": room_id,
            "IM_V2_GATEWAY_PROBE_MEDIA_ID": media_id,
            "IM_V2_GATEWAY_PROBE_CLIENT_MESSAGE_ID": client_message_id,
        })
        probe_keys = (
            "IM_V2_GATEWAY_PROBE_MODE", "IM_V2_GATEWAY_PROBE_ACCESS_TOKEN",
            "IM_V2_GATEWAY_PROBE_DEVICE_ID", "IM_V2_GATEWAY_PROBE_EXPECTED_ROOM_ID",
            "IM_V2_GATEWAY_PROBE_MEDIA_ID", "IM_V2_GATEWAY_PROBE_CLIENT_MESSAGE_ID",
        )
        sent = run_private(
            compose + ["exec", "-T"] + [part for key in probe_keys for part in ("--env", key)]
            + ["gateway", args.gateway_probe_path], environment=probe_env, timeout=30)
        room_reply, message_reply = sent.split()
        checked(str(uuid.UUID(room_reply)) == room_id)
        message_id = str(uuid.UUID(message_reply))

        phase = "persisted message ownership and unique send"
        proof = """
SELECT (SELECT count(*) FROM im_v2.messages
        WHERE room_id = :'room'::uuid AND sender_user_id = :'owner'::uuid
          AND client_message_id = :'client_message'::uuid),
       (SELECT count(*) FROM im_v2.messages
        WHERE room_id = :'room'::uuid AND sender_user_id = :'owner'::uuid
          AND client_message_id = :'client_message'::uuid AND message_id = :'message'::uuid),
       (SELECT count(*) FROM im_v2.message_media_references
        WHERE message_id = :'message'::uuid AND media_id = :'media'::uuid);
"""
        counts = run_private(compose + ["exec", "-T", "postgres", "psql", "-tA", "-v", "ON_ERROR_STOP=1",
                                        "-v", "room=" + room_id, "-v", "owner=" + owner_id,
                                        "-v", "client_message=" + client_message_id,
                                        "-v", "message=" + message_id, "-v", "media=" + media_id,
                                        "-U", "im_v2", "-d", "im_v2"], input_text=proof)
        checked(counts == "1|1|1")

        phase = "RoomRef media authorization and signed download"
        query = urllib.parse.urlencode({"room_id": room_id, "message_id": message_id})
        download = http_request("GET", f"/v2/media/{media_id}?{query}", identity=owner)
        checked(isinstance(download, dict) and download["expectedByteCount"] == len(payload))
        download_path, download_authority, download_headers = signed_path(download, "/v2/local-media/download/")
        downloaded = http_request("GET", download_path, extra_headers=download_headers,
                                  signed_authority=download_authority)
        checked(downloaded == payload)
        print("ACTOR_HTTP_SMOKE_OK nickname invitation media_send_download")
        return 0
    except Exception as error:
        # Never emit an exception, request body, signed URL, or subprocess output.
        print(f"ACTOR_HTTP_SMOKE_FAILED phase={phase} kind={type(error).__name__}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

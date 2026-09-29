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
import base64
import hashlib
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


def checked(condition: bool, check: str = "unnamed_check") -> None:
    if not condition:
        raise SmokeFailure(check)


def run_private(command: list[str], *, environment: dict[str, str] | None = None,
                input_text: str | None = None, timeout: int = 30) -> str:
    result = subprocess.run(command, input=input_text, text=True, capture_output=True,
                            env=environment, timeout=timeout, check=False)
    checked(result.returncode == 0)
    return result.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("account-url", "ca", "compose-file", "env-file", "project",
                   "context", "recovery-directory", "gateway-probe-path", "gateway-account-url"):
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
        gateway_account_url = urllib.parse.urlsplit(args.gateway_account_url)
        checked(gateway_account_url.scheme == "https" and gateway_account_url.hostname == "account"
                and gateway_account_url.port == 8443 and not gateway_account_url.username
                and not gateway_account_url.password and not gateway_account_url.query
                and not gateway_account_url.fragment and gateway_account_url.path in ("", "/"))
        context = ssl.create_default_context(cafile=str(ca))
        compose = ["docker", "--context", args.context, "compose", "--project-name", args.project,
                   "--env-file", str(env_file), "--file", str(compose_file)]
        suffix = uuid.uuid4().hex[:20]
        room_id = str(uuid.uuid4())

        def http_request(method: str, path: str, *, body: dict | bytes | None = None,
                         identity: tuple[str, str] | None = None,
                         extra_headers: dict[str, str] | None = None,
                         expected: int = 200, signed_authority: str | None = None,
                         route_label: str = "unlabeled") -> dict | list | bytes:
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
                checked(response.status == expected,
                        f"{method} {route_label} status={response.status} expected={expected}")
                checked("no-store" in (response.getheader("Cache-Control") or "").lower(),
                        f"{method} {route_label} cache_control")
                if response.getheader("Content-Type", "").startswith("application/json"):
                    return json.loads(data)
                return data
            finally:
                connection.close()

        def signed_path(target: dict, expected_prefix: str) -> tuple[str, str, dict[str, str]]:
            url = urllib.parse.urlsplit(target["url"])
            # Keep the signed URL's authority and query unchanged; only the TCP
            # destination is remapped to the random host port of this project.
            checked(url.scheme == "https" and url.hostname == base.hostname,
                    "signed_target_scheme_host")
            checked(url.username is None and url.password is None and not url.fragment,
                    "signed_target_authority")
            checked(url.path.startswith(expected_prefix) and url.port == 8443,
                    "signed_target_path_port")
            raw_headers = target["headers"]
            checked(isinstance(raw_headers, list)
                    and all(isinstance(item, dict) and isinstance(item.get("name"), str)
                            and isinstance(item.get("value"), str) for item in raw_headers),
                    "signed_target_headers")
            headers = {item["name"]: item["value"] for item in raw_headers}
            checked(len(headers) == len(raw_headers), "signed_target_unique_headers")
            return (url.path + ("?" + url.query if url.query else ""),
                    url.netloc, headers)

        def domain_id(value: object) -> str:
            # Core's Codable identifiers are objects with a rawValue field;
            # invitation HTTP DTOs use plain strings instead.
            raw = value.get("rawValue") if isinstance(value, dict) else value
            checked(isinstance(raw, str))
            return str(uuid.UUID(raw))

        def page_has_nickname(page: object, user_id: str, nickname: str) -> bool:
            if not isinstance(page, dict):
                return False
            batch = page.get("batch")
            if not isinstance(batch, dict) or not isinstance(batch.get("results"), list):
                return False
            for item in batch["results"]:
                if not isinstance(item, dict):
                    continue
                payload = item.get("presentation")
                if not isinstance(payload, dict) or not isinstance(payload.get("_0"), dict):
                    continue
                member = payload["_0"].get("groupMember")
                if isinstance(member, dict) and member.get("groupNickname") == nickname \
                        and domain_id(member.get("userID")) == user_id:
                    return True
            return False

        def invitation_intent(actor_id: str, action_name: str, action: dict,
                              operation_kind: str) -> dict:
            return {
                "identity": {"accountID": {"rawValue": actor_id},
                             "scope": {"room": {"_0": {"rawValue": room_id}}},
                             "operation": {operation_kind: {"_0": {"rawValue": str(uuid.uuid4())}}}},
                "action": {action_name: action},
                "confirmedUntilMilliseconds": int(time.time() * 1000) + 60_000,
            }

        def invitation_submit(intent: dict, identity: tuple[str, str],
                              secret: str | None = None) -> dict:
            endpoint = f"/v2/rooms/{room_id}/invitation-operations"
            label = "/v2/rooms/:room/invitation-operations"
            authorization = {"rawValue": secret} if secret is not None else None
            admission_result = http_request("POST", endpoint + "/admissions", identity=identity,
                                            route_label=label + "/admissions",
                                            body={"intent": intent, "secretAuthorization": authorization})
            admitted = admission_result.get("admitted") if isinstance(admission_result, dict) else None
            admission = admitted.get("_0") if isinstance(admitted, dict) else None
            checked(isinstance(admission, dict) and isinstance(admission.get("id"), dict),
                    "invitation_admitted")
            result = http_request("POST", endpoint + "/submit", identity=identity,
                                  route_label=label + "/submit",
                                  body={"command": {"intent": intent, "admission": admission},
                                        "secretAuthorization": authorization})
            received = result.get("receipt") if isinstance(result, dict) else None
            receipt = received.get("_0") if isinstance(received, dict) else None
            checked(isinstance(receipt, dict), "invitation_receipt")
            outcome = receipt.get("outcome")
            checked(isinstance(outcome, dict), "invitation_receipt_outcome")
            value = outcome.get("applied", outcome.get("alreadySatisfied"))
            checked(isinstance(value, dict) and isinstance(value.get("_0"), dict),
                    "invitation_applied")
            return value["_0"]

        def invitation_revision(identity: tuple[str, str]) -> int:
            baseline = http_request("GET", f"/v2/rooms/{room_id}/invitation-operations/baseline",
                                    identity=identity,
                                    route_label="/v2/rooms/:room/invitation-operations/baseline")
            checked(isinstance(baseline, dict) and domain_id(baseline.get("roomID")) == room_id
                    and isinstance(baseline.get("membershipRevision"), int),
                    "invitation_baseline")
            return baseline["membershipRevision"]

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
        nickname_operation_id = str(uuid.uuid4())
        updated = http_request("PUT", f"/v2/profile-presentations/groups/{room_id}/nickname",
                               identity=owner, route_label="/v2/profile-presentations/groups/:room/nickname",
                               body={"actorUserID": {"rawValue": owner_id},
                                     "roomID": {"rawValue": room_id},
                                     "operationID": {"rawValue": nickname_operation_id},
                                     "nickname": nickname,
                                     "firstSubmissionDeadlineMilliseconds": int(time.time() * 1000) + 60_000})
        committed = updated.get("outcome", {}).get("committed", {}).get("_0") if isinstance(updated, dict) else None
        checked(isinstance(committed, dict) and committed.get("groupNickname") == nickname,
                "group_nickname_receipt_committed")
        listed = http_request("GET", f"/v2/profile-presentations/groups/{room_id}/nicknames?limit=20",
                              identity=owner, route_label="/v2/profile-presentations/groups/:room/nicknames")
        checked(page_has_nickname(listed, owner_id, nickname), "group_nickname_owner_list")

        phase = "invitation create preview apply approve"
        created = invitation_submit(invitation_intent(owner_id, "create", {
            "lifetimeSeconds": 3600, "maximumApprovedUses": 1,
            "expectedMembershipRevision": invitation_revision(owner),
        }, "groupInvite"), owner)
        invite = created.get("inviteCreated")
        checked(isinstance(invite, dict), "invite_create_receipt")
        invite_id = domain_id(invite.get("inviteID"))
        links = http_request("GET", f"/v2/group-invites?{urllib.parse.urlencode({'room_id': room_id})}",
                             identity=owner, route_label="/v2/group-invites")
        checked(isinstance(links, dict) and isinstance(links.get("items"), list),
                "invite_directory_list")
        invitation = next((item for item in links["items"] if isinstance(item, dict)
                           and item.get("invite_id", "").lower() == invite_id), None)
        checked(isinstance(invitation, dict) and invitation.get("room_id", "").lower() == room_id
                and isinstance(invitation.get("token"), str), "invite_directory_created")
        preview = http_request("POST", "/v2/group-invites/preview", identity=peer,
                               body={"token": invitation["token"]},
                               route_label="/v2/group-invites/preview")
        checked(isinstance(preview, dict) and preview.get("room_id", "").lower() == room_id,
                "invite_preview_room")
        checked(preview.get("is_already_member") is False, "invite_preview_nonmember")
        token_digest = base64.b64encode(hashlib.sha256(invitation["token"].encode()).digest()).decode()
        submitted = invitation_submit(invitation_intent(peer_id, "submit", {
            "inviteID": {"rawValue": invite_id}, "tokenDigest": token_digest,
            "note": "Actor smoke",
        }, "groupJoinRequest"), peer, invitation["token"])
        submission = submitted.get("requestSubmitted")
        checked(isinstance(submission, dict)
                and domain_id(submission.get("inviteID")) == invite_id,
                "join_request_submitted")
        request_id = domain_id(submission.get("requestID"))
        requests = http_request("GET", f"/v2/group-join-requests?{urllib.parse.urlencode({'room_id': room_id})}",
                                identity=owner, route_label="/v2/group-join-requests")
        checked(isinstance(requests, dict) and isinstance(requests.get("items"), list)
                and any(isinstance(item, dict) and item.get("request_id", "").lower() == request_id
                        and item.get("applicant_user_id", "").lower() == peer_id
                        for item in requests["items"]), "join_request_owner_list")
        decided = invitation_submit(invitation_intent(owner_id, "decide", {
            "requestID": {"rawValue": request_id}, "decision": "approve",
            "expectedMembershipRevision": invitation_revision(owner),
        }, "groupJoinDecision"), owner)
        decision = decided.get("requestDecided")
        checked(isinstance(decision, dict) and domain_id(decision.get("requestID")) == request_id
                and decision.get("decision") == "approve", "join_request_approved")
        peer_view = http_request("GET", f"/v2/profile-presentations/groups/{room_id}/nicknames?limit=20",
                                 identity=peer, route_label="/v2/profile-presentations/groups/:room/nicknames")
        checked(page_has_nickname(peer_view, owner_id, nickname), "group_nickname_peer_list")

        phase = "media upload target and signed object PUT"
        media_id = str(uuid.uuid4())
        payload = ("actor-http-media-" + suffix).encode()
        digest = hashlib.sha256(payload).hexdigest()
        session = http_request("POST", "/v2/resource-uploads", identity=owner,
                               route_label="/v2/resource-uploads", body={
            "operationID": {"rawValue": str(uuid.uuid4())},
            "mediaID": {"rawValue": media_id},
            "usage": {"messageAttachment": {"_0": {"rawValue": room_id}}},
            "contentType": "text/plain", "byteCount": len(payload),
            "checksum": {"algorithm": "sha256", "value": digest},
            "clientModes": ["http_put"],
        })
        checked(isinstance(session, dict) and domain_id(session.get("mediaID")) == media_id
                and isinstance(session.get("locator"), dict)
                and isinstance(session.get("generation"), int), "resource_upload_session")
        locator = session["locator"]
        generation = session["generation"]
        plans = http_request("POST", "/v2/resource-uploads/targets", identity=owner,
                             route_label="/v2/resource-uploads/targets",
                             body={"locator": locator, "generation": generation,
                                   "partNumbers": [], "background": False})
        checked(isinstance(plans, list) and len(plans) == 1 and isinstance(plans[0], dict)
                and plans[0].get("mode") == "http_put"
                and plans[0].get("expectedByteCount") == len(payload)
                and plans[0].get("checksum") == {"algorithm": "sha256", "value": digest},
                "resource_upload_target")
        upload_path, upload_authority, upload_headers = signed_path(plans[0], "/v2/local-media/upload/")
        upload_headers.setdefault("Content-Type", "text/plain")
        upload_headers["Content-Length"] = str(len(payload))
        http_request("PUT", upload_path, body=payload, extra_headers=upload_headers,
                     signed_authority=upload_authority, expected=204,
                     route_label="/v2/local-media/upload/:media")
        finalized = http_request("POST", "/v2/resource-uploads/finalize", identity=owner,
                                 route_label="/v2/resource-uploads/finalize",
                                 body={"locator": locator, "generation": generation, "parts": []})
        checked(isinstance(finalized, dict) and finalized.get("state") == "completed",
                "resource_upload_finalized")
        deadline = time.monotonic() + 30
        while True:
            state = http_request("POST", "/v2/resource-uploads/status", identity=owner,
                                 route_label="/v2/resource-uploads/status", body=locator)
            checked(isinstance(state, dict) and state.get("state") == "completed",
                    "resource_upload_status_completed")
            if state.get("resourceState") == "ready":
                break
            checked(state.get("resourceState") in ("scanning", "processing")
                    and time.monotonic() < deadline, "resource_upload_ready")
            time.sleep(0.25)

        phase = "authenticated gateway media send"
        client_message_id = str(uuid.uuid4())
        probe_env = os.environ.copy()

        probe_env.update({
            "IM_V2_GATEWAY_PROBE_ACCOUNT_BASE_URL": args.gateway_account_url,
            "IM_V2_GATEWAY_PROBE_CA_PATH": "/caddy/caddy/pki/authorities/local/root.crt",
            "IM_V2_GATEWAY_PROBE_MODE": "sendRoomMediaMessage",
            "IM_V2_GATEWAY_PROBE_ACCESS_TOKEN": owner[0],
            "IM_V2_GATEWAY_PROBE_DEVICE_ID": owner[1],
            "IM_V2_GATEWAY_PROBE_EXPECTED_ROOM_ID": room_id,
            "IM_V2_GATEWAY_PROBE_MEDIA_ID": media_id,
            "IM_V2_GATEWAY_PROBE_CLIENT_MESSAGE_ID": client_message_id,
            "IM_V2_GATEWAY_PROBE_SEND_DEADLINE_MS": str(int(time.time() * 1000) + 86_400_000),
        })
        probe_keys = (
            "IM_V2_GATEWAY_PROBE_ACCOUNT_BASE_URL", "IM_V2_GATEWAY_PROBE_CA_PATH",
            "IM_V2_GATEWAY_PROBE_MODE", "IM_V2_GATEWAY_PROBE_ACCESS_TOKEN",
            "IM_V2_GATEWAY_PROBE_DEVICE_ID", "IM_V2_GATEWAY_PROBE_EXPECTED_ROOM_ID",
            "IM_V2_GATEWAY_PROBE_MEDIA_ID", "IM_V2_GATEWAY_PROBE_CLIENT_MESSAGE_ID",
            "IM_V2_GATEWAY_PROBE_SEND_DEADLINE_MS",
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
        download = http_request("GET", f"/v2/media/{media_id}?{query}", identity=owner,
                                route_label="/v2/media/:media")
        download_plan = download.get("plan") if isinstance(download, dict) else None
        checked(isinstance(download_plan, dict) and download_plan.get("mode") == "http_get"
                and download_plan.get("expectedByteCount") == len(payload)
                and download_plan.get("checksum") == {"algorithm": "sha256", "value": digest},
                "media_download_target")
        download_path, download_authority, download_headers = signed_path(download_plan, "/v2/resource-bytes/")
        downloaded = http_request("GET", download_path, extra_headers=download_headers,
                                  signed_authority=download_authority,
                                  route_label="/v2/resource-bytes/:placement")
        checked(downloaded == payload, "media_download_bytes")
        print("ACTOR_HTTP_SMOKE_OK nickname invitation media_send_download")
        return 0
    except Exception as error:
        # Never emit an exception, request body, signed URL, or subprocess output.
        check = f" check={error}" if isinstance(error, SmokeFailure) else ""
        print(f"ACTOR_HTTP_SMOKE_FAILED phase={phase} kind={type(error).__name__}{check}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

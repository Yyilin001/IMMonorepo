# Large Group Realtime Delivery

This document defines the beta production path for large group message delivery.
The beta deployment may drop existing test data and redeploy from a clean
database when the realtime model changes.

## Goals

- Support hot conversations with 10000 online users on the single-node profile.
- Keep the write path durable through the conversation timeline.
- Keep realtime delivery best-effort and lightweight for large groups.
- Prove drain behavior with an automated gate, not manual log inspection.

## Non-Goals

- Full message-body fanout to every large-group member.
- Inactive online user realtime hint fanout.
- Timeline-gap realtime payloads for active viewers.
- Runtime reconstruction of large-group events that lack embedded preview data
  or recipient snapshots.
- Runtime switches that silently fall back to unbounded fanout.

## Delivery Semantics

Large-group `message_created` uses one durable source of truth:

```text
conversation timeline + timeline/since catch-up
```

Realtime packets are only hints:

```text
active chat viewers    -> compact conversation-activity hint
inactive online users  -> no realtime fanout; use conversation changes and timeline/since
offline users          -> no realtime fanout
```

Clients must treat compact hints as invalidation signals. A client may render the
preview carried in the hint, but it must reconcile through `timeline/since` for
durable ordering, missing messages, reconnects, and duplicate hints.

## Required Profile

The single-node beta production profile uses:

```text
IM_REALTIME_MESSAGE_CREATED_PREVIEW_LOOKUP_ENABLED=false
IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS=100
IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS=100
IM_GATEWAY_LOCAL_FANOUT_BATCH_SIZE=512
IM_GATEWAY_LOCAL_FANOUT_EVENT_LOOP_YIELD_CHUNKS=32
```

Active compact fanout and inactive pull-only delivery are fixed semantics, not
runtime mode switches.

Do not add a fallback that turns a route/cache failure into full unsplit fanout.
The safe degradation for large groups is to drop best-effort realtime hints and
let clients recover via `timeline/since`.

## Gate

The large-group drain gate is:

```text
connections=10000
activeConversationUsers=10000
messageRate=200 msg/s
messageDuration=60s
expectedMessages=12000
messageAck == messageSent
failures == {}
final Kafka lag == 0
lagClearAfterSendSeconds <= 15
```

Run `monitor_tcp_drain.py` with:

```bash
python3 IMServer/LoadTests/monitor_tcp_drain.py \
  --progress-file /tmp/tcp-10000-e2e-200-progress.json \
  --output-jsonl /tmp/tcp-10000-e2e-200-monitor.jsonl \
  --summary-file /tmp/tcp-10000-e2e-200-summary.json \
  --expected-messages 12000 \
  --sample-interval-seconds 1 \
  --heavy-sample-interval-seconds 5 \
  --post-send-timeout-seconds 180 \
  --metrics-secret production-smoke-internal-secret \
  --max-lag-clear-after-send-seconds 15 \
  --require-acks \
  --require-no-failures \
  --require-final-lag-zero
```

The monitor exits non-zero if the gate fails.

## Verified Result

On 2026-06-16, the 8 vCPU / 16 GiB single-node test server passed:

```text
10000 online
10000-member conversation
200 msg/s for 60s
messageSent=12000
messageAck=12000
messageSendError=0
failures={}
lagClearAfterSendSeconds=14.539
```

This is the baseline for the beta single-node profile.

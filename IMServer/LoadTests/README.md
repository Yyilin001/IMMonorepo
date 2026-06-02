# IMServer Load Tests

These load tests target the private-chat and small-group text IM path only. They do not claim large-group/channel or media delivery capacity.

## Profiles

- `local-smoke`: 100 virtual users, roughly 10 msg/s.
- `staging-baseline`: 10k virtual users, roughly 300 msg/s.
- `capacity-target`: 50k-100k TCP connections and 3k msg/s; run only against isolated capacity infrastructure.

## One-command Baseline

```bash
cd IMServer
./scripts/staging_baseline.sh --profile staging-baseline --env-file LoadTests/staging-baseline.env
```

Create `LoadTests/staging-baseline.env` from `LoadTests/staging-baseline.env.example`. Do not commit real credentials.

For the full multi-device release gate, including service tests, client tests, optional Redis integration, TCPDriver build, and optional staging baseline:

```bash
cd IMServer
./scripts/multidevice_release_gate.sh --env-file LoadTests/staging-baseline.env --staging-baseline
```

## HTTP k6

```bash
cd IMServer/LoadTests/k6
k6 run -e PROFILE=local-smoke -e BASE_URL=http://127.0.0.1:8080 http-small-group.js
```

Required environment:

- `BASE_URL`
- `IM_EMAIL`
- `IM_PASSWORD`
- `IM_MEMBER_EMAILS` as a comma-separated list

Optional environment:

- `IM_CONVERSATION_ID` to reuse an existing conversation
- `IM_INTERNAL_SECRET` to exercise `/internal/im/messages/send`

## Hot Conversation HTTP k6

Use this profile when validating a single high-frequency conversation. It sends all writes to the same conversation through the internal message endpoint, so it stresses sequence allocation, owner routing, the single-conversation write queue, outbox creation, projection lag, and fanout side effects without mixing in conversation creation noise.

```bash
cd IMServer/LoadTests/k6
k6 run \
  -e PROFILE=local-hot-smoke \
  -e BASE_URL=http://127.0.0.1:8080 \
  -e IM_EMAIL="$IM_EMAIL" \
  -e IM_PASSWORD="$IM_PASSWORD" \
  -e IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
  -e IM_INTERNAL_SECRET="$IM_INTERNAL_SECRET" \
  http-hot-conversation-write.js
```

Profiles:

- `local-hot-smoke`: 50 VUs for 1 minute.
- `staging-hot-baseline`: 500 VUs for 10 minutes.
- `capacity-hot-target`: 2k VUs for 20 minutes; run only against isolated capacity infrastructure.

Optional environment:

- `IM_MEMBER_EMAILS` when the script should create a fresh group conversation.
- `IM_SEND_INTERVAL_MS` to add per-VU pacing.
- `IM_METRICS_URL` to sample a non-default metrics endpoint.
- `IM_METRICS_SECRET`, `IM_METRICS_INTERNAL_SECRET`, or `IM_INTERNAL_SHARED_SECRET` to sample `/internal/metrics`.
- `IM_METRICS_SAMPLE_EVERY` to control metrics sampling frequency for VU 1.

Hot conversation go/no-go:

- `im_hot_write_errors` below 0.1%.
- `im_hot_write_send_latency` P95 below 500 ms and P99 below 1s for `staging-hot-baseline`.
- `im_conversation_write_queue_depth` does not stay above 100 for more than 5 minutes.
- `im_outbox_backlog_events` drains after load stops.
- `im_projection_lag_millis` returns below 10s after load stops.
- `im_message_write_queue_rejected_total`, `im_sequence_block_reserve_failures_total`, and `im_conversation_owner_forward_failures_total` remain at zero.

## Message Convergence HTTP k6

Use this profile to measure the HTTP compensation path end to end. Each iteration sends one message, polls `messages/since` until the canonical message is visible, then polls the conversation list until the summary projection catches up to that message.

```bash
cd IMServer/LoadTests/k6
k6 run \
  -e PROFILE=local-convergence-smoke \
  -e BASE_URL=http://127.0.0.1:8080 \
  -e IM_EMAIL="$IM_EMAIL" \
  -e IM_PASSWORD="$IM_PASSWORD" \
  -e IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
  -e IM_INTERNAL_SECRET="$IM_INTERNAL_SECRET" \
  http-message-convergence.js
```

Profiles:

- `local-convergence-smoke`: 10 VUs for 1 minute.
- `staging-convergence-baseline`: 100 VUs for 10 minutes.

Optional environment:

- `IM_CONVERGENCE_TIMEOUT_MS`, default `10000`.
- `IM_CONVERGENCE_POLL_INTERVAL_MS`, default `250`.

Convergence go/no-go:

- TCPDriver ack success rate remains above 99.9%.
- TCPDriver canonical message success rate remains above 99.9%.
- `im_message_convergence_errors` below 0.1%.
- `im_message_accept_latency` P95 below 300 ms for `staging-convergence-baseline`.
- `im_message_timeline_latency` P95 below 2s for `staging-convergence-baseline`.
- `im_message_summary_latency` P95 below 5s for `staging-convergence-baseline`.
- Outbox backlog and projection lag drain back under alert thresholds after the run.

## TCPDriver

```bash
cd IMServer/LoadTests/TCPDriver
swift run IMTCPLoadDriver \
  --profile local-smoke \
  --base-url http://127.0.0.1:8080 \
  --tcp-host 127.0.0.1 \
  --tcp-port 9001 \
  --email "$IM_EMAIL" \
  --password "$IM_PASSWORD" \
  --conversation-id "$IM_CONVERSATION_ID" \
  --connections 5 \
  --devices-per-user 5 \
  --messages 1
```

Required options:

- `--email`
- `--password`
- `--conversation-id`

Useful TCP scenarios:

- `1 user x 5 devices`: `--connections 5 --devices-per-user 5 --messages 1`
- `100 users x 2 devices`: pair HTTP/k6 user load with TCP `--devices-per-user 2`; use more load generator accounts for true multi-user TCP pressure.
- `1 group x 500 members x 2 devices`: create the group through staging fixtures, then run TCPDriver against the target `IM_CONVERSATION_ID` while k6 drives HTTP changes/history reads.
- `AI stream concurrency`: covered by `scripts/staging_baseline.sh`; tune with `IM_AI_STREAM_ATTEMPTS` and `IM_AI_STREAM_CONCURRENCY`.
- `logout all storm`: run TCPDriver continuously, then repeatedly call `DELETE /api/auth/sessions/all` for load accounts.
- `reconnect storm`: covered by `scripts/staging_baseline.sh` when `IM_RECONNECT_STORM_COMMAND` is set to a gateway restart/failover command that validates `messages/since` convergence.

TCPDriver reports:

- ack success rate and ack latency percentiles
- canonical message success rate and canonical latency percentiles
- total fanout message count
- reconnect count
- server error count

## Go/No-Go

- HTTP/TCP error rate below 0.1%.
- TCP ack success rate above 99.9%.
- TCP canonical message success rate above 99.9%.
- `conversations/changes` convergence P95 below 2s.
- Outbox backlog returns to zero or continuously drains after load stops.
- Reconnect `messages/since` success above 99.9%.
- Cross-node dispatch failures and session-count query failures remain at zero.
- AI stream stale repair, finalize failure, and Redis lease heartbeat failure remain at zero during steady state.
- `capacity-target` is not a CI job; it must run in a dedicated environment with a capacity report.

## Production Dashboard

Track these counters or gauges together when reviewing release readiness:

- TCP connections and abnormal disconnect spikes.
- Outbox backlog, publish failures, and dead-letter events.
- Redis route cache hit/miss and stale route cleanup counts.
- AI active streams, lease reservations, lease rejections, lease heartbeat failures, chunk fanout count, snapshot writes, finalize retries, finalize failures, and stale repairs.

Recommended alerts:

- `ai_stream_stale_repair > 0` over a 5 minute window.
- `ai_stream_finalize_failure > 0` over a 5 minute window.
- Outbox backlog grows for 10 consecutive minutes.
- Redis lease heartbeat failures occur in production.
- TCP abnormal disconnects spike above the current baseline.

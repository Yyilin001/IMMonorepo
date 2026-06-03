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

## HTTP Login Capacity

Use this profile to test `/api/auth/login` by itself. Do not mix this result with
TCP online capacity; it measures the HTTP auth/database/session path only.

```bash
cd IMServer/LoadTests/k6
k6 run \
  -e PROFILE=login-baseline \
  -e BASE_URL=http://120.25.106.200:8080 \
  -e ACCOUNT_FILE="$PWD/../accounts/load-10000.csv" \
  http-auth-login.js
```

Profiles:

- `login-smoke`: 1 VU for 20 seconds.
- `login-baseline`: 200 VUs for 10 minutes.
- `login-capacity`: 1000 VUs for 20 minutes.

Optional environment:

- `ACCOUNT_FILE` or `IM_ACCOUNT_FILE`: local `email,password` CSV.
- `IM_ACCOUNT_PREFIX`, `IM_ACCOUNT_DOMAIN`, `IM_ACCOUNT_PASSWORD`,
  `IM_ACCOUNT_START_INDEX`, and `IM_ACCOUNT_COUNT`: generate account emails
  without a CSV.
- `IM_LOGIN_SLEEP_MS`: add per-iteration pacing.

Go/no-go:

- `im_auth_login_errors` below the profile threshold.
- `im_auth_login_latency` P95/P99 below the profile threshold.
- Report login throughput separately from TCP online capacity.

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
  --messages 1 \
  --hold-seconds 0
```

Required options:

- `--email`
- `--password`
- `--conversation-id`

Useful TCP scenarios:

- Idle online capacity ladder: run with `--profile custom --messages 0 --hold-seconds 30`
  to authenticate connections and keep them open while remote CPU, memory, TCP
  connection count, and Kafka lag are sampled. This is the baseline for "how many
  users can stay online".
- `1 user x 5 devices`: `--connections 5 --devices-per-user 5 --messages 1`
- Custom capacity ladder: use `--profile custom` so `--connections` is not capped by
  `local-smoke` or raised by `staging-baseline`; run `100`, `500`, `1000`, `2000`,
  `5000`, then `10000` connections from a separate load generator.
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

Add `--connection-log-file /path/to/tcp-driver.jsonl` when diagnosing TCP lifecycle
issues. The file is JSONL and records `login_start`, `login_ok`, `connection_start`,
`login_attempt_failed`, `login_retry_scheduled`, `nw_ready`, `auth_send_ok`,
`packet_received`, `auth_ok_received`, `heartbeat_send_ok`,
`heartbeat_ack_received`, `connection_disconnected`, `reconnect_scheduled`,
`reconnect_start`, `hold_complete`, `connection_finish`, `connect_timeout_fired`,
`preauth_timeout_fired`, `hold_timeout_fired`, and related failure events per
connection.
Use this when server metrics show `auth_ok` but the driver still reports missing or
closed connections.

Use `--login-cache-file` to separate HTTP login cost from TCP online-capacity tests.
The driver reuses cached access tokens when they are still valid long enough for the
connect ramp; otherwise it falls back to HTTP login and rewrites the cache. Use
`--login-only true` to prewarm the cache without opening TCP connections.
Use `--require-login-cache true` for TCP online-capacity runs where HTTP login must
not be part of the result. In that mode, a missing, undersized, or nearly expired
cache fails fast instead of falling back to HTTP login. Summary output includes
`loginCacheHit`, `loginCacheRecords`, and `loginCacheValidForSeconds`.
JIT HTTP login retries transient failures by default. Use `--login-retries` or
`IM_TCP_LOGIN_RETRIES` and `--login-retry-delay-ms` or
`IM_TCP_LOGIN_RETRY_DELAY_MS` to tune it. `login_failed` is logged only after all
attempts fail.

Use `--connection-queue-pool-size` when the local load generator becomes the
bottleneck. A larger pool reduces timer and send-completion tail latency for
thousands of `NWConnection` instances. Track `heartbeat_send_start.scheduleDriftMs`
and `heartbeat_send_ok.sendCompletionMs` from the JSONL log; if these tails reach
many seconds, split the run across multiple load generators before blaming the
server.

Use `--max-reconnects` for long idle-online hold tests. Reconnect is limited to
`--messages 0` scenarios so message-send tests cannot hide duplicate-send behavior.
Reconnect attempts log `connection_disconnected`, `reconnect_scheduled`, and
`reconnect_start`, then authenticate again and restart heartbeat on the new TCP
connection.

```bash
cd IMServer/LoadTests/TCPDriver
.build/release/IMTCPLoadDriver \
  --profile custom \
  --base-url http://120.25.106.200:8080 \
  --tcp-host 120.25.106.200 \
  --tcp-port 9000 \
  --account-file ../accounts/load-1000.csv \
  --connections 1000 \
  --messages 0 \
  --login-concurrency 20 \
  --timeout-seconds 120 \
  --login-cache-file /tmp/imtcp-login-cache-1000.json \
  --login-only true

.build/release/IMTCPLoadDriver \
  --profile custom \
  --base-url http://120.25.106.200:8080 \
  --tcp-host 120.25.106.200 \
  --tcp-port 9000 \
  --account-file ../accounts/load-1000.csv \
  --conversation-id 00000000-0000-0000-0000-000000000001 \
  --connections 1000 \
  --messages 0 \
  --hold-seconds 180 \
  --connect-ramp-seconds 120 \
  --timeout-seconds 120 \
  --heartbeat-interval-seconds 30 \
  --connection-queue-pool-size 256 \
  --max-reconnects 3 \
  --reconnect-delay-ms 1000 \
  --login-retries 2 \
  --login-cache-file /tmp/imtcp-login-cache-1000.json \
  --connection-log-file /tmp/imtcp-driver-1000-online.jsonl
```

Example 1000-connection idle diagnostic run. Use heartbeat for hold windows longer
than the server TCP idle timeout.

```bash
cd IMServer/LoadTests/TCPDriver
swift run IMTCPLoadDriver \
  --profile custom \
  --base-url http://120.25.106.200:8080 \
  --tcp-host 120.25.106.200 \
  --tcp-port 9000 \
  --account-file ../accounts/load-1000.csv \
  --conversation-id 00000000-0000-0000-0000-000000000001 \
  --connections 1000 \
  --messages 0 \
  --hold-seconds 180 \
  --login-concurrency 20 \
  --connect-ramp-seconds 60 \
  --timeout-seconds 20 \
  --heartbeat-interval-seconds 30 \
  --connection-queue-pool-size 256 \
  --max-reconnects 3 \
  --connection-log-file /tmp/imtcp-driver-1000-heartbeat.jsonl
```

Capacity ladder helper:

```bash
cd IMServer/LoadTests
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
SSH_HOST=root@120.25.106.200 \
LADDER="100 500 1000 2000 5000 10000" \
MESSAGES=0 \
HOLD_SECONDS=30 \
TIMEOUT_SECONDS=90 \
./tcp_capacity_ladder.sh
```

Provision a realistic multi-account pool before running online-capacity tests:

```bash
cd IMServer/LoadTests
COUNT=1000 \
PREFIX=load \
DOMAIN=example.com \
PASSWORD=password1234 \
SSH_HOST=root@120.25.106.200 \
./provision_load_accounts.sh
```

Then run the ladder with that account file:

```bash
cd IMServer/LoadTests
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
SSH_HOST=root@120.25.106.200 \
ACCOUNT_FILE="$PWD/accounts/load-1000.csv" \
LADDER="500 1000" \
MESSAGES=0 \
HOLD_SECONDS=60 \
CONNECT_RAMP_SECONDS=60 \
TIMEOUT_SECONDS=300 \
HEARTBEAT_INTERVAL_SECONDS=30 \
CONNECTION_QUEUE_POOL_SIZE=256 \
MAX_RECONNECTS=3 \
LOGIN_RETRIES=2 \
LOGIN_MODE=just-in-time \
CONNECTION_LOG_DIR=/tmp/imtcp-driver-logs \
./tcp_capacity_ladder.sh
```

### Online Capacity With Login Cache

This is the primary online-user capacity workflow. It prewarms access tokens first,
then the TCP run requires `login_cache_hit`; if the formal run logs any HTTP
`login_start`, the step is invalid.

The server access-token TTL must cover
`CONNECT_RAMP_SECONDS + HOLD_SECONDS + TIMEOUT_SECONDS + LOGIN_CACHE_TTL_GUARD_SECONDS`.
For the 10000-online example below, set `AUTH_ACCESS_TOKEN_TTL_SECONDS=3600` on the
server before prewarming cache.

For high TCP fan-in, set the gateway listen backlog and host SYN backlog above
the target ramp burst before starting the gateway:

```bash
sudo tee /etc/sysctl.d/99-imserver-tcp-capacity.conf >/dev/null <<'EOF'
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_synack_retries = 5
net.ipv4.tcp_abort_on_overflow = 0
EOF
sudo sysctl -p /etc/sysctl.d/99-imserver-tcp-capacity.conf
sudo sed -i 's/^IM_TCP_LISTEN_BACKLOG=.*/IM_TCP_LISTEN_BACKLOG=8192/' /etc/imserver/common.env
grep -q '^IM_TCP_LISTEN_BACKLOG=' /etc/imserver/common.env \
  || echo 'IM_TCP_LISTEN_BACKLOG=8192' | sudo tee -a /etc/imserver/common.env
sudo systemctl restart imserver-gateway
```

Verify that `ss -ltn sport = :9000` shows `Send-Q` at the configured backlog.

For a 10000-online target with two load generators, provision at least 10000
accounts, copy the same CSV to both load generators, then run one command per
machine.

Load generator 1:

```bash
cd IMServer/LoadTests
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
SSH_HOST=root@120.25.106.200 \
ACCOUNT_FILE="$PWD/accounts/load-10000.csv" \
LOAD_GENERATOR_ID=1 \
LOAD_GENERATOR_COUNT=2 \
LADDER="5000" \
MESSAGES=0 \
HOLD_SECONDS=1800 \
CONNECT_RAMP_SECONDS=900 \
TIMEOUT_SECONDS=30 \
HEARTBEAT_INTERVAL_SECONDS=15 \
CONNECTION_QUEUE_POOL_SIZE=256 \
MAX_RECONNECTS=3 \
PREWARM_LOGIN_CACHE=true \
LOGIN_CACHE_DIR=/tmp/imtcp-login-cache \
LOGIN_CACHE_TTL_GUARD_SECONDS=60 \
LOGIN_MODE=upfront \
CONNECTION_LOG_DIR=/tmp/imtcp-driver-logs \
./tcp_capacity_ladder.sh
```

Load generator 2 uses the same command with `LOAD_GENERATOR_ID=2`.

Single-machine local sharding is available when you cannot use two load
generators. It runs multiple TCPDriver processes on the same host so one process
does not become the bottleneck:

```bash
cd IMServer/LoadTests
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
SSH_HOST=root@120.25.106.200 \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
CONNECTIONS=5000 \
LOCAL_DRIVER_SHARDS=5 \
MESSAGES=0 \
HOLD_SECONDS=1800 \
CONNECT_RAMP_SECONDS=900 \
TIMEOUT_SECONDS=30 \
HEARTBEAT_INTERVAL_SECONDS=15 \
HEARTBEAT_LOG_MODE=errors \
CONNECTION_QUEUE_POOL_SIZE=256 \
MAX_RECONNECTS=3 \
PREWARM_LOGIN_CACHE=true \
LOGIN_CACHE_DIR=/tmp/imtcp-login-cache-local-shards \
LOGIN_CACHE_TTL_GUARD_SECONDS=60 \
CONNECTION_LOG_DIR=/tmp/imtcp-driver-logs-local-shards \
./tcp_capacity_local_shards.sh
```

Acceptance for each generator:

- `loginCacheHit=true`, `loginCacheRecords >= connections`, and no HTTP
  `login_start` in the formal TCP run JSONL.
- `successes / connections >= 99.9%`.
- `connect_timeout_fired + preauth_timeout_fired < 0.1%`.
- `heartbeat_send_ok.sendCompletionMs` P99 below 10s; if this exceeds 10s while
  server CPU and memory are low, split into more load generators.
- Server `established_9000`, gateway CPU/memory, and Kafka lag are recorded during
  the run.

Use `MESSAGES`, `DEVICES_PER_USER`, `SEND_INTERVAL_MS`, `TIMEOUT_SECONDS`, and
`COOLDOWN_SECONDS` to tune each step. Set `MESSAGES=0` plus `HOLD_SECONDS` for
idle online capacity. Set `MESSAGES=1` or higher for a hot-conversation fanout
test; that is intentionally heavier and should not be interpreted as idle online
user capacity. When `MESSAGES=0` and `DEVICES_PER_USER` is unset, the helper uses
one device session per connection because the server intentionally kicks duplicate
connections for the same session. `LOGIN_CONCURRENCY` defaults to `5` for device
session pre-warm; lower it if the auth/database path becomes the bottleneck.
`ACCOUNT_FILE` points to a local `email,password` CSV and makes TCPDriver round-robin
connections across real accounts.
`CONNECT_RAMP_SECONDS` staggers TCP connection startup; use it to separate steady
online capacity from a same-instant reconnect storm.
`LOGIN_MODE=just-in-time` logs in each virtual user immediately before its ramped
TCP connect. This better simulates real clients but can make the local generator's
HTTP stack part of the test. `LOGIN_RETRIES` retries transient HTTP login timeouts;
if `login_attempt_failed` grows but `login_failed` stays at zero, login jitter was
absorbed by retries.
For official online-capacity numbers, use `PREWARM_LOGIN_CACHE=true` and
`LOGIN_MODE=upfront`; reserve `LOGIN_MODE=just-in-time` for combined login+TCP
experiments.
`SAMPLE_DURING_SECONDS` controls remote metric sampling while the driver is still
running; set it to `0` to disable during-run samples.
`HEARTBEAT_INTERVAL_SECONDS` sends TCP heartbeat packets after auth succeeds. Keep
it lower than server `IM_TCP_IDLE_TIMEOUT` when `MESSAGES=0` and `HOLD_SECONDS`
is used to simulate long-lived online clients. `HEARTBEAT_LOG_MODE` defaults to
`errors` for capacity runs so heartbeat success traffic is aggregated in the
summary instead of written for every heartbeat. Use `sample` or `all` only for
diagnostic runs. The summary prints `heartbeatSendCompletionMs` p50/p95/p99; P99
above 10s usually means the load generator is overloaded.
`connect_timeout_fired` means the TCP connection did not reach `nw_ready` within
`TIMEOUT_SECONDS`. `preauth_timeout_fired` means TCP reached `nw_ready` and auth was
sent, but `authOK` did not arrive within `TIMEOUT_SECONDS`.
Use `--connection-queue-pool-size` or `IM_TCP_CONNECTION_QUEUE_POOL_SIZE` to control
how many DispatchQueues TCPDriver uses for NWConnection callbacks and timers.
The default is capped at 64 queues. This avoids one serial queue per connection,
which becomes expensive at thousands of connections. If `sendCompletionMs` stays
high, try `32`, `64`, and `128` before changing server settings.
On a single Mac load generator, observed signs of generator saturation are
`heartbeat_send_ok.sendCompletionMs` P99 above 10s, growing
`connect_timeout_fired`, and HTTP `login_attempt_failed` while the server gateway
CPU and memory remain low. Treat that as a load-generator limit and split the run
across multiple machines; do not treat it as the IM server's online-user limit.
`PROTOCOL_VERSION` defaults to `9`; set it only when the generated
realtime protocol version changes. Run it from a load generator, not from the
IMServer host.

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

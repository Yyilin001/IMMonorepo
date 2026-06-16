# IMServer Load Tests

These load tests cover the text IM capacity paths that are currently production
gated: HTTP login, private/small-group baseline traffic, TCP online capacity,
and hot large-group message delivery through lightweight realtime hints plus
`timeline/since` catch-up. They do not claim media delivery, push notification,
or channel/broadcast capacity unless a profile explicitly says so.

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

## Load-Test Gate Self-Test

Run this after changing TCP ladder metrics, gates, message-send wrappers, or
shell helpers. It does not open network connections or run the Swift TCP driver;
it sources the ladder functions and verifies the release-gate behavior for
metrics snapshots, timeline/since P95/P99, visibility scan limits, and
message-send production defaults.

```bash
cd IMServer
./LoadTests/tcp_capacity_ladder_test.sh
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

### Fast Offline Login Cache

For a single 8 vCPU / 16 GiB load-test server, keep HTTP login outside the
online-capacity run and prewarm the cache in parallel. This avoids repeating the
old 10-minute connection ramp for every message test. On the 5000-account
Shenzhen test server, `CONCURRENCY=96` generated a 5000-record login cache in
about 3 minutes; adjust it down if the command API CPU saturates or login errors
appear.

Generate a 5000-account cache:

```bash
cd IMServer/LoadTests
./prewarm_login_cache_parallel.py \
  --base-url http://47.106.103.10:8080 \
  --account-file /tmp/load-5000.csv \
  --connections 5000 \
  --login-cache-file /tmp/imtcp-login-cache-new-5000.json \
  --concurrency 96 \
  --request-timeout-seconds 30 \
  --login-retries 2
```

Then run the online check in strict cache-only mode. This profile has been
validated with 5000/5000 `authOK`, zero failures, and normal heartbeat ACKs
using a 180-second ramp:

```bash
python3 /opt/imserver/IMMonorepo/IMServer/LoadTests/tcp_online_driver.py \
  --tcp-host 127.0.0.1 \
  --tcp-port 9000 \
  --connections 5000 \
  --connect-ramp-seconds 180 \
  --hold-seconds 1200 \
  --timeout-seconds 240 \
  --heartbeat-interval-seconds 30 \
  --barrier-keepalive-seconds 15 \
  --barrier-batch-size 500 \
  --login-cache-file /tmp/imtcp-login-cache-new-5000.json \
  --login-cache-ttl-guard-seconds 30 \
  --suppress-packet-received-log \
  --progress-file /tmp/tcp-5000-msgtest-progress.json \
  --progress-interval-seconds 1
```

Use a longer ramp only when the load generator itself is saturated or when
auth/connect timeout counters increase. If the cache is still valid, do not
prewarm again; reuse it for repeated message-rate tests.

### Slow Offline Login Cache

On small servers, do not prewarm hundreds or thousands of HTTP logins inside the
same ladder step. Generate the login cache first with low pressure, then run the
TCP test in strict cache-only mode.

Generate a 1000-account cache with small batches:

```bash
cd IMServer/LoadTests
ACCOUNT_FILE="$PWD/accounts/load-1000.csv" \
CONNECTIONS=1000 \
BASE_URL=http://120.25.106.200:8080 \
LOGIN_CACHE_FILE=/tmp/imtcp-login-cache-slow/tcp-login-cache-lg1-1000.json \
BATCH_SIZE=50 \
BATCH_PAUSE_SECONDS=5 \
REQUEST_TIMEOUT_SECONDS=30 \
LOGIN_RETRIES=2 \
./prewarm_login_cache_slow.sh
```

Then run online capacity without any HTTP login fallback:

```bash
cd IMServer/LoadTests
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
SSH_HOST=root@120.25.106.200 \
ACCOUNT_FILE="$PWD/accounts/load-1000.csv" \
LADDER="1000" \
MESSAGES=0 \
HOLD_SECONDS=1800 \
CONNECT_RAMP_SECONDS=120 \
TIMEOUT_SECONDS=30 \
HEARTBEAT_INTERVAL_SECONDS=15 \
PREWARM_LOGIN_CACHE=false \
REQUIRE_LOGIN_CACHE=true \
LOGIN_CACHE_FILE=/tmp/imtcp-login-cache-slow/tcp-login-cache-lg1-1000.json \
LOGIN_CACHE_TTL_GUARD_SECONDS=600 \
CONNECTION_LOG_DIR=/tmp/imtcp-driver-logs \
./tcp_capacity_ladder.sh
```

For message-send tests, reuse the same cache:

```bash
cd IMServer/LoadTests
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
SSH_HOST=root@120.25.106.200 \
ACCOUNT_FILE="$PWD/accounts/load-1000.csv" \
ONLINE_LADDER="1000" \
MESSAGE_RATES="5 10" \
MESSAGE_COMPLETION_MODE=ack-only \
MESSAGE_HOLD_SECONDS=60 \
MESSAGE_CONNECT_RAMP_SECONDS=120 \
PREWARM_LOGIN_CACHE=false \
REQUIRE_LOGIN_CACHE=true \
LOGIN_CACHE_FILE=/tmp/imtcp-login-cache-slow/tcp-login-cache-lg1-1000.json \
LOGIN_CACHE_TTL_GUARD_SECONDS=600 \
MESSAGE_METRICS_GATE_MODE=fail \
MESSAGE_COLLECT_REMOTE_METRICS=true \
MESSAGE_COLLECT_IM_METRICS=true \
MESSAGE_COLLECT_IM_METRICS_DELTA=true \
./tcp_message_send_ladder.sh
```

If the cache is missing, too small, or too close to expiry, the strict TCP run
fails before it can perform HTTP login. That failure is intentional: it keeps
HTTP login capacity separate from TCP online or message-delivery conclusions.

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

`tcp_capacity_local_shards.sh` passes the same active-room controls as the main
ladder, including `ACTIVE_CONVERSATION_USERS` and
`GLOBAL_HOLD_BARRIER_MIN_RATIO`, so single-machine sharding can still model
"all users authenticated before hold" and "N users actively viewing this
conversation" scenarios. It also uses the same remote `/internal/metrics`
delta and `IM_METRICS_GATE_MODE` checks as the main ladder; in `fail` mode a
local-shards run is invalid without `SSH_HOST`, remote metrics collection, and
before/after IM metrics deltas. Use `LOCAL_SHARDS_DRY_RUN=true` to print the
per-shard TCPDriver arguments without building or opening network connections.
`LOCAL_DRIVER_SHARDS` must be less than or equal to `CONNECTIONS`; each shard
must own at least one connection.

Acceptance for each generator:

- `loginCacheHit=true`, `loginCacheRecords >= connections`, and no HTTP
  `login_start` in the formal TCP run JSONL.
- `successes / connections >= 99.9%`.
- `connect_timeout_fired + preauth_timeout_fired < 0.1%`.
- `heartbeat_send_ok.sendCompletionMs` P99 below 10s; if this exceeds 10s while
  server CPU and memory are low, split into more load generators.
- Server `established_9000`, gateway CPU/memory, and Kafka lag are recorded during
  the run.

### Message Send And Delivery Capacity

Use this workflow after online capacity is known. It keeps users online with
cached login tokens, then sends messages at a controlled global rate and verifies
that the paired receiver observes the realtime message event.

`tcp_message_send_ladder.sh` is fail-closed by default for production-style
runs: it prewarms login cache, requires the formal TCP run to use that cache,
collects remote `/internal/metrics` deltas, and sets
`IM_METRICS_GATE_MODE=fail` for the delegated `tcp_capacity_ladder.sh` step.
Override with `MESSAGE_METRICS_GATE_MODE=warn|off` only for local exploratory
runs whose results will not be used as production evidence.

Do not start with the server's maximum idle-online connection count. For the
current 2 vCPU / 2 GiB single-node server, use `1000`, `2000`, then `3000`
connections first; avoid `4000+` message tests until idle-online capacity has
headroom.

Single load generator example:

```bash
cd IMServer/LoadTests
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
SSH_HOST=root@120.25.106.200 \
ACCOUNT_FILE="$PWD/accounts/load-3000.csv" \
ONLINE_LADDER="1000 2000 3000" \
MESSAGE_RATES="10 50 100" \
MESSAGE_HOLD_SECONDS=600 \
MESSAGE_CONNECT_RAMP_SECONDS=300 \
MESSAGE_METRICS_GATE_MODE=fail \
./tcp_message_send_ladder.sh
```

Message profile parameters:

- `MESSAGE_PROFILE=per-connection` makes each
  connection sends `MESSAGES` messages and expects its own ack/canonical event.
- `MESSAGE_PROFILE=pair-delivery` pairs sender `i` with receiver
  `(i + MESSAGE_RECEIVER_OFFSET) % connections` and records delivery latency when
  the receiver sees the matching `clientMessageID`.
- `MESSAGE_RATE_PER_SECOND` controls the global send rate in `pair-delivery`.
  When it is greater than zero, total messages are approximately
  `MESSAGE_RATE_PER_SECOND * HOLD_SECONDS`, spread evenly across senders.
- `MESSAGE_SENDER_EVERY=1` means every connection sends. Use `2`, `5`, or `10`
  to reduce the active sender population while keeping receivers online.
- `MESSAGE_PREWARM_LOGIN_CACHE=true` and `MESSAGE_REQUIRE_LOGIN_CACHE=true` are
  the production defaults. A formal message-send run must not perform JIT HTTP
  login.
- `MESSAGE_METRICS_GATE_MODE=fail` is the production default. It fails a step on
  active fanout route drops, gateway relay failures, timeline/since misses,
  visibility scan-limit hits, slow timeline reads, owner batch write stalls, or
  projection lag beyond the configured gate thresholds.
- `MESSAGE_SEND_LADDER_DRY_RUN=true` prints the delegated
  `tcp_capacity_ladder.sh` settings without opening network connections; this is
  used by the shell self-test.

Recommended ladder for the current single-node server:

```text
1000 online, 10 msg/s, hold 10m
1000 online, 50 msg/s, hold 10m
1000 online, 100 msg/s, hold 10m
2000 online, 10 msg/s, hold 10m
2000 online, 50 msg/s, hold 10m
2000 online, 100 msg/s, hold 10m
3000 online, 10 msg/s, hold 10m
3000 online, 50 msg/s, hold 10m
```

Latest verified single-node large-group result:

```text
2026-06-16, 8 vCPU / 16 GiB test node
10000 online, 10000-member conversation, 200 msg/s, 60s send window
connections=10000 successes=10000 authOK=10000
messageSent=12000 messageAck=12000 messageSendError=0 failures={}
messageReceived=13153557 heartbeatSent=165067 heartbeatAck=165067
lagClearAfterSendSeconds=14.539
Kafka consumer lag drained to 0 for domain, realtime, summary, notification
```

This result uses cached logins, `compact-only` active conversation fanout,
`pull-only` inactive hints, `IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS=100`,
`IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS=100`,
`IM_GATEWAY_LOCAL_FANOUT_BATCH_SIZE=512`, and
`IM_GATEWAY_LOCAL_FANOUT_EVENT_LOOP_YIELD_CHUNKS=32`. It validates the large-group
compact/timeline-pull model, not full message-body fanout to every member.

Recent 200 msg/s drain tuning history:

```text
activeCompactMs  gatewayBatch  yieldChunks  lagClearAfterSendSeconds
50               64            64(default)  29.708
100              64            64(default)  24.609
100              128           64(default)  20.816
100              256           32           16.949
100              512           32           14.539
```

Use `monitor_tcp_drain.py` beside `tcp_online_driver.py` when validating drain
SLOs. It writes one JSONL sample per interval with driver progress, Kafka lag,
selected `/internal/metrics`, TCP established count, and container CPU/memory;
the summary file reports `lagClearAfterSendSeconds`.

Message send acceptance:

- `loginCacheHit=true` and no formal-run `login_start` events.
- `successes / connections >= 99.9%`.
- `ackSuccessRate >= 0.999`.
- `deliverySuccessRate >= 0.999`.
- `ackLatencyMs p95 < 300ms`, `ackLatencyMs p99 < 1000ms`.
- `deliveryLatencyMs p95 < 1000ms`, `deliveryLatencyMs p99 < 3000ms`.
- Kafka lag, outbox backlog, and projection lag do not grow without draining.
- TCP close/reconnect counters do not spike during steady state.
- Remote metrics snapshots include selected `/internal/metrics` values when
  `SSH_HOST` and `COLLECT_REMOTE_METRICS=true` are set. Use `IM_METRICS_URL`
  to override the remote endpoint and `IM_METRICS_SECRET`,
  `IM_METRICS_INTERNAL_SECRET`, or `IM_INTERNAL_SHARED_SECRET` for the
  `X-IM-Metrics-Secret` header. Override `IM_METRICS_NAMES` to sample a custom
  space-separated metric set. The default metric set includes TCP write pressure,
  local fanout, compact large-group hinting, timeline/since cache, timeline read
  latency and visibility scans, client timeline catch-up health, owner-delivery
  batch write, projection lag, and stream-consumer counters. Each ladder step
  also prints an `im metrics delta` section when `/internal/metrics` is
  reachable: counters ending in `_total` show the step delta, while gauges show
  the final value and change from the pre-step snapshot.
- Remote snapshots print service activity for `REMOTE_SERVICE_NAMES`. The
  default list includes gateway, outbox relay, generic stream-consumer, and
  split summary/domain/realtime/notification consumer service names. Missing or
  inactive services are reported but do not stop the snapshot, so Kafka lag and
  `/internal/metrics` collection still run on partially split deployments.
- Remote snapshots also describe Kafka lag for
  `KAFKA_CONSUMER_GROUPS`, defaulting to `domain-delivery-consumer`,
  `summary-projection-consumer`, `realtime-delivery-consumer`, and
  `notification-consumer`. Override `KAFKA_BOOTSTRAP_SERVER` when Kafka is not
  reachable at `127.0.0.1:9092`, and override `KAFKA_CONSUMER_GROUPS` when a
  deployment splits or renames stream-consumer groups. Override
  `KAFKA_CONSUMER_GROUPS_CMD` when `kafka-consumer-groups.sh` is installed
  somewhere other than `/opt/kafka/bin/kafka-consumer-groups.sh`, exposed on
  `PATH`, or wrapped by a container command. If the command is unavailable, the
  snapshot prints a warning and continues collecting service and `/internal/metrics`
  data. Treat realtime lag growth separately from domain/summary lag; a hot group
  can have healthy writes but still back up live delivery.
- `IM_METRICS_GATE_MODE=warn|fail|off` evaluates the same before/after metrics
  snapshot after each ladder step. Defaults are intentionally strict for
  correctness counters: client catch-up failures/deferred,
  timeline/since distributed invalidation errors, stream failed events, TCP
  write backpressure/drops, active-conversation route-drop counters,
  realtime async relay dropped dispatch/recipient counters, gateway HTTP relay
  skipped recipients/request failures/binary fallbacks/inbound failures, and
  `im_timeline_since_target_sequence_strong_misses_total` /
  `im_timeline_since_target_sequence_errors_total` /
  `im_timeline_read_visibility_scan_limit_exceeded_total` all default to max
  `0`. Targeted strong catch-up also fails when
  `im_timeline_since_target_sequence_strong_fallbacks_total` increases by at
  least `IM_GATE_TARGET_SEQUENCE_SINGLEFLIGHT_MIN_FALLBACKS` (default `10`) but
  `im_timeline_since_target_sequence_singleflight_joined_total` does not increase.
  It also fails when targeted strong fallback rate exceeds
  `IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MAX_PERCENT` (default `25`) after
  at least `IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MIN_REQUESTS` targeted
  pulls (default `20`), because strong catch-up is a bounded lag fallback, not
  the steady-state active-room read path.
  Gateway HTTP relay outbound and inbound max body gauges default to max
  `1048576` bytes so large realtime payload regressions fail release-candidate
  runs before they rely on JSON fallback or gateway body-limit errors.
  Step-level server-side `timeline/since` read latency is computed from the
  histogram delta for the current ladder step; P95 defaults to max `2000`, P99
  defaults to max `5000`, and the raw
  `im_timeline_read_latency_max_millis` gauge defaults to max `10000`. Use
  `fail` for release-candidate runs so a step exits non-zero on any violation;
  keep `warn` for exploratory tuning. In `fail` mode the script validates before
  building or opening TCP connections that `SSH_HOST`,
  `COLLECT_REMOTE_METRICS=true`, `COLLECT_IM_METRICS=true`, and
  `COLLECT_IM_METRICS_DELTA=true` are all set. A missing before/after
  `/internal/metrics` snapshot still fails the step instead of silently skipping
  the gate.
- Gate thresholds are configured with `IM_GATE_CLIENT_CATCH_UP_FAILURES_MAX`,
  `IM_GATE_CLIENT_CATCH_UP_DEFERRED_MAX`,
  `IM_GATE_TIMELINE_INVALIDATION_ERRORS_MAX`,
  `IM_GATE_STREAM_FAILED_EVENTS_MAX`,
  `IM_GATE_TCP_DROPPED_BACKPRESSURE_MAX`, `IM_GATE_TCP_BACKPRESSURE_MAX`,
  `IM_GATE_ACTIVE_FANOUT_ROUTE_SPLIT_DROPS_MAX`,
  `IM_GATE_REMOTE_ACTIVE_FANOUT_ROUTE_SPLIT_DROPS_MAX`,
  `IM_GATE_REALTIME_ASYNC_RELAY_DROPPED_DISPATCHES_MAX`,
  `IM_GATE_REALTIME_ASYNC_RELAY_DROPPED_RECIPIENT_DELIVERIES_MAX`,
  `IM_GATE_GATEWAY_HTTP_RELAY_SKIPPED_RECIPIENTS_MAX`,
  `IM_GATE_GATEWAY_HTTP_RELAY_REQUEST_FAILURES_MAX`,
  `IM_GATE_GATEWAY_HTTP_RELAY_BINARY_FALLBACKS_MAX`,
  `IM_GATE_GATEWAY_HTTP_RELAY_INBOUND_FAILURES_MAX`,
  `IM_GATE_GATEWAY_HTTP_RELAY_REQUEST_MAX_BODY_BYTES`,
  `IM_GATE_GATEWAY_HTTP_RELAY_INBOUND_MAX_BODY_BYTES`,
  `IM_GATE_TARGET_SEQUENCE_STRONG_MISSES_MAX`,
  `IM_GATE_TARGET_SEQUENCE_ERRORS_MAX`,
  `IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MAX_PERCENT`,
  `IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MIN_REQUESTS`,
  `IM_GATE_CATCH_UP_REQUEST_MAX_MS`,
  `IM_GATE_CATCH_UP_HINT_TO_APPLY_MAX_MS`,
  `IM_GATE_TIMELINE_READ_MAX_MS`,
  `IM_GATE_TIMELINE_SINCE_READ_P95_MAX_MS`,
  `IM_GATE_TIMELINE_SINCE_READ_P99_MAX_MS`,
  `IM_GATE_TIMELINE_VISIBILITY_SCAN_LIMIT_EXCEEDED_MAX`,
  `IM_GATE_TIMELINE_SINCE_NOTICE_BYPASSES_MAX`,
  `IM_GATE_TIMELINE_SINCE_VISIBILITY_NOTICE_BYPASSES_MAX`,
  `IM_GATE_OWNER_BATCH_WRITE_MAX_MS`, and
  `IM_GATE_PROJECTION_LAG_MAX_MS`.

Message fanout interpretation:

- `im_realtime_active_conversation_fanout_active_recipients_total` is the number
  of recipients who were actively viewing the conversation and received live
  message fanout.
- `im_realtime_active_conversation_fanout_inactive_hint_recipients_total` is the
  number of inactive recipients selected for lightweight conversation-list hints
  in `IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE=relay`. In production
  `pull-only` mode this should stay near zero because inactive online users use
  conversation changes and `timeline/since` catch-up instead of realtime fanout.
- `im_realtime_active_conversation_fanout_downgraded_active_recipients_total`
  is the number of active conversation viewers downgraded from full live message
  fanout to compact active realtime hints.
- `im_realtime_active_conversation_fanout_compact_active_recipients_total`
  is the subset of downgraded active viewers that received a lightweight
  `conversation_activity_hint` instead of the full `message_created` payload.
  These viewers are actively in the conversation but must use `timeline/since`
  to fetch the message body.
- `im_domain_relay_after_record_pre_split_compact_active_recipients_total`
  is the same compact-active signal on the domain-delivery relay-after-record
  path. It should rise with downgraded active viewers when owner delivery is
  skipped, while `im_domain_relay_after_record_pre_split_inactive_hint_recipients_total`
  should stay near zero in production `pull-only` mode.
- `im_realtime_active_conversation_fanout_backpressure_downgraded_active_recipients_total`
  is the subset downgraded because all local connections for that active user
  were non-writable when `IM_TCP_DROP_REALTIME_WHEN_NOT_WRITABLE=true`. These
  recipients are not converted into inactive `conversation_activity_hint`
  recipients; they recover through the normal selected-chat timeline catch-up
  or reconnect path instead of receiving a list-summary hint while active.
- `im_realtime_inactive_conversation_hint_recipients_total` shows how many hint
  recipients were actually flushed after debounce/coalescing in relay mode.
  Production `pull-only` runs should not depend on this metric for list
  freshness.
- `im_realtime_inactive_conversation_hint_suppressed_recipients_total` shows
  how many pending inactive hints were replaced before flush when relay mode is
  explicitly enabled for a local experiment.
- If active recipients dominate and TCP write latency/backpressure rises, the
  bottleneck is gateway live fanout or slow clients.
- If downgraded active recipients grow while backpressure downgrades stay flat,
  `IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT` or the payload byte budget
  is protecting full-message fanout. Compact active recipients receive a
  realtime activity hint and must catch up through `timeline/since`. If
  backpressure downgrades grow, the gateway/client network path is saturated;
  affected clients also catch up through `timeline/since`.
- If inactive hint recipients dominate in a production run, the deployment is
  not using `IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE=pull-only` everywhere.
  Fix the gateway/stream-consumer env before treating the result as a production
  capacity number.
- If `im_realtime_coalesced_*` and `im_realtime_async_relay_*` grow while
  active/inactive recipient counts are low, tune the stream-consumer relay
  dispatcher before raising message rate.

Realtime relay tuning:

- Keep `IM_REALTIME_DELIVERY_ASYNC_RELAY_ENABLED=false` for strict synchronous
  relay semantics.
- Use `IM_REALTIME_DELIVERY_ASYNC_RELAY_ENABLED=true` for realtime latency
  capacity tests. In this mode the realtime Kafka consumer commits after placing
  relay work into a bounded in-process dispatcher; durable owner delivery remains
  the catch-up source if the process exits before a best-effort live relay
  finishes.
- `IM_REALTIME_DELIVERY_ASYNC_MAX_IN_FLIGHT` caps concurrent gateway relay jobs.
  Start with `32`; if gateway CPU, relay errors, or TCP send completion latency
  spikes, lower it. If realtime Kafka lag grows while gateway has headroom, raise
  it cautiously.
- `IM_REALTIME_DELIVERY_ASYNC_MAX_QUEUED` caps relay jobs waiting for an async
  dispatcher slot. Start with `1024`; lower it if stream-consumer memory grows
  during hot-group bursts. When this queue is saturated, the server drops the
  best-effort live relay and relies on owner-delivery cursor or timeline catch-up;
  track `im_realtime_async_relay_*` metrics before increasing in-flight relay
  concurrency.
- `IM_REALTIME_REMOTE_DISPATCH_USER_BATCH_SIZE` caps the number of target users
  in one cross-node realtime packet. Start with `512`; lower it if gateway relay
  body size, Redis dispatch latency, or TCP local fanout latency spikes.
  Production gateway validation rejects values above `2048`.
- `IM_REALTIME_REMOTE_DISPATCH_MAX_IN_FLIGHT` caps concurrent cross-node dispatch
  requests from one process. Start with `8`; raise it only when remote gateway
  nodes have CPU/network headroom and dispatch queues stay flat. Production
  gateway validation requires `> 1` and rejects values above `64`.
- Metrics expose `im_realtime_remote_dispatch_config_user_batch_size` and
  `im_realtime_remote_dispatch_config_max_in_flight`; include them in every
  remote metrics snapshot so cross-node dispatch latency and body-size results
  can be interpreted against the actual runtime config.
- Use `im_cross_node_dispatch_latency_avg_millis` and
  `im_cross_node_dispatch_latency_max_millis` to separate remote gateway relay
  latency from local TCP fanout latency during multi-gateway large-group tests.
- `IM_GATEWAY_LOCAL_FANOUT_BATCH_SIZE` caps how many local TCP connections one
  fanout chunk writes to. Start with `64`; lower it if a single hot-room relay
  monopolizes gateway EventLoops. Production gateway validation rejects values
  above `1024` because one chunk is not preempted until all writes in that chunk
  have been queued.
- `IM_GATEWAY_LOCAL_FANOUT_EVENT_LOOP_YIELD_CHUNKS` caps how many local fanout
  chunks one EventLoop runner processes before rescheduling itself. Start with
  `64`; lower it if heartbeat/ACK latency rises during hot-room fanout, and
  raise it only when `im_local_fanout_event_loop_jobs_total` is high while TCP
  write latency is healthy.
- Local fanout metrics cover pre-split domain-event batches plus generic encoded
  single-packet fanout such as stream signals, so a spike in
  `im_local_fanout_event_loop_jobs_total` should be checked against packet type
  and active hot-room traffic before raising the yield or batch limits.
- Use `im_local_fanout_chunks_total` and
  `im_local_fanout_max_chunks_per_event_loop_job` with
  `im_local_fanout_event_loop_jobs_total` to tune
  `IM_GATEWAY_LOCAL_FANOUT_BATCH_SIZE` and
  `IM_GATEWAY_LOCAL_FANOUT_EVENT_LOOP_YIELD_CHUNKS`; if chunks/job stays pinned
  at the configured yield while ACK or heartbeat latency rises, lower the yield
  before increasing relay concurrency.
- `IM_TCP_WRITE_BUFFER_LOW_WATERMARK` and
  `IM_TCP_WRITE_BUFFER_HIGH_WATERMARK` configure NIO per-channel write-buffer
  watermarks on gateway TCP connections. Start with `524288` / `1048576`; lower
  them if slow clients retain too much memory, and raise them only when
  `im_local_fanout_*` metrics show gateway fanout is healthy but brief network
  bursts trigger unnecessary writability churn.
- `IM_TCP_DROP_REALTIME_WHEN_NOT_WRITABLE=true` drops best-effort realtime
  domain-event fanout for a connection that is already non-writable. ACK/kick
  control packets still use the normal write path. Keep this enabled for
  large-group tests so slow clients catch up through owner cursor or
  `timeline/since` instead of retaining unbounded gateway buffers.
- `im_tcp_write_completions_total`, `im_tcp_write_failures_total`,
  `im_tcp_write_backpressure_total`,
  `im_tcp_write_dropped_backpressure_total`, and
  `im_tcp_write_latency_*_millis` show whether fanout work is reaching the socket
  layer cleanly. Treat rising backpressure or write latency during steady load as
  a gateway/client-network bottleneck before increasing realtime relay
  concurrency.
- `IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD` enables a
  large-conversation realtime optimization for `message_created`. When the
  recipient count is greater than or equal to the threshold, realtime relay sends
  a lightweight hint for non-full-fanout recipients while owner delivery or
  timeline reads remain the catch-up source for the message body. Inactive or
  list-only recipients receive `conversation_activity_hint`; production active
  chat viewers downgraded from full fanout also receive a bounded
  `conversation_activity_hint` message-lite payload. Start with `500` for
  production hot-group testing and keep it aligned with the summary
  activity-only and owner-delivery skip thresholds.
- `IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_PREVIEW_MAX_CHARS` caps the preview
  text used in inactive `conversation_activity_hint` payloads; the default is
  `120`.
- `IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS` must be `1...120` so
  active chat viewers can render a new hot-room message from the realtime hint
  while still reconciling through `timeline/since`.
- `IM_REALTIME_MESSAGE_CREATED_PREVIEW_LOOKUP_ENABLED=false` is the production
  setting for hot large-group realtime. New `message_created` events must carry
  an embedded preview, so the realtime consumer can build inactive conversation
  hints without reading the message row on the hot path. Track
  `im_domain_event_message_created_preview_embedded_total`,
  `im_domain_event_message_created_preview_message_lookup_total`, and
  `im_domain_event_message_created_preview_missing_total`; production hot-group
  tests should show embedded previews growing, message lookups staying flat, and
  missing previews at zero.
- When active-conversation route lookup or pre-split fanout fails, the system
  drops the best-effort realtime fanout. It does not fall back to full unsplit
  group fanout and does not convert active-chat delivery into inactive
  `conversation_activity_hint` semantics. Track
  `im_realtime_active_conversation_fanout_route_split_drops_total`,
  `im_realtime_active_conversation_fanout_route_split_drop_recipients_total`,
  `im_realtime_remote_active_conversation_fanout_route_split_drops_total`, and
  `im_realtime_remote_active_conversation_fanout_route_split_drop_recipients_total`.
- `IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS` coalesces large
  `message_created` inactive-list hints by conversation when relay mode is
  explicitly enabled. Production active chat viewers should use a short
  active compact window, for example
  `IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS=100`, so hot rooms collapse
  repeated compact hints by recipient while keeping visible-message catch-up
  freshness bounded well below one second. Inactive online users are not realtime-fanout targets
  in production `pull-only` mode; they use conversation changes and
  `timeline/since` catch-up. This is the production path for hot large groups,
  not a per-message delivery guarantee. Track `im_realtime_coalesced_*` metrics
  to see how much hint fanout pressure is being collapsed. Domain-delivery
  `IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true` follows the same split: active
  compact hints use the active compact window, inactive hints use the inactive
  coalescing window.
- `IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED=true` is required on
  production gateways. It splits active chat viewers from inactive online users;
  production `compact-only` plus `pull-only` keeps realtime delivery focused on
  active viewers, while inactive recipients advance conversation-list state via
  changes/timeline pull. This prevents a hot large group from forcing every idle
  client to receive every realtime message or list hint.
- `IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD` controls when the
  active/inactive split starts. Keep it aligned with the large-group threshold
  used by owner-delivery skip and lightweight realtime payloads; start with
  `500` for production gateway tests.
- `IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT` caps how many active
  viewers of one conversation receive full live `message_created` fanout from a
  gateway split. The default `0` is only for local smoke checks.
  Production validation requires a value above `0`, less than or equal to
  `IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD`, and no higher
  than the hard cap `128`. For production hot-room tests, start with `128`;
  lower it if TCP write latency or backpressure grows. Overflow writable active
  viewers receive the configured active compact hint; production uses bounded
  `conversation_activity_hint` message-lite payloads. Inactive or non-writable viewers rely on timeline catch-up instead of
  realtime hint fanout in production `pull-only` mode. Do not raise this above
  `128` in a production load test; use a local/experimental branch if you need
  to compare unsafe upper bounds.
- `IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_MODE=compact-only` is the
  production large-group mode. In this mode even active chat viewers receive a
  bounded active compact hint and use `timeline/since` to reconcile the
  message body. Keep `bounded` only for local A/B tests that intentionally
  measure limited full realtime fanout; production validation rejects bounded
  mode because it makes hot-room capacity depend on full-message socket fanout.
- `IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_PAYLOAD_BYTE_BUDGET` caps the
  estimated full-payload bytes sent per hot-conversation message before fanout
  replication. When a message payload is large, the effective full fanout limit
  becomes `min(IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT,
  budget / encoded_payload_bytes)` and remaining writable active viewers receive
  compact-active message-lite hints. Inactive or non-writable viewers use
  timeline/since catch-up instead of realtime hint fanout in production
  `pull-only` mode. Start with `262144` and keep it at least `65536` in
  production; set `0` only for local A/B comparison. Track
  `im_realtime_active_conversation_fanout_payload_budget_applied_total`,
  `im_realtime_active_conversation_fanout_payload_budget_downgraded_active_recipients_total`,
  `im_realtime_active_conversation_fanout_payload_budget_max_payload_bytes`, and
  `im_realtime_active_conversation_fanout_payload_budget_max_effective_limit`
  together with `im_realtime_active_conversation_fanout_compact_active_recipients_total`
  to see whether large payloads, rather than active-room size alone, are moving
  users from full to compact realtime.
- `IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE=pull-only` is the production
  setting. It disables realtime fanout to inactive online users for hot groups;
  clients use conversation changes and `timeline/since` catch-up for list and
  message freshness. Keep `relay` only for local A/B experiments.
- `IM_REALTIME_INACTIVE_CONVERSATION_HINT_DEBOUNCE_SECONDS` only matters when
  `IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE=relay`. Production `pull-only`
  deployments should not tune this to improve hot-group list freshness.
- `IM_TIMELINE_SINCE_HOT_CACHE_TTL_MS` protects query-api from synchronized
	  `timeline/since` pulls after lightweight large-group hints. It is a short
	  in-process cache keyed by conversation, lower timeline bound, visible sequence
	  floor, and limit; it only serves pages that are safe to share, and bypasses
	  cache when notices or user-hidden messages require exact per-user visibility.
	  Start with `250`, keep production between `50` and `5000`, keep it below the
	  iOS selected-hint catch-up throttle, and
	  track `im_timeline_since_hot_cache_hits_total`,
	  `im_timeline_since_hot_cache_misses_total`, and
	  `im_timeline_since_hot_cache_unsafe_bypasses_total` during 1000-user hot-group
	  tests. When targeted catch-up uses `targetSequence`, also track
	  `im_timeline_since_hot_cache_target_sequence_bypasses_total`; a high value
	  means the exact hot-cache entry exists but is older than the hinted sequence,
	  so the request correctly falls through to shared strong catch-up instead of
	  returning a stale page.
- `IM_TIMELINE_SINCE_RECENT_CACHE_TTL_MS` adds a short per-conversation recent
  page cache for adjacent safe `timeline/since` cursors. The exact hot cache
  only helps when clients request the same `afterSequence`; the recent cache lets
  nearby cursors reuse the latest safe page suffix after compact large-group
  hints. It is checked only after the same shared-read safety gate as the hot
  cache, never serves pages containing notices, and is invalidated by the same
  local or Redis-distributed conversation invalidations. Start with `2000` and
  keep production between `1000` and `30000`.
- `IM_TIMELINE_SINCE_RECENT_CACHE_MAX_CONVERSATIONS` bounds the number of
  conversation/visible-floor recent entries kept by each query-api process. Start
  with `1024`; production must keep at least `512`, and should raise only when
  hot-group tests show useful hit rate but eviction pressure.
- `IM_TIMELINE_SINCE_RECENT_CACHE_MAX_ITEMS_PER_CONVERSATION` caps the cached
  latest timeline items per entry. Start with `512`; production must keep at
  least `128`, lower it if query-api memory grows during many concurrent hot
  conversations, and raise it only when
  `im_timeline_since_recent_cache_misses_total` stays high because client cursors
  are spread across a wider recent window.
- Track `im_timeline_since_recent_cache_hits_total`,
  `im_timeline_since_recent_cache_misses_total`,
  `im_timeline_since_recent_cache_target_sequence_bypasses_total`,
  `im_timeline_since_recent_cache_stores_total`,
  `im_timeline_since_recent_cache_invalidations_total`, and
  `im_timeline_since_recent_cache_invalidated_entries_total` together with the
  exact hot-cache counters. In a healthy 1000-user hot-group compact-hint run,
  recent-cache hits should rise when clients catch up from slightly different
  local cursors; zero hits means synchronized pulls are either already exact-key
  hits or still falling through to DB. A high target-sequence bypass count means
  the cached recent suffix does not extend far enough to the hinted sequence;
  raise `IM_TIMELINE_SINCE_RECENT_CACHE_MAX_ITEMS_PER_CONVERSATION` only if query
  memory and invalidation rates remain safe.
- Targeted `timeline/since` catch-up requests from realtime lightweight hints include
  `targetSequence`. Query-api passes that target through the eventual read path
  first, so target-aware hot/recent cache checks, target-sequence singleflight,
  and the short target-sequence coalescing window can satisfy active-viewer pulls
  before any strong read is attempted. Cached pages are used only when their
  latest timeline sequence reaches `targetSequence`; stale entries are counted as
  target-sequence bypasses and do not satisfy the request. If the eventual
  response still does not reach the target, query-api retries against the strong
  timeline source through the same target-aware shared path. This prevents a
  stale empty hot cache entry or replica lag from turning a delivered hint into a
  visible `target_not_reached` delay while still collapsing synchronized catch-up
  from many active viewers. Untargeted history/gap reads keep the normal
  eventual-read hot-cache path.
- `IM_TIMELINE_SINCE_HOT_CACHE_MAX_ENTRIES` bounds that query-api process cache.
	  Start with `4096`; raise it only when hit rate is low because many hot
	  conversations or cursor windows are active at once.
- iOS selected-conversation lightweight hints are micro-batched for a short
  window before issuing `timeline/since`; adjacent hints keep only the latest
  target timeline sequence. This keeps active viewers close to realtime while
  reducing synchronized hot-room pull amplification. During hot-group tests,
  track `im_client_timeline_catch_up_hint_queued_total`,
  `im_client_timeline_catch_up_since_requests_total`,
  `im_client_timeline_catch_up_since_successes_total`,
  `im_client_timeline_catch_up_since_failures_total`,
  `im_client_timeline_catch_up_deferred_total`,
  `im_client_timeline_catch_up_applied_items_total`,
  `im_client_timeline_catch_up_hint_to_request_max_millis`,
  `im_client_timeline_catch_up_hint_to_request_avg_millis`,
  `im_client_timeline_catch_up_request_max_millis`,
  `im_client_timeline_catch_up_request_avg_millis`,
  `im_client_timeline_catch_up_hint_to_apply_max_millis`, and
  `im_client_timeline_catch_up_hint_to_apply_avg_millis`. Avg gauges show the
  current reporting-client trend; max gauges catch individual client spikes. A high
  hint-to-request max points at client-side batching/rate-limit pressure; a high
  request max with healthy hint-to-request points at query-api/timeline read
  pressure; a high hint-to-apply max with low request max points at local client
  merge or UI-store pressure. Normal client-health reports remain rate-limited,
  but timeline catch-up `deferred`, `incomplete`, `failed`, and slow catch-up
  paths bypass the normal 60s interval with their own short cooldown so hot-room
  tests surface bad catch-up behavior quickly without flooding the health
  endpoint.
- iOS selected-conversation catch-up tuning can be overridden per build/run with
  `IM_SELECTED_HINT_CATCH_UP_INITIAL_JITTER_MS`,
  `IM_SELECTED_HINT_CATCH_UP_MIN_INTERVAL_MS`, and
  `IM_SELECTED_HINT_CATCH_UP_MICRO_BATCH_MS` through the process environment or
  matching `UserDefaults` keys. Explicit `0` is accepted for jitter; interval and
  micro-batch values are clamped to the client's minimum safe delay. The client
  includes the effective values in health reports; metrics expose
  `im_client_timeline_catch_up_config_selected_hint_initial_jitter_*_millis`,
  `im_client_timeline_catch_up_config_selected_hint_min_interval_*_millis`, and
  `im_client_timeline_catch_up_config_selected_hint_micro_batch_*_millis`.
  Always compare hint-to-request latency against these config gauges before
  treating slow selected-chat catch-up as a server-side timeline read issue.
- `IM_TIMELINE_SINCE_CACHE_INVALIDATION_MODE=redis` is required in production when
  any shared `timeline/since` cache is enabled. Command/stream nodes publish conversation invalidations
  after message and timeline-notice writes; query nodes subscribe and clear local
  hot cache, visibility-safety cache, and in-flight `timeline/since` singleflight
  work. Track `im_timeline_since_distributed_invalidations_published_total`,
  `im_timeline_since_distributed_invalidations_received_total`, and
  `im_timeline_since_distributed_invalidation_errors_total`. Any non-zero error
  count during hot-group tests means cache TTL must stay very short until Redis
  pub/sub connectivity is fixed.
- `IM_REDIS_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_SECONDS` controls the short
  in-process Redis presence cache used for active conversation user-set snapshots
  and per-user active route lookups. Cold misses use Redis-side membership
  probes against the conversation-node active user indexes, so the gateway only
  receives matched routes instead of full active-user sets for each node. Start
  with `2`; lower it if active-chat presence changes must be reflected faster,
  and raise it only when
  `im_redis_presence_active_conversation_node_index_*` metrics show hot groups
  are still repeatedly probing Redis node indexes.
- `IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_MS` controls the
  stream-consumer hot-conversation route cache. In production
  `IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE=pull-only`, it stores a short-lived
  active-room route snapshot for the conversation, so adjacent `message_created`
  relays query Redis by active viewers instead of probing every group member. In
  relay-hint comparison mode, it falls back to the per-recipient route cache,
  including negative inactive results, because inactive hint fanout still needs
  recipient-level routing. A 1000-member group at 5-10 msg/s should therefore
  avoid rebuilding the same active-room route query for every message even when
  recipient windows differ slightly. Start with `1000`; set `0` only for A/B
  comparison tests. Track
  `im_realtime_active_conversation_route_cache_hits_total`,
  `im_realtime_active_conversation_route_cache_partial_hits_total`,
  `im_realtime_active_conversation_route_cache_missed_users_total`,
  `im_realtime_active_conversation_route_cache_joined_in_flight_total`, and the
  matching domain relay-after-record route cache metrics together with Redis
  presence metrics to separate stream-consumer cache misses from Redis cache
  misses. A rising joined-in-flight counter means concurrent hot-group route
  misses were collapsed behind one Redis lookup instead of stampeding Redis.
- `IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_MAX_ENTRIES` bounds that
  stream-consumer cache. Each entry contains a conversation ID plus one cached
  user route result, including negative inactive results, so leaving it
  unbounded is unsafe for production hot-group tests with many active
  conversations or large recipient windows. Start with `4096`;
  lower it if stream-consumer memory grows, and raise it only when the hit ratio
  is low while memory remains flat.
- `IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD`
  makes `summary-projection-consumer` update a shared conversation activity row
  instead of writing one per-owner summary/change-log row for every large-group
  message. Production `summary-projection-consumer` deployments must set this
  above `0`; start with `500`. For omitted-recipient `message_created` events,
  the projection consumer uses the event snapshot's `recipient_count` hint to
  choose this path, so hot large-group summary projection does not need to decode
  the full shared recipient JSON before writing `ConversationActivitySummary`.
- `IM_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS` coalesces hot large-group
  `ConversationActivitySummary` writes by conversation. Within the window, only
  the latest activity row is written, while clients still use timeline/cursor
  catch-up for exact message history. Start with `500`; production must keep it
  between `50` and `1000`, lower it if conversation list freshness needs tighter
  bounds, and track
  `im_domain_event_summary_activity_coalesced_*` to confirm write pressure is
  actually collapsing.
- `IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT` caps summary/list/change response
  and realtime conversation summary member ID payloads. When `member_count` is
  greater than this value, summary responses keep the true `member_count` but
  return an empty `memberUserIDs` array, and clients must use the paged members
  API for member details. Start with `500` so 1000+ member group list/change
  reads and membership/settings realtime payloads do not repeatedly transfer or
  decode full member JSON.
- Track `im_realtime_payload_summary_member_ids_omitted_total` and
  `im_realtime_payload_summary_member_ids_omitted_members_total` during large
  membership/settings realtime tests. They should increase for 1000+ member
  groups; if `im_realtime_payload_summary_member_ids_emitted_members_total`
  grows at the same rate, realtime summaries are still carrying full member ID
  arrays.
- `IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD` keeps small-group
  `message_created` outbox events self-contained, but omits the full
  `recipientUserIDs` list at or above the threshold. Consumers expand large
  message-created recipients from the conversation membership read path, so
  Kafka/outbox payload size no longer grows linearly with large-group member
  count. Production command-api deployments must set this above `0`; keep it
  aligned with the other large-group thresholds and start with `500`.
- `IM_DOMAIN_EVENT_RECIPIENT_SNAPSHOT_DEDUP_THRESHOLD` stores large omitted
  recipient snapshots once per unique recipient hash, then lets per-event
  snapshot rows reference that shared set. Shared recipient sets also maintain a
  `conversation_domain_event_recipient_set_members` index; production
  `pull-only` realtime delivery uses that index to filter current active viewers
  without decoding the full UUID JSON for every hot-group message. Production
  command-api deployments must set this above `0` and no higher than
  `IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD`; start with `500`. This keeps
  hot 1000/2000 member groups from writing or decoding the same UUID list for
  every message.
- `IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE=timeline-pull` is the
  production large-group delivery model. At or above
  `IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD`,
  `domain-delivery-consumer` does not write durable per-owner `message_created`
  copies; offline and gap catch-up come from the conversation timeline
  (`timeline/since`) instead of one owner-delivery protobuf per member per
  message. Keep `owner-delivery` plus threshold `0` only for small-group/full
  owner-delivery validation.
- `IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD`
  is the recipient count where `timeline-pull` starts. The iOS client treats
  active `conversation_activity_hint` events for the currently opened conversation
  as a `timeline/since` catch-up trigger, so active viewers can recover the real
  message body even when they receive a lightweight hint instead of an owner
  cursor event. Inactive users use conversation changes and `timeline/since`
  instead of realtime message fanout. The server timeline reader must scan past hidden or cleared
  candidate rows before deciding there are no visible items; otherwise large-group
  hint catch-up can stop on an empty filtered page. Start with `500`.
- `IM_TIMELINE_READ_VISIBILITY_SCAN_MAX_ROWS` and
  `IM_TIMELINE_READ_VISIBILITY_SCAN_MAX_PAGES` cap how far `timeline` and
  `timeline/since` scan through hidden or cleared candidate rows while searching
  for visible items. Start with `5000` rows and `50` pages on production
  command/query API nodes. The production schema validator requires
  `im_messages_conversation_timeline_server_sequence_idx` so these scans can use
  the conversation timeline cursor while checking the message server-sequence
  visibility floor. During hot-group tests, watch
  `im_timeline_read_visibility_scan_rows_total`,
  `im_timeline_read_visibility_scan_max_rows`,
  `im_timeline_read_visibility_scan_pages_total`,
  `im_timeline_read_visibility_scan_max_pages`, and
  `im_timeline_read_visibility_scan_limit_exceeded_total`. Any non-zero scan
  limit count means clients are protected from a misleading empty catch-up
  response, but the read path needs either a higher budget, better visibility
  indexes, or product cleanup of extreme hidden-message histories.
- `im_timeline_read_latency_millis_bucket{kind="since",...}` is the primary
  server-side tail-latency signal for large-group hint catch-up. Use
  `histogram_quantile(0.95, rate(im_timeline_read_latency_millis_bucket{kind="since"}[5m]))`
  and the matching P99 query to separate query-api/timeline read pressure from
  client-side hint batching or UI merge delays. The ladder scripts collect the
  histogram bucket/count/sum samples by default, print a step-level
  `timeline read latency summary`, and can gate the current step with
  `IM_GATE_TIMELINE_SINCE_READ_P95_MAX_MS` and
  `IM_GATE_TIMELINE_SINCE_READ_P99_MAX_MS`.
- Targeted `timeline/since` catch-up also reports
  `im_timeline_since_target_sequence_requests_total`,
  `im_timeline_since_target_sequence_eventual_satisfied_total`,
  `im_timeline_since_target_sequence_strong_fallbacks_total`,
  `im_timeline_since_target_sequence_strong_satisfied_total`, and
  `im_timeline_since_target_sequence_strong_misses_total`, and
  `im_timeline_since_target_sequence_errors_total`. Pair these with
  `im_timeline_since_hot_cache_target_sequence_bypasses_total`,
  `im_timeline_since_recent_cache_target_sequence_bypasses_total`, and
  `im_timeline_since_target_sequence_singleflight_joined_total`. The companion
  `im_timeline_since_target_sequence_window_joined_total` isolates the short
  target-sequence coalescing window that can merge active-viewer pulls even when
  their `afterSequence` cursors differ slightly. In a healthy active compact-hint
  run where the eventual read model keeps up, eventual-satisfied should rise and
  strong fallback should not grow linearly with active viewers. A high fallback
  rate with high
  target-sequence singleflight joins means the target-aware shared catch-up is
  absorbing synchronized active-viewer pulls. A high fallback rate with low
  target-sequence singleflight joins means clients are too spread out by cursor,
  limit, visible floor, target sequence, or query-api process locality to
  coalesce. A non-zero strong miss count means the strong timeline source also
  did not reach the hinted sequence, while
  target-sequence errors mean the targeted catch-up request failed before it
  could prove convergence. Investigate command write, sequence allocation, hint
  payload correctness, and query-api health before tuning caches.
  `im_timeline_since_visibility_notice_bypasses_total` and
  `im_timeline_since_response_singleflight_notice_bypasses_total` protect
  user-specific timeline notices from being shared through cached or in-flight
  catch-up. They should stay near zero in pure large-group message tests; high
  values mean the run includes membership/notice traffic and should not be used
  as a clean hot-message read-path benchmark.
  `IM_GATE_TIMELINE_SINCE_VISIBILITY_NOTICE_BYPASSES_MAX` and
  `IM_GATE_TIMELINE_SINCE_NOTICE_BYPASSES_MAX` default to `0` in fail mode for
  this reason.
  `IM_TIMELINE_SINCE_TARGET_SEQUENCE_COALESCE_WINDOW_MS` controls that short
  merge window; start with `5`, and only raise it after confirming P95/P99
  `timeline/since` latency still meets the gate.
  The ladder prints a `target-sequence catch-up summary` for each step. In
  `IM_METRICS_GATE_MODE=fail`, when strong fallbacks reach
	  `IM_GATE_TARGET_SEQUENCE_SINGLEFLIGHT_MIN_FALLBACKS` and
	  `im_timeline_since_target_sequence_singleflight_joined_total` does not
	  increase, the step fails because targeted strong catch-up is not coalescing.
	  The same fail-mode gate rejects a high targeted strong fallback rate through
	  `IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MAX_PERCENT` once
	  `IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MIN_REQUESTS` has been
	  reached. Raise that threshold only for a measured read-model lag experiment,
	  not for a production capacity claim.
- `IM_DOMAIN_DELIVERY_OWNER_RECORD_BATCH_MAX_REQUESTS` caps each Postgres owner
  delivery write/sequence allocation statement. The default is `1000`, which
  keeps 5000/10000 member runs from producing oversized single SQL statements
  while preserving per-owner cursor semantics. Production validation rejects
  values below `100` or above `5000`; keep the default unless database metrics
  show that larger chunks are safe. Track
  `im_domain_event_owner_delivery_batch_write_chunked_total` and
  `im_domain_event_owner_delivery_batch_write_chunks_total` during hot-group
  tests to confirm large owner-delivery writes are being split as expected.
  `im_domain_event_owner_delivery_batch_write_materialized_fast_paths_total`
  shows how often Postgres batch writes reused the rows already materialized for
  insert and avoided a follow-up owner-delivery row refetch.
- `IM_STREAM_CONSUMER_BATCH_FILL_WAIT_MS` gives the Kafka consumer a short
  in-process queue fill window after the first message in a processing batch.
  This helps adjacent same-partition `message_created` events enter the same
  run so summary/domain/realtime consumers can coalesce hot-conversation work.
  Start with `10`; production validation requires `1...100`, and values near
  the upper bound should be treated as a latency tradeoff, not a free throughput
  gain.
- The wait window is only applied when the first queued event is a valid
  `message_created` event with a message ID. Other event types bypass the wait
  and increment `im_stream_batch_fill_skipped_batches_total`, so membership,
  read-state, malformed, or dead-letter-bound events do not pay avoidable
  batch-fill latency. The consumer checks the Kafka `event-type` header before
  decoding the JSON payload; keep that header on custom producers so non-message
  events can skip batch-fill with minimal CPU overhead.
- This optimization assumes conversation events are produced to Kafka with the
  conversation ID as the message key, so one hot conversation remains partition
  ordered. The server has a regression test for this invariant; if a custom
  producer is introduced, keep the same keying strategy.
- Watch `im_stream_processing_batches_total`,
  `im_stream_processing_batch_events_total`,
  `im_stream_processing_batch_events_avg`,
  `im_stream_message_created_run_events_total`,
  `im_stream_message_created_run_events_avg`,
  `im_stream_batch_fill_waits_total`, and
  `im_stream_batch_fill_events_total` per `consumer_group` after changing the
  batch-fill wait. A healthy hot-conversation run should show processing batch
  events above `1`, message-created run events above `1`, and non-zero fill
  events without a matching increase in `im_stream_run_event_lag_*` or Kafka
  lag. Prefer the message-created run metrics over generic run averages when
  judging hot-group fanout, because non-message events can legitimately remain
  single-event runs. If fill waits rise but fill events stay near zero, the wait
  window is not helping; check Kafka partitioning, producer ordering, or lower
  the wait to reduce added latency.
- `tcp_capacity_ladder.sh` prints a `stream batch-fill summary` after each step
  when remote `/internal/metrics` snapshots are available. Treat
  `batchFillEffect=useful` as evidence that the wait window is improving
  `message_created` run coalescing, not merely generic queue batching. Treat
  `batchFillEffect=none` or `weak` as a signal to avoid raising
  `IM_STREAM_CONSUMER_BATCH_FILL_WAIT_MS` blindly; first verify that
  hot-conversation messages are landing on the same Kafka partition and arriving
  contiguously enough for the consumer to coalesce them. `generic-useful` means
  the queue batch got larger but no `message_created` run evidence was observed,
  so it should not be used as proof that hot-group fanout improved.

Use `MESSAGES`, `DEVICES_PER_USER`, `SEND_INTERVAL_MS`, `TIMEOUT_SECONDS`, and
`COOLDOWN_SECONDS` to tune each step. Set `MESSAGES=0` plus `HOLD_SECONDS` for
idle online capacity. Set `MESSAGES=1` or higher for a hot-conversation fanout
test; that is intentionally heavier and should not be interpreted as idle online
user capacity. Set `MESSAGE_COMPLETION_MODE=ack-only` when validating large-group
coalesced realtime mode; that mode measures send acknowledgement and observed
fanout without requiring every message to be pushed live to every receiver. When
`MESSAGES=0` and `DEVICES_PER_USER` is unset, the helper uses
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
For official online-capacity numbers, use cached tokens and `LOGIN_MODE=upfront`.
On larger load generators, `PREWARM_LOGIN_CACHE=true` is acceptable. On small
servers, prefer `prewarm_login_cache_slow.sh` followed by
`PREWARM_LOGIN_CACHE=false` and `REQUIRE_LOGIN_CACHE=true`. Reserve
`LOGIN_MODE=just-in-time` for combined login+TCP experiments.
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
`PROTOCOL_VERSION` defaults to the value in
`Protocol/im_realtime/v1/protocol_version.txt`. Override it only for a protocol
development smoke test. Run it from a load generator, not from the IMServer host.

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

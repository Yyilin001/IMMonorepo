# Multi-Node Fault Validation

This is the fault-validation boundary for the IM runtime. It separates behavior
that can be proved locally from behavior that requires independently running
roles and real Redis/Kafka/PostgreSQL infrastructure. A local pass is a code
contract, never proof of multi-node availability or capacity.

## Non-Negotiable Invariants

- The command write and its outbox record are durable before any best-effort
  realtime hint is attempted.
- Redis routing or cross-node relay failure may suppress realtime delivery; it
  must not create an unbounded fallback fanout or discard durable history.
- The recovery path is authenticated summary refresh plus `timeline/since`.
- Replayed stream records and retried client message IDs remain idempotent.
- Only `ops` may run schema migration. Serving and consumer roles only validate
  schema at startup.

## Local Contract Gates

Run these without a remote server. They use the test database/fakes and prove
that the failure policy is preserved by code. The wrapper below executes the
whole local contract set in one test process, writes a combined log and a
per-contract summary, and does not start a runtime or connect to a remote host.

```bash
cd IMServer/LoadTests
./run_local_multinode_fault_contracts.sh check
./run_local_multinode_fault_contracts.sh run
```

Artifacts are written to
`IMServer/LoadTests/results/local-multinode-fault-contracts/<run-id>/`; this
directory is ignored by Git. The runner covers Redis startup/routing failures,
Cell ingress role selection and malformed-map startup rejection, durable outbox
claim/recovery, duplicate client retries, replay idempotency for projections
and owner delivery, plus cross-Cell same-shard-name validation, idempotent
remote transfer-page import, and copy/verify behavior that preserves the active
source route before cutover. It also gates the Cross-Cell realtime handoff
contract: source persistence before target acceptance, target failure retained
for retry, recovery after the target returns, replay de-duplication, and an
HTTP Gateway relay returning failure when it cannot durably record the handoff.

The individual commands remain useful when diagnosing one boundary:

```bash
cd IMServer
swift test --package-path . --filter IMServerTests.productionRequiresRedisRouting
swift test --package-path . --filter IMServerTests.productionNonOpsRolesCannotEnableStartupAutoMigration
swift test --package-path . --filter IMServerTests.connectionRoutingDropsRemoteRealtimeFanoutWhenActiveRouteLookupFailsClosed
swift test --package-path . --filter IMServerTests.realtimeDeliveryRetriesStreamEventWhenRouteSplitFails
swift test --package-path . --filter IMServerTests.domainRelayAfterRecordRetriesStreamEventWhenRouteSplitFails
swift test --package-path . --filter IMServerTests.cellIngressConfigurationSelectsPurposeEndpoints
swift test --package-path . --filter IMServerTests.productionRuntimeRejectsMalformedCellIngressEndpointConfiguration
swift test --package-path . --filter IMServerTests.conversationOutboxRelayMarksPublishedEvents
swift test --package-path . --filter IMServerTests.conversationOutboxRelayRecoversTimedOutClaims
swift test --package-path . --filter IMServerTests.tcpMessagePersistenceIsIdempotentByClientMessageID
swift test --package-path . --filter IMServerTests.messageCreatedProjectionUsesEventMessageForLargeGroups
swift test --package-path . --filter IMServerTests.messageCreatedRunOwnerDeliveryPreservesPerOwnerEventOrder
```

## Local Valkey Cluster Smoke

The ordinary production smoke stack uses standalone Redis for a fast baseline.
The Cluster smoke overlay starts three Valkey primaries, creates all slots, and
sets the runtime to `IM_REDIS_DEPLOYMENT_TOPOLOGY=cluster` with HTTP node
dispatch. Its `run` command also enables bounded, 100% sampled delivery traces
for this disposable environment and verifies the realtime-consumer relay trace
contains a correlation ID and no message body, `payload`, `content`, or raw
`error` field. It exercises the same command, outbox, Kafka, projection, and
timeline/since flow against the Cluster transport.

```bash
cd IMServer
./scripts/cluster_smoke.sh self-test
./scripts/cluster_smoke.sh run
./scripts/cluster_smoke.sh failure-drill redis-outage
./scripts/cluster_smoke.sh down
```

This is an integration smoke, not capacity evidence: it has one Gateway and
one process per consumer group. The smoke traffic does not authenticate a TCP
recipient, so it validates the realtime-consumer trace stage but does not
prove a Gateway recipient-delivery trace. The isolated-environment drills
below remain mandatory before claiming multi-Gateway or multi-Cell
availability.

On a macOS host with Swift installed, add
`IM_CLUSTER_SMOKE_REQUIRE_GATEWAY_TCP_RELAY=true` to the `run` command to run
the existing two-account TCP driver against the created direct conversation.
This verifies that the receiving TCP client gets the sender's message, then
requires the Gateway's sampled payload-delivery trace with the same
payload-safety rules. The option remains disabled by default because the
driver uses Apple's `Network` framework and cannot run on a generic Linux
Docker host.

The relevant tests intentionally prove different boundaries:

| Failure class | Local contract | Expected result |
| --- | --- | --- |
| Redis absent in production | `productionRequiresRedisRouting` | Startup rejects local routing. |
| Redis route lookup fails during delivery | `connectionRoutingDropsRemoteRealtimeFanoutWhenActiveRouteLookupFailsClosed` | No remote realtime packet; route-drop counters increase. |
| Active route split fails in consumer | `realtimeDeliveryRetriesStreamEventWhenRouteSplitFails` | The stream record remains retryable; no unbounded fallback fanout is fabricated. |
| Cell ingress role selection | `cellIngressConfigurationSelectsPurposeEndpoints` | Command, query, and realtime forwarding select independent endpoints with a legacy fallback only. |
| Malformed Cell ingress map | `productionRuntimeRejectsMalformedCellIngressEndpointConfiguration` | Production startup rejects the exact malformed environment entry. |
| Duplicate client retry | `tcpMessagePersistenceIsIdempotentByClientMessageID` | One canonical timeline message. |
| Outbox retry | `conversationOutboxRelayMarksPublishedEvents` | An event is published once after durable claim state changes. |
| Active route split fails in domain relay | `domainRelayAfterRecordRetriesStreamEventWhenRouteSplitFails` | The stream record remains retryable when the relay cannot construct a safe route split. |
| Timed-out outbox claim | `conversationOutboxRelayRecoversTimedOutClaims` | A claim left by a stopped relay becomes retryable. |
| Cross-Cell target unavailable | `crossCellRealtimeOutboxRetainsFailedDeliveryForRetry` | The source Cell keeps a pending durable handoff instead of acknowledging a transient target failure. |
| Cross-Cell target recovery | `crossCellRealtimeOutboxDeliversRetainedDispatchAfterTargetRecovery` | The retained handoff is delivered after the target ingress accepts requests again. |
| Cross-Cell source replay | `crossCellRealtimeOutboxDeduplicatesReplayedSourceHandoff` | Replayed source events reuse one outbox row and do not issue another initial delivery. |
| Reliable HTTP Gateway relay | `reliableGatewayRelayReturnsFailureWhenCellHandoffCannotBeRecorded` | The caller cannot acknowledge a Kafka record when the Gateway failed to persist a cross-Cell handoff. |
| Stream consumer replay | `messageCreatedProjectionUsesEventMessageForLargeGroups` | Summary and change-log projections remain one row per member. |
| Owner-delivery replay | `messageCreatedRunOwnerDeliveryPreservesPerOwnerEventOrder` | Owner cursors and aggregate sequence stay deduplicated and ordered. |
| Invalid role migration | `productionNonOpsRolesCannotEnableStartupAutoMigration` | Serving role startup is rejected. |

## Two-Cell HTTP Smoke

The following disposable Docker overlay starts the ordinary Cell A role set,
an independent Cell B gateway, command API, and query API, and a separate
PostgreSQL conversation shard for Cell B. The primary/control database remains
shared. It creates a direct conversation on Cell A, writes a source message,
waits until its outbox work is complete, then runs source-Cell
`prepare -> copy -> verify -> cutover` into Cell B. It finally writes and reads
through Cell A so both requests must be forwarded using the newly cut-over
directory route. The source command and query APIs must each report a
remote-Cell forwarding success metric.

It requires Docker Compose v2.24.4 or later because the overlay uses Compose's
`!override` tag to replace inherited host port mappings for Cell B.

```bash
cd IMServer
./scripts/multicell_smoke.sh self-test
./scripts/multicell_smoke.sh run
./scripts/multicell_smoke.sh down
```

On a macOS load-generator host, run the same smoke with
`IM_MULTICELL_SMOKE_REQUIRE_GATEWAY_TCP_RELAY=true` to require a peer connected
to Cell A's TCP Gateway to receive a message routed through Cell A and persisted
by the migrated Cell B. This records the receiver's TCPDriver JSONL event log
and proves Cell B to Cell A recipient delivery, not merely HTTP forwarding.

The overlay deliberately shares Kafka/Redis and the primary control database,
but it does **not** share the conversation shard database: Cell B's `shard-0`
is a distinct PostgreSQL instance. It proves role-specific command/query
ingress selection, route-version-protected HTTP forwarding, remote canonical
page import, target fingerprint verification, target search-index finalization,
and the directory cutover. The optional macOS TCP gate additionally proves
cross-Cell recipient delivery after that cutover. The overlay also starts a
dedicated `outbox-relay-cell-b`: once cut over, Cell B owns persistence and
local outbox publication while Cell A reaches the conversation only through
authenticated Cell ingress.

Run the following dependency recovery drills with Docker available. Each starts
from a clean stack, completes the Cell migration, injects the fault, then
requires the post-recovery write to be readable through Cell A and Cell B's
outbox to drain:

```bash
cd IMServer
./scripts/multicell_smoke.sh failure-drill redis-outage
./scripts/multicell_smoke.sh failure-drill kafka-outage
```

`redis-outage` pauses Redis before a new routed write. `kafka-outage` writes
while Kafka is stopped, then requires the durable Cell B outbox to publish
after Kafka returns. These prove recovery of a single migrated route, not Cell
failover, source-retention cleanup/rollback, or capacity.

On a macOS host, run the source-to-target realtime handoff drill with a real
Cell A TCP recipient presence:

```bash
cd IMServer
IM_MULTICELL_SMOKE_REQUIRE_GATEWAY_TCP_RELAY=true \
  ./scripts/multicell_smoke.sh failure-drill target-gateway-outage
```

The drill force-kills Cell A's Gateway, sends a post-cutover message through
Cell A, requires a new Cell B source
`im_cross_cell_realtime_dispatches` row to remain `pending`, then restores
Cell A and requires that row to become
`delivered`. This specifically proves that an unavailable target ingress does
not create a false acknowledgement. Its receipt must include
`sourceCrossCellOutboxRecovered=true` and
`tcpRecipientDelivery.required=true` / `verified=true`; the verifier rejects a
target-Gateway outage result without both source-outbox and TCP recipient
evidence. It is intentionally unavailable on generic Linux CI because the
TCPDriver uses Apple's Network framework.

The manual GitHub Actions workflow **IMServer Multi-Cell Smoke** runs the same
physical migration on an Ubuntu Docker runner. Its `failure_drill` input can
select `none`, `redis-outage`, or `kafka-outage`; inspect the uploaded reports
and workflow log as the execution evidence. The runner proves HTTP route and
outbox recovery. The optional TCP recipient gate still requires a macOS load
generator, so run it separately with
`IM_MULTICELL_SMOKE_REQUIRE_GATEWAY_TCP_RELAY=true` before making a TCP
cross-Cell delivery claim.

When the Docker stack runs on a remote Linux host, do not try to run the
Network.framework-based TCPDriver on that host. Keep the physical migration
smoke on the remote host, then run the TCP gate from a macOS controller through
private SSH tunnels:

```bash
cd IMServer
IM_MULTICELL_REMOTE_SSH_TARGET=root@your-host \
IM_MULTICELL_REMOTE_SSH_IDENTITY_FILE=/absolute/path/to/key.pem \
  ./scripts/multicell_remote_tcp_relay_probe.sh run
```

The probe reads the latest successful remote migration receipt, opens one real
TCP recipient connection to Cell A, writes through Cell A's command endpoint,
and requires both the recipient packet and a newly delivered durable
`cell-b -> cell-a` realtime outbox record. It writes local evidence to
`reports/latest-multicell-remote-tcp-relay.json`.

Every successful run writes `reports/latest-multicell-smoke.json` and a compose
log. A failed run overwrites that receipt with `status=failed` and records the
same diagnostic log path, so CI artifacts retain the fault context. Validate a
successful receipt explicitly with:

```bash
cd IMServer
python3 scripts/verify_multicell_smoke.py \
  --receipt-json reports/latest-multicell-smoke.json \
  --require-pass \
  --require-artifacts-exist
```

## Isolated Environment Drills

Run these only after a non-production environment has separate gateway,
command-api, query-api, outbox-relay, stream-consumer, and ops processes. Use
the exact role topology in [im-runtime-operating-modes.md](im-runtime-operating-modes.md).

| Drill | Injected failure | Required observation | Pass condition |
| --- | --- | --- | --- |
| Gateway loss | Terminate one gateway with selected conversations open. | TCP close mix, reconnects, client catch-up requests. | Reconnected clients converge through `timeline/since`; no duplicate canonical messages. |
| Consumer restart | Restart one stream consumer after records are committed but before all projections finish. | Stream duplicate/failed counters, outbox backlog, projection lag. | Idempotent projections; backlog drains; no permanently missing summary. |
| Redis outage | Deny route lookup and presence operations briefly. | Route-split drops, Redis errors, client catch-up health. | Durable messages remain readable; no full-fanout fallback; recovery occurs after routing returns. |
| Relay delay/failure | Delay or reject gateway relay requests. | Relay failure/latency counters, active-hint drops, `timeline/since` reads. | Realtime is degraded only; durable catch-up heals affected clients. |
| Outbox interruption | Pause relay, then resume it. | `im_outbox_backlog_events`, publication failures, stream lag. | Backlog is bounded and drains after resume; events publish once. |

Capture before/during/after snapshots of at least:

- `im_outbox_backlog_events` and `im_outbox_failed_events_total`
- `im_stream_*` group lag, duplicate, failed, and processed counters
- `im_gateway_http_relay_*` attempts, failures, and latency totals
- `im_realtime_*_route_split_drop*`
- `im_timeline_since_target_sequence_*`
- client catch-up queue, failure, and latency diagnostics

## Release Boundary

The local gates above are required on every relevant change. The isolated drills
are required before claiming a production multi-node deployment. The complete
role, secret, network, and capacity criteria remain in
[im-runtime-operating-modes.md](im-runtime-operating-modes.md) and
[release-candidate-checklist.md](release-candidate-checklist.md).

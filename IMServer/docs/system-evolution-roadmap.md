# IM System Evolution Roadmap

This document is the engineering roadmap for evolving the current IM system
without changing its core delivery contract. It links client convergence,
command-side durability, realtime hints, read models, and operational evidence
into one ordered plan.

It is intentionally separate from deployment and capacity runbooks. A local
test result proves correctness of a component or contract. It does not prove a
production capacity or availability claim.

## Delivery Invariants

The following rules are not negotiable during future work:

1. The conversation timeline and `timeline/since` are the durable message
   source of truth.
2. TCP domain events and compact activity hints are best-effort invalidations,
   never the only copy of a message.
3. `eventID`, `clientMessageID`, conversation timeline sequence, and owner
   aggregate sequence remain the correlation keys; no message body, access
   token, or email address is added to operational logs or metric labels.
4. Metrics remain low-cardinality aggregates. Per-user, per-conversation, and
   per-event drill-down belongs in structured logs, not Prometheus labels.
5. A performance optimization may reduce best-effort realtime work, but must
   not turn a routing/cache failure into an unbounded full-fanout fallback.

## Current Architecture Boundary

```text
iOS / IMClientKit
    TCP hints, HTTP summaries, timeline/since reconciliation
        |
gateway
    TCP lifecycle, Redis presence/routing, internal relay
        |
command-api -> conversation shard -> outbox -> Kafka
                                           |
stream-consumer -> owner delivery, summary projections, changes log,
                   notification/search/realtime relay
                                           |
query-api -> summaries, changes, timeline, timeline/since, search
```

The production role ownership and required configuration are defined in
[im-runtime-operating-modes.md](im-runtime-operating-modes.md). Large-group
realtime semantics are defined in
[LargeGroupRealtimeDesign.md](LargeGroupRealtimeDesign.md).

## Workstreams

### M1: Client Convergence

**Goal:** a user can reach a correct conversation state even when TCP is
temporarily unavailable or a hint is missing.

Implemented local scope:

- Foreground summary refresh and selected-conversation `timeline/since`
  catch-up are gated by an authenticated HTTP session, not by TCP connection
  state.
- A TCP reconnect failure does not cancel foreground HTTP reconciliation.
- A changed summary whose selected conversation has a newer timeline sequence
  schedules targeted catch-up immediately.
- Backgrounding cancels foreground catch-up and summary refresh work.
- The client records timeline catch-up queue, request, success/failure, page,
  item, and latency diagnostics through its existing health snapshot.

Local acceptance:

- TCP connection failure with a valid HTTP session still refreshes summary
  changes and fills the selected timeline gap.
- The repaired message appears in the selected conversation without leaving
  and reopening it.
- No foreground refresh request continues after backgrounding.

Next refinement:

- Add UI/integration coverage for selected, unselected, foreground, background,
  reconnect, and app relaunch cases against a local runtime.
- Keep the selected-conversation optimization targeted; do not fetch bodies for
  every changed summary.

### M2: Observability and Incident Diagnosis

**Goal:** determine whether an incident is command persistence, outbox/Kafka,
projection, relay, TCP, or client reconciliation without enabling verbose
payload logs.

Existing server coverage:

- `/internal/metrics` exposes TCP lifecycle/close reasons, write backpressure,
  relay work, stream group lag, message-write stages, owner-delivery batching,
  summary/timeline reads, and aggregated client health.
- Client health reports include deferred domain events and timeline catch-up
  diagnostics. Reporting is observational and cannot block sync.
- Gateway, relay, and stream paths preserve request/event correlation fields.

Implemented local scope:

- Message persistence, gateway node/Cell dispatch, and stream-consumer
  fail-closed realtime relay paths use a typed delivery trace with canonical
  `conversation_id`, optional `event_id`, `request_id`,
  `client_message_id`, `timeline_sequence`, `owner_sequence`, `runtime_role`,
  and `outcome` fields.
- Failure paths record a bounded `error_kind` instead of `String(describing: error)`,
  so transport and downstream response text cannot be emitted as
  message payload diagnostics. Local tests assert the correlation fields and
  the absence of payload/raw-error fields.

Remaining changes:

- Apply the standard structured log spelling to future non-delivery code:
  `request_id`, `event_id`, `client_message_id`, `conversation_id`,
  `timeline_sequence`, `owner_sequence`, `runtime_role`, and `outcome`.
- Sampled end-to-end traces are available for explicit diagnostic runs through
  `IM_DELIVERY_TRACE_SAMPLING_ENABLED=true`. Sampling is deterministically
  keyed by correlation IDs and bounded by
  `IM_DELIVERY_TRACE_SAMPLE_RATE_BPS` and
  `IM_DELIVERY_TRACE_MAX_LOGS_PER_MINUTE`; it remains disabled by default.
- Publish dashboard panels and alerts for catch-up failure ratio, stream lag,
  owner-delivery batch latency, relay failures, TCP close reason mix, and
  client deferred-event growth.

### M3: Hot Conversation Write Path

**Goal:** keep a hot conversation's command path predictable while large-group
members use pull-based durable reconciliation.

Order of work:

1. Measure sequence allocation, message persistence, outbox insertion, and
   owner-delivery batch-write latency separately.
2. Keep command-side sequence blocks per command node; verify duplicate
   `clientMessageID` handling under retries and node handoff.
3. Increase owner-delivery batch size only after measuring its database lock,
   row-count, and consumer-lag effects.
4. Reduce realtime payload size before increasing relay batch size further.
   Summary member IDs and full message bodies must stay out of large-group
   realtime fanout.
5. Treat consumer parallelism as a partitioning and ordering decision, not a
   generic thread-count increase.

Local acceptance:

- Duplicate command retry creates one canonical timeline message and one
  durable event effect.
- Batch/fallback paths preserve per-conversation timeline ordering.
- Projection/replay remains idempotent after restart or duplicate stream input.

Online acceptance, deferred:

- Run isolated hot-conversation profiles with stream lag, database metrics, and
  client catch-up latency captured together.
- Record the exact hardware, role count, database topology, Kafka settings,
  traffic shape, and pass/fail thresholds in a capacity report.

### M4: Runtime and Code-Quality Boundaries

**Goal:** make the single-node development mode convenient without letting it
hide production coupling.

- Keep `combined` and inline projection as local-only convenience modes.
- Maintain the route and ownership split between gateway, command-api,
  query-api, outbox-relay, stream-consumer, and ops.
- Keep database writes behind command services/repositories and query models
  behind read-side services.
- Continue moving fanout/persistence policy into explicit configuration objects
  with validation, rather than reading environment variables in hot paths.
- Add deterministic failure tests for role guards, replay, cache unavailability,
  and duplicate delivery.

### M5: Multi-Node and Failure Readiness

**Goal:** prepare the architecture for horizontal deployment before traffic
requires it.

- Gateway nodes remain stateless except for local TCP channels; Redis is the
  presence and route index.
- Command nodes own only their local sequence block cache and persist durable
  state through shards/outbox.
- Consumers scale by partition/consumer-group ownership while preserving the
  ordering guarantees documented for each projection.
- Cross-node relay remains authenticated internal traffic with bounded retries;
  failure degrades to client `timeline/since`, not message loss.

Cell and shard rollout order:

1. `conversation_directory` is the primary-database authority for
   `conversation_id -> cell_id + shard_id`; independent conversation shards do
   not maintain duplicate routing or direct-pair directory records.
2. Command responses and read models are split before enabling independent
   conversation-shard writes. When summary storage is separate, conversation
   creation, membership, metadata, preferences, and invite-join commands
   require the command-receipt media type and return `202`; the server never
   rebuilds a summary from the command shard for those requests. Local combined
   mode retains the legacy summary response only for compatibility.
3. Command and strong-query public routes now resolve and forward an active
   remote `cell_id` exactly once through configured Cell ingress endpoints,
   preserving bearer authentication and binding the request to a target cell
   and directory route version. The receiving Cell verifies the internal
   credential, target cell, and current route version before execution. Gateway
   messages and non-conversation query surfaces remain a separate rollout;
   a route without a configured endpoint still returns a typed `503`, never
   falls through to a local shard.
4. Directory cache and remote Cell forwarding latency/error metrics are
   exposed with low-cardinality aggregates. Command, query, and realtime Cell
   forwarding now select separate role-specific ingress maps, with the old
   Cell-wide endpoint retained only as an L7-router compatibility fallback.
   Malformed endpoint-map entries fail production startup instead of being
   silently ignored. A disposable two-Cell smoke starts Cell B's
   gateway/command/query roles against an isolated physical conversation-shard
   PostgreSQL database. It performs a Cell A -> Cell B
   prepare/copy/verify/cutover, then checks command/query forwarding after the
   route change. On a macOS load generator it can also require a TCP recipient
   connected to Cell B to receive a message sent via Cell A. Next run that gate
   and the node, Redis, Kafka, and directory-failure drills in an isolated
   environment.

Required fault tests before a production multi-node claim:

- Kill one gateway with active selected conversations.
- Restart a consumer with duplicate stream records.
- Drop Redis route lookups and verify pull-based recovery.
- Delay Kafka/relay and verify visible lag plus eventual durable catch-up.
- Verify no role outside `ops` performs schema migration.

Physical shard migration now has prepared route-version snapshots, paged
idempotent canonical copy, and deterministic source/target fingerprint
verification. `ops --copy-conversation-shard-migration` persists per-table
source-row watermarks, while `ops --verify-conversation-shard-migration`
advances to `ready_to_cutover`. The manual source-Cell `ops
--cutover-conversation-shard-migration` command uses a migration lease, source
write fence, frozen re-verification, target search-index rebuild, and directory
route-version CAS. Automatic route changes remain disabled. Recipient snapshots
and side-effect claims are copied with canonical migration data.

Cross-Cell migration now has authenticated target preflight, resumable
canonical page upload, remote canonical verification, and target-local search
index rebuild over target-Cell command ingress. `ops
--inspect-conversation-shard-migration` and `ops
--prepare-conversation-shard-migration` accept `--target-cell`; prepare stores
the source route/version, target binding, and a short-lived transfer capability
in the shared primary control record. The receiver accepts a page only for that
active `copying` migration and validates its checksum, origin, route version,
target shard, and capability before idempotent primary-key import. The source
Cell exclusively owns the write fence and final directory CAS; target index
rebuild requires the active cutover lease. The disposable two-Cell Compose
smoke now rehearses this physical copy/cutover boundary using separate source
and target conversation-shard PostgreSQL instances. Source-retention cleanup,
rollback automation, and a fault-injected remote transfer rehearsal remain
required before broad production use.

Before deploying more than one Cell, run
`deploy/multinode/validate_multicell_inventory_set.sh` with every node
inventory. It validates each Cell's node map separately, requires the shared
primary control database/Kafka/internal credentials and identical role-specific
Cell ingress maps, and rejects a physical conversation-shard database reused
by two different Cells.

The local-contract and isolated-environment boundaries for these drills are
maintained in [multi-node-fault-validation.md](multi-node-fault-validation.md).

### M6: Administration and Trust Operations

**Goal:** make user support and content moderation a separately authenticated,
auditable Web workflow without granting application clients backend power.

Implemented local scope:

- The Web console and Admin API stay on `command-api` only; they are not part
  of iOS application navigation or gateway/query runtime roles.
- `super_admin`, `moderator`, and `support` roles have explicit server-side
  permissions. A shared admin secret is retained only as a break-glass
  `super_admin` bootstrap path.
- An administrator can authenticate with an existing access token; audit
  records use the verified account email rather than a request-controlled
  actor header.
- Role changes invalidate active authentication-principal cache entries, and
  every role/status/report mutation records actor role and authentication
  method in audit metadata.
- Report status changes now use a shared state machine and append immutable
  decision records with reviewer identity, role, authentication method,
  transition, resolution category, note, and request correlation. Terminal
  decisions cannot be reopened through the normal moderation route.
- Report reviewer assignment, controlled HTTPS evidence links, and request
  idempotency are now explicit. Retrying an identical decision or evidence
  write returns the existing result; reusing a key with changed input is
  rejected.
- Operators have indexed active-report queues for unassigned work, their own
  work, or all active work, with backlog age summaries. Audit queries support
  exact actor/target/request correlation and ISO-8601 time windows.
- `super_admin` can inspect a user's session and push-device metadata through
  a separate permission; credential material and complete push tokens are
  never exposed, and every inspection is audited.
- Conversation metadata and member-state inspection is available to support
  staff through a separate permission; canonical message-body inspection is
  restricted to `super_admin`, reads the owning conversation shard strongly,
  and records only bounded pagination metadata in audit events.
- User status, role, and reviewer assignment writes now share an actor-scoped
  idempotency ledger with hashed request fingerprints, alongside the existing
  immutable decision and evidence idempotency records.
- `super_admin` can set group-wide mute state or remove a non-owner group member
  through a cross-shard command. The destructive removal path requires an
  explicit confirmation, durable shard-side idempotency receipt, action-specific
  Outbox events, and accepted/applied/failed audit records. Report rows already
  link to their owning conversation and bounded message snapshot in the Web
  management console.
- `super_admin` can freeze or unfreeze a group through `group.lifecycle.set`.
  Freezing requires explicit confirmation, projects `groupLifecycleState` into
  conversation summaries, and blocks user message, forward, AI-stream,
  metadata, invitation, and membership writes while retaining history, read
  state, leave, and invitation revocation. TCP `metadata_updated` is only an
  invalidation signal; HTTP summary reconciliation remains canonical.
- `super_admin` can dissolve a group through the same command with explicit
  confirmation. Dissolution is an irreversible, read-only historical archive:
  it preserves messages, media, and current membership for historical access,
  blocks all group and member mutations including leave, and cannot transition
  back to `active` or `frozen`. Physical retention/deletion is intentionally a
  separate policy-controlled workflow.

Next increments, in order:

1. Add repeated-abuse, account/device-risk, and SLA escalation signals; the
   current report queue is intentionally limited to direct backlog and age.
   Add exportable audit search only with explicit access control and retention
   policy.
2. Replace long-lived browser-entered credentials with an admin-specific
   short session, MFA, session/device inventory, forced re-auth for privileged
   actions, and network access restrictions.

The cross-shard command, inbox, Outbox, and central-audit requirements for
destructive group governance are specified in
[admin-cross-shard-governance.md](admin-cross-shard-governance.md).

Local acceptance:

- A non-admin access token receives no management access.
- `moderator` can process reports but cannot inspect user inventory, change
  user status, assign roles, or read audit records.
- `support` can inspect overview, users and conversation metadata, but cannot
  inspect message bodies or perform write actions.
- Revoking a role takes effect on the next request even with session
  validation caching enabled.
- An audited mutation contains verified actor, role, authentication method,
  request correlation, target, and bounded metadata, with no message payload
  copied into log fields.

Production acceptance, deferred:

- Verify independent admin host/VPN policy, HTTPS, MFA, secret rotation,
  access-review process, audit retention/export controls, and a break-glass
  exercise in an isolated environment.

## Verification Matrix

| Layer | Local gate | Environment gate |
| --- | --- | --- |
| IMClientKit state reducers | `swift test --package-path IMClientKit` | N/A |
| iOS runtime coordination | focused simulator tests | two-device reconnect/background smoke |
| IMServer contracts | `swift test --package-path IMServer` | PostgreSQL/Redis/Kafka release gate |
| Role validation | environment preflight unit tests | isolated staging roles |
| TCP capacity | driver/script static and smoke tests | dedicated load generators, cache-prewarmed login |
| Large-group delivery | projection/replay/local contract tests | isolated hot-group rate ladder |
| Admin management | role matrix and audit mutation tests | isolated administrator/MFA/network-policy drill |

No release note or capacity document may convert a local gate into an online
capacity conclusion.

## Completed Local Evidence

The local M3 measurement and failure-policy gates are complete:

1. `LoadTests/run_local_hot_conversation.sh` captures local-only command,
   persistence, outbox, projection, relay, and `timeline/since` window stages.
2. `LoadTests/run_local_multinode_fault_contracts.sh` exercises the fail-closed
   routing, durable outbox recovery, client retry, projection replay, and owner
   delivery ordering contracts without requiring remote infrastructure.
3. The hot write pipeline reserves one contiguous conversation domain-event
   sequence range per batch. Idempotent retries do not consume a new sequence.

These are regression and design-correctness gates only. Their local artifacts
must not be used as production capacity or availability evidence.

## Next Implementation Slice

The next slice advances from local evidence to isolated-environment proof:

1. Run the multi-node fault matrix with independent gateway, command-api,
   query-api, outbox-relay, stream-consumer, Redis/Valkey, Kafka, and PostgreSQL
   roles, preserving the matching deployment inventory revision.
2. Capture before/during/after metrics for every injected fault described in
   [multi-node-fault-validation.md](multi-node-fault-validation.md).
3. Use those results to choose one narrow write-path or delivery-path
   optimization at a time; do not infer it from combined local runs.

This sequence keeps system correctness, operational diagnosis, and throughput
work independently verifiable.

# IMMonorepo Architecture Boundaries

This document is the maintenance contract for the monorepo. It does not change
wire protocols or runtime behavior; it defines where new code is allowed to live.

## Ownership

- `IMServer` owns authentication/session authority, message timeline, server
  sequence, read state, realtime fanout, AI stream terminal state, and operational
  repair.
- `IMClientKit` and `IMClientKitAndroid` own client protocol adapters, local
  cache integration, sync/runtime controllers, and state merging.
- `IMApp` and Android `app` own UI, view models, application lifecycle, and
  dependency assembly only.
- Release scripts, monitoring, and capacity reports own launch confidence. A GA
  claim requires real Redis staging and capacity data, not local-only tests.

## Boundary Rules

- App/UI layers must not directly parse TCP packets, run HTTP sync, write cache
  snapshots, or compensate AI stream chunks. They call facade/gateway methods and
  observe state.
- Client core libraries must keep DTOs, persistence models, and wire models behind
  domain/read models before they reach UI.
- AI stream state writes must go through `AIMessageStreamStateStore`, with
  message `derivedState`/content and `im_ai_message_streams` double-writes
  centralized in `AIMessageStreamWriteStore`.
- AI stream provider, content safety, billing, and model routing code must not
  write message/index state or hold database write dependencies. New providers
  call the streaming service/facade only, and new audit or repair rules belong
  in `AIMessageStreamRepairStore`.
- Large IM runtime services should stay as facades over small components. New
  summary projection, outbox, event stream, or message write behavior belongs in
  a focused helper/coordinator rather than expanding the facade file.
- High-complexity service files listed in `docs/service-size-budgets.tsv` have
  explicit owners and line budgets. Increasing a budget is a design decision:
  split a helper first, and only raise the budget with owner review and a clear
  reason in the PR.
- Real AI providers must pass through `AIStreamRequestGuardrails` before lease
  reservation/provider execution. Content safety, concurrency limiting, and cost
  ceilings are provider-entry requirements, not optional provider-specific code.
- TCP is the realtime accelerator. HTTP `changes`, `messages/since`, and stream
  snapshots remain the convergence source after reconnect.
- Cross-subsystem work must be split into reviewable commits: protocol/server,
  iOS core/app, Android core/app, release/monitoring, and docs.

## Review Requirements

- Changes touching TCP, multi-device routing, read sync, cache restore, AI stream,
  media transfer, or DB migrations require targeted regression tests.
- Changes touching release gate or capacity docs must state whether the evidence
  is real staging data or local smoke only.
- Production safety assumptions, including TCP TLS termination, internal secrets,
  Redis ACLs, and metrics secrets, must remain explicit in runbooks.

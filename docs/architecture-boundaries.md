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
- AI stream state writes must go through the stream state store. Do not update
  message `derivedState` and `im_ai_message_streams` independently.
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

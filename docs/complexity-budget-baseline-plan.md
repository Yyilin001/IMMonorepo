# Complexity Budget Baseline Plan

The governance boundary check enforces `docs/complexity-budgets.tsv` in CI.
Several high-complexity files predate that CI enforcement, so the budget table
records their current line-count baseline rather than an aspirational target.
This keeps CI actionable: feature work cannot grow those files without an
explicit architecture review, while existing production work can still pass.

## Baseline Policy

- Budget entries above the category target are legacy baselines, not design
  approval for further growth.
- Do not increase a baseline for feature work. Split a helper, reducer,
  coordinator, or view subcomponent first.
- Keep budget changes separate from behavior changes when possible.
- Remove stale budget entries when files are deleted or renamed.

## Priority Splits

1. `ConversationEventConsumers.swift`: split domain delivery, realtime delivery,
   summary projection, notification, and failure/retry handling into focused
   consumer modules.
2. `IMTCPServerSupport.swift` and `IMGatewaySessionRuntimeSupports.swift`: split
   channel lifecycle, auth/session bookkeeping, relay dispatch, and close reason
   metrics into dedicated support types.
3. `ConnectionRoutingService.swift`: separate route lookup/cache policy from
   gateway relay command handling.
4. `AuthService.swift`: separate token issuing, session lifecycle, credential
   validation, and audit/event recording.
5. Client IM stores and views: keep SwiftUI-facing stores thin and move
   timeline, outgoing queue, domain-event replay, and cache mapping behavior
   behind reducers or coordinators.

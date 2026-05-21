# IMMonorepo Domain Boundaries

This document turns the architecture rules into domain-level ownership. It is a
maintenance contract only: it does not change TCP packets, public HTTP APIs, or
database semantics.

## Domain Owners

| Domain | Primary paths | Allowed dependencies | Forbidden dependencies |
| --- | --- | --- | --- |
| Server timeline and message write | `IMServer/Sources/IMServer/IM/*Message*`, conversation commands, migrations | database models, write coordinators, outbox facade, projection facade | client DTOs, app UI state, direct provider policy writes |
| Server routing, sessions, and presence | `IMServer/Sources/IMServer/IMTCP`, connection routing, gateway session support | session/auth services, presence store, node dispatch facade | client cache, UI state, AI provider internals |
| Server outbox and read model | outbox processor, summary projection, read supports, event consumers | message timeline, projection builders, dispatch facade | direct controller response shaping outside adapters |
| Server AI stream | `AIStream*`, `AIMessageStream*`, `IMMessageStreamingService` | `AIStreamProviderPolicyService`, lease coordinator, state store facade, event publisher | direct message/index writes outside stream write/repair stores |
| Server media | `IMServer/Sources/IMServer/Media`, media command services | media storage provider facade, auth/session identity, message facade | direct client UI state, AI stream state writes |
| Server contacts and social graph | contact requests, block list, direct conversation relationship support | user/auth services, conversation command facade | realtime packet parsing, client local cache |
| iOS core runtime | `IMClientKit/Sources/IMClientKit` | protocol adapters, persistence abstractions, state stores, runtime facades | SwiftUI view state, app navigation, direct server DB concepts |
| iOS app runtime and UI | `IMApp/IMApp/Auth`, `IMApp/IMApp/Features` | `AuthManager`/runtime facades, `IMClientKit` public models, presentation helpers | TCP packet parsing, HTTP sync orchestration, GRDB/cache internals, stream recovery internals |
| Android core runtime | `imclientkit/src`, `IMClientKitAndroid` | Ktor/Room/DataStore internals, runtime/store facades, DTO adapters | Compose UI, Android route state |
| Android app and UI | `app/src` | gateway/ViewModel APIs, Compose state, dependency assembly | Ktor calls, Room DAO/database access, raw TCP transports in UI/ViewModel code |
| Release and monitoring | `IMServer/scripts`, `IMServer/LoadTests`, `monitoring`, `deploy` | release gate output, Prometheus/Grafana metrics, capacity reports | GA claims without real Redis staging and capacity data |

All owner routing is encoded in `.github/CODEOWNERS`. Pull requests that touch
more than two domains must split commits by domain and call out the impacted
domains in the PR checklist.

## Facade Rules

- App/UI code calls facades and observes state. It must not parse TCP packets,
  run HTTP sync, write cache snapshots, open Room/GRDB databases, or compensate
  AI stream chunks directly.
- Client core libraries convert DTO, persistence, and wire models into domain or
  read models before state reaches app UI.
- Server controllers route commands into domain facades. They should not mutate
  outbox, projection, stream index, or message derived state directly.
- Large facade files listed in `docs/complexity-budgets.tsv` may coordinate, but
  new behavior belongs in a helper/coordinator behind the facade.

## AI Stream Boundary

- `AIMessageStreamWriteStore` is the only component allowed to dual-write message
  `derivedState`/content and `im_ai_message_streams` during start, snapshot
  update, terminal finalize, and repair transactions.
- `AIMessageStreamRepairStore` may repair legacy or stale rows through the same
  state-store boundary.
- `IMMessageStreamingService`, providers, content safety, rate limiting, cost
  ledger, model routing, and fanout code must call the state facade. They must
  not hold database write dependencies for message/index state.
- Real provider work must pass through `AIStreamProviderPolicyService` before
  lease reservation or provider execution.
- New stream terminal states, audit rules, or repair paths require state-store
  regression tests and an update to the PR checklist impact section.

## Complexity Budget Rules

- `docs/complexity-budgets.tsv` is the single source of truth for files above the
  governance threshold.
- Budget categories:
  - `facade`: 500-800 lines are acceptable only for forwarding and orchestration.
  - `controller` / `coordinator`: target 200-500 lines.
  - `view` / `component`: target 100-350 lines.
  - `domain-store`: files above 800 lines need an explicit reducer/merge/cache
    split plan and owner review.
- New files above the threshold must be added to the budget in the same commit,
  or split before merge.
- Raising a budget is architecture work. It must be a separate commit with the
  reason, impacted domain, and follow-up split plan.

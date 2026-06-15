## Summary

- What changed:
- Why:

## Touched domains

- [ ] Server timeline/message-write
- [ ] Server routing/session/presence
- [ ] Server outbox/read-model/projection
- [ ] Server AI stream/provider policy
- [ ] Server media
- [ ] Server contacts/social graph
- [ ] iOS `IMClientKit`
- [ ] iOS App runtime/UI
- [ ] Android `:imclientkit`
- [ ] Android App/ViewModel/UI
- [ ] Release/monitoring/capacity
- [ ] Docs/governance only

If more than two domains are checked:

- [ ] Commits are split by domain, and each commit message names its domain.
- [ ] Cross-domain compatibility and rollback notes are included below.

## Boundary checklist

- [ ] Change is scoped to one subsystem, or commits are split by subsystem.
- [ ] App/UI layers do not directly handle TCP, HTTP sync, cache persistence, Room/GRDB, or stream chunk compensation.
- [ ] IMServer remains the protocol and persistence authority for message timeline, read state, sessions, and AI stream terminal state.
- [ ] AI stream message/index writes go through the stream state store; no direct dual-write bypass was added.
- [ ] AI stream provider, content safety, billing, or model routing code does not write message/index state directly.
- [ ] AI provider changes pass through `AIStreamRequestGuardrails` for content safety, concurrency limiting, and cost ceilings.
- [ ] New AI stream terminal states, audit rules, or repair behavior include state store / repair regression tests.
- [ ] High-complexity files remain within `docs/complexity-budgets.tsv`, or the budget increase is reviewed as architecture work in a separate commit.
- [ ] Public HTTP API, TCP packet shape, and DB primary semantics are unchanged, or compatibility/migration is documented.

## Complexity budget impact

| Path | Old lines | New lines | Budget | Action |
| --- | ---: | ---: | ---: | --- |
| | | | | |

- [ ] No new Swift/Kotlin/server file exceeds the governance threshold without an entry in `docs/complexity-budgets.tsv`.
- [ ] Any budget increase includes the owner, category, reason, and follow-up split plan.

## Risk checklist

- [ ] Multi-device, ack/canonical echo, read sync, and gap sync behavior are covered when touched.
- [ ] DB migration has forward/revert behavior and data backfill/repair notes when needed.
- [ ] Release gate/capacity changes use real staging data before claiming GA readiness.
- [ ] Rollback or operational fallback is documented for production-facing changes.

## Compatibility / rollback notes

- Impacted domains:
- Backward compatibility:
- Rollback or feature flag:

## Validation

- [ ] Governance: `./scripts/check_governance_boundaries.sh`
- [ ] IMServer production gate: `cd IMServer && ./scripts/production_release_gate.sh`
  - Local fast smoke only: `cd IMServer && ./scripts/production_release_gate.sh --skip-swift-tests`
- [ ] IMServer: `swift test --no-parallel`
- [ ] iOS core: `cd IMClientKit && swift test`
- [ ] iOS app: `xcodebuild ... build/test -only-testing:IMAppTests`
- [ ] Android: `./gradlew :imclientkit:testDebugUnitTest :app:testDebugUnitTest :app:assembleDebug`
- [ ] Redis staging/release gate, when required:
  `cd IMServer && ./scripts/multidevice_release_gate.sh --require-redis --require-staging-baseline --env-file LoadTests/staging-baseline.env --profile staging-baseline`

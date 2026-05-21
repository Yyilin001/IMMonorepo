# IMServer RC Capacity Report

- Date: 2026-05-21
- Git commit: `05ce2eb6aebe04f410384e358fb6d91b3b81b5a9`
- Environment: local validation completed; Redis staging baseline pending
- Test owner: release engineering
- Release status: RC candidate only, not GA

## Evidence Summary

This report is intentionally not a GA capacity claim. The current branch has local correctness and governance evidence, but the required Redis staging release gate and 100/500/1000 online-device load ladder have not been executed in this environment.

| Evidence | Status | Notes |
| --- | --- | --- |
| IMServer unit/integration tests | Passed | `swift test --no-parallel`, 173 tests, prior validation on this branch |
| iOS app tests | Passed | `xcodebuild ... test -only-testing:IMAppTests -parallel-testing-enabled NO`, 87 tests, prior validation on this branch |
| iOS simulator build | Passed | `xcodebuild ... build`, prior validation on this branch |
| Governance boundary scan | Passed | `./scripts/check_governance_boundaries.sh`, prior validation on this branch |
| Redis integration tests | Pending | Requires `IM_REDIS_INTEGRATION_URL` |
| Staging baseline release gate | Pending | Requires `LoadTests/staging-baseline.env` and staging services |
| 100/500/1000 device capacity ladder | Pending | Must be run against staging before GA |

## Topology

| Component | Value |
| --- | --- |
| gateway nodes | Pending staging run |
| command-api nodes | Pending staging run |
| query-api nodes | Pending staging run |
| outbox-relay nodes | Pending staging run |
| stream-consumer groups | Pending staging run |
| PostgreSQL shape | Pending staging run |
| Kafka brokers/partitions | Pending staging run |
| Redis shape | Pending staging run |

## Required Workload

| Scenario | Required Result | Current Status |
| --- | --- | --- |
| `1 user x 5 devices` | Same-account fanout, self echo merge, no duplicate canonical messages | Pending |
| `100 users x 2 devices` | Normal multi-device fanout and read sync | Pending |
| `1 group x 500 members x 2 devices` | Large group fanout, outbox drain, projection convergence | Pending |
| `AI stream concurrency` | User limit 2, conversation limit 5, reject/repair/finalize metrics stable | Pending |
| `reconnect storm` | Gap sync recovery succeeds without duplicates after gateway disruption | Pending |

## Results

| Metric | Go/No-Go Threshold | Result |
| --- | --- | --- |
| HTTP error rate | `< 0.1%` | Pending |
| TCP error rate | `< 0.1%` | Pending |
| TCP ack p50/p95/p99 | Record values | Pending |
| canonical message p50/p95/p99 | Record values | Pending |
| ack success rate | `>= 99.9%` | Pending |
| canonical success rate | `>= 99.9%` | Pending |
| duplicate canonical messages | `0` | Pending |
| wrong-session kicks | `0` | Pending |
| write P95/P99 | Record values | Pending |
| list conversations P95/P99 | Record values | Pending |
| changes convergence P95/P99 | Record values | Pending |
| messages/since success rate | Record values; must converge without duplicates | Pending |
| reconnect count | Record values | Pending |
| server errors | `0` unexpected errors | Pending |
| outbox backlog peak | Record values | Pending |
| outbox recovery time | Backlog must return to `0` after load stops | Pending |
| Kafka lag peak | Record values | Pending |
| projection lag P95/P99 | Record values | Pending |
| Redis dispatch success | `100%` expected for routed dispatch | Pending |
| cross-node dispatch failures | `0` | Pending |
| session-count relay failures | `0` | Pending |
| AI stream active peak | Record values | Pending |
| AI stream rejected | Expected only for configured limit tests | Pending |
| AI stream stale repairs | `0` during healthy load | Pending |
| AI stream finalize failures | `0` | Pending |

## Required Commands

```bash
cd /Users/yyl/Desktop/Code/IMMonorepo/IMServer

IM_REDIS_INTEGRATION_URL=redis://... swift test --filter RedisPresenceIntegrationTests

./scripts/multidevice_release_gate.sh \
  --require-redis \
  --require-staging-baseline \
  --env-file LoadTests/staging-baseline.env \
  --profile staging-baseline
```

## Go/No-Go

- Decision: No-Go for GA until Redis staging release gate and capacity ladder are complete.
- Current label: RC candidate.
- Blocking issues:
  - Redis integration evidence is not attached.
  - Staging baseline output is not attached.
  - Prometheus metric snapshot is not attached.
  - TCPDriver logs for the five required scenarios are not attached.
  - 100/500/1000 online-device capacity ladder has not been recorded.
- Follow-up actions:
  - Provision `LoadTests/staging-baseline.env` without committing secrets.
  - Run the release gate command above.
  - Attach release gate output, staging baseline report, Prometheus snapshots, and TCPDriver logs.
  - Fill this report with measured values and only then make an RC Go/No-Go decision.

GA remains blocked by any duplicate canonical message, wrong-session kick, cross-node dispatch failure, permanent AI streaming state, AI finalize failure, or sustained outbox backlog after load stops.

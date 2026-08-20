# Direct room-log admission-mode A/B (2026-08-21)

This is a disposable, same-host experiment. It decides the default for the
`shard_only` admission experiment; it is not a production capacity promise.

## Controlled inputs

- One ARM64 8-vCPU / 16-GiB host, one Gateway, PostgreSQL 16, public TLS.
- Fresh PostgreSQL volume, canonical schema, fresh Caddy CA, and 1,500 fresh
  users for **each** arm.
- `high-active-direct-1500-600-v1`: 100 connections/s ramp, 4,500 symmetric
  direct rooms pre-opened before the phase, then 600 message/s and 600
  room-log reads/s for 60 seconds.
- `fsync=on`, `synchronous_commit=on`, `full_page_writes=on`, content review
  disabled, room-log mode, and shard-credit batch size 32 in both arms.

## Results

| Metric | `room` | `shard_only` | Delta |
| --- | ---: | ---: | ---: |
| Authenticated / connection failures | 1,500 / 0 | 1,500 / 0 | unchanged |
| Message ACK | 29,343 | 29,140 | -0.7% |
| Message ACK P95 | 626 ms | 696 ms | +11.2% worse |
| Room-log pull P95 | 513 ms | 567 ms | +10.5% worse |
| Heartbeat P95 | 270 ms | 285 ms | +5.6% worse |
| Workload failures | 0 | 0 | unchanged |

## Decision

Do **not** deploy `shard_only` or its shard-credit batch as the default. The
feature preserves the intended authorization and durability invariants, but
it does not remove the locked-room pre-read, canonical message/event append,
event indexes, or synchronous WAL commit. On this representative test it
made the end-to-end path slower. Keep the runtime guard and integration test
for controlled research only; use `room` with a credit batch size of `0` for
the default direct room-log deployment.

The next experiment must target a larger mandatory unit of work: an ordered,
bounded micro-batch that durably appends several canonical events in one
transaction while preserving per-room ordering and idempotent ACK semantics.

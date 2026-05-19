# IMServer Capacity Report

- Date:
- Git commit:
- Environment:
- Test owner:

## Topology

- gateway nodes:
- command-api nodes:
- query-api nodes:
- outbox-relay nodes:
- stream-consumer groups:
- PostgreSQL shape:
- Kafka brokers/partitions:
- Redis shape:

## Workload

- Profile:
- Duration:
- Concurrent users/connections:
- Device mix:
  - 1 user x 5 devices:
  - 100 users x 2 devices:
  - 1 group x 500 members x 2 devices:
- Message rate:
- Read mix:
- Group size:
- AI stream concurrency attempts:
- Reconnect storm command:

## Results

- HTTP error rate:
- TCP error rate:
- TCP ack p50/p95/p99:
- canonical message p50/p95/p99:
- ack success rate:
- canonical success rate:
- duplicate canonical messages:
- wrong-session kicks:
- write P95/P99:
- list conversations P95/P99:
- changes convergence P95/P99:
- messages/since success rate:
- reconnect count:
- server errors:
- outbox backlog peak:
- outbox recovery time:
- Kafka lag peak:
- projection lag P95/P99:
- Redis dispatch success:
- cross-node dispatch failures:
- session-count relay failures:
- AI stream active peak:
- AI stream rejected:
- AI stream stale repairs:
- AI stream finalize failures:

## Failure Drills

- restart-gateway:
- pause-stream-consumer:
- stop-outbox-relay:
- redis-outage:

## Go/No-Go

- Decision:
- Blocking issues:
- Follow-up actions:
- RC rule: do not mark Go when any duplicate canonical message, wrong-session kick, cross-node dispatch failure, permanent AI streaming state, or sustained outbox backlog is observed.

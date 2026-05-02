# IMServer 100w DAU capacity validation plan

This runbook proves whether the current implementation can support 100w DAU.
It assumes private chat and small groups are the primary workload.

## Target envelope

- DAU: 1,000,000
- Concurrent online users: 50,000 to 100,000
- Initial write target: 3,000 msg/s
- Stretch write target: 10,000 msg/s
- Conversation list and history reads: P95 below 300 ms during write load
- Main message write path: P95 below 150 ms, P99 below 300 ms
- `messages/since` reconnect gap fill success: above 99.9%
- Cross-node realtime dispatch success: above 99.9%
- Projection lag: P95 below 2 seconds
- Search lag: P95 below 3 seconds when OpenSearch is enabled

## Required deployment

Use `deploy/multinode` to deploy at least:

- 2 gateway nodes
- 2 command-api nodes
- 2 query-api nodes
- 2 outbox-relay nodes
- 1 stream-consumer process per consumer group
- 3 Kafka brokers
- PostgreSQL primary plus replica, or managed PostgreSQL
- Redis HA deployment
- Prometheus scraping `/internal/metrics`

The existing single-node profile is only valid for functional verification.

## Load generator

Run from one or more independent load-generator hosts:

```bash
python3 tools/loadtest/im_loadgen.py \
  --http-base-url http://api.example.com \
  --tcp-host tcp.example.com \
  --tcp-port 9000 \
  --users 1000 \
  --group-size 10 \
  --duration-seconds 900 \
  --tcp-messages-per-second 0.05 \
  --read-every 20
```

Scale by running multiple generators with different email templates:

```bash
python3 tools/loadtest/im_loadgen.py --email-template lg1-{index}@example.com ...
python3 tools/loadtest/im_loadgen.py --email-template lg2-{index}@example.com ...
```

The generator covers:

- login/register
- conversation creation
- conversation list reads
- latest 100 message reads
- TCP auth
- TCP message writes

## Test phases

### Phase 1: baseline

- 1k concurrent test users
- 50 msg/s
- 10 minutes
- No errors above 0.1%
- Metrics endpoint available from every HTTP role

### Phase 2: 10w DAU proxy

- 10k concurrent TCP connections
- 500 to 1,000 msg/s
- 30 minutes
- Conversation and message read P95 below 300 ms
- Outbox backlog returns to zero after load stops

### Phase 3: 100w DAU target

- 50k concurrent TCP connections
- 3,000 msg/s
- 60 minutes
- Projection lag P95 below 2 seconds
- Cross-node dispatch failure rate below 0.1%
- Reconnect gap fill success above 99.9%

### Phase 4: stretch

- 100k concurrent TCP connections
- 10,000 msg/s
- 60 minutes
- Scale Kafka partitions, command-api, and outbox-relay until backlog is stable

## Failure drills

Run these during Phase 3:

- restart one gateway node
- restart one command-api node
- pause one stream-consumer group for 5 minutes, then resume
- stop one outbox-relay node
- inject Kafka broker restart
- inject Redis 30 second outage in staging

Pass condition:

- no durable message loss
- consumers catch up after recovery
- clients reconnect and fill gaps using `messages/since`
- alerts fire and recover

## Metrics to watch

Prometheus config lives in `monitoring/prometheus`.

Critical metrics:

- `im_http_requests_total`
- `im_http_request_failures_total`
- `im_http_request_latency_avg_millis`
- `im_http_request_latency_max_millis`
- `im_tcp_connections`
- `im_cross_node_dispatch_total`
- `im_cross_node_dispatch_failures_total`
- `im_outbox_backlog_events`
- `im_outbox_oldest_pending_age_millis`
- `im_projection_lag_millis`
- `im_search_lag_millis`
- `im_stream_consumed_events_total`
- `im_stream_failed_events_total`

## Capacity report template

For each test phase record:

- date and git commit
- deployment topology and instance sizes
- Kafka partitions and broker count
- PostgreSQL configuration
- Redis configuration
- generator count and parameters
- HTTP RPS, failure rate, P95/P99 latency
- TCP connections
- msg/s
- outbox backlog peak and recovery time
- projection lag P95/P99
- reconnect success rate
- bottleneck and next scaling action


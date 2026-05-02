# IMServer multi-node production template

This directory is a deployment template for capacity validation and production
rollout. It does not replace the single-node Ubuntu scripts; it defines the
role split, ports, and environment shape required to prove 100w DAU.

## Topology

Minimum capacity-validation topology:

- `gateway`: 2+ nodes, public TCP `9000`, private HTTP `18080`
- `command-api`: 2+ nodes, private HTTP `8081`
- `query-api`: 2+ nodes, private HTTP `8082`
- `outbox-relay`: 2+ nodes
- `stream-consumer`: one process per consumer group
- `postgres`: managed PostgreSQL or primary/replica pair
- `redis`: managed Redis, Sentinel, or Cluster
- `kafka`: 3+ brokers for production validation
- `prometheus`: scrapes each HTTP role on `/internal/metrics`

Traffic routing:

- Public HTTP/API load balancer:
  - `/api/auth/*` -> gateway `18080`
  - `GET /api/im/*` -> query-api `8082`
  - non-GET `/api/im/*` -> command-api `8081`
  - `/api/media/*` -> command-api `8081`
- Public TCP load balancer:
  - `9000/tcp` -> gateway nodes, connection draining enabled
- Metrics:
  - only private network can access `/internal/metrics`

## Render role env files

Copy the inventory template and edit it:

```bash
cp deploy/multinode/inventory.example.env deploy/multinode/inventory.env
vim deploy/multinode/inventory.env
```

Render environment files:

```bash
bash deploy/multinode/render_env.sh deploy/multinode/inventory.env /tmp/imserver-multinode-env
```

Copy the generated files to each node:

```text
/tmp/imserver-multinode-env/common.env
/tmp/imserver-multinode-env/roles/<role>.env
```

Install the existing systemd units on each host, but keep only the unit for that
host's role enabled. Example gateway node:

```bash
sudo install -d -m 0750 /etc/imserver /etc/imserver/roles
sudo cp common.env /etc/imserver/common.env
sudo cp roles/gateway.env /etc/imserver/roles/gateway.env
sudo systemctl enable --now imserver-gateway
```

For stream consumers, deploy one role env per group:

```text
stream-consumer-summary.env       IM_STREAM_CONSUMER_GROUPS=summary-projection-consumer
stream-consumer-changes.env       IM_STREAM_CONSUMER_GROUPS=changes-log-consumer
stream-consumer-search.env        IM_STREAM_CONSUMER_GROUPS=search-index-consumer
stream-consumer-notification.env  IM_STREAM_CONSUMER_GROUPS=notification-consumer
stream-consumer-repair.env        IM_STREAM_CONSUMER_GROUPS=repair-replay-consumer
```

Each process must run exactly one group in production.

## Capacity validation checklist

1. Deploy the role split above.
2. Confirm all `/internal/metrics` targets are scraped by Prometheus.
3. Run `tools/loadtest/im_loadgen.py` from one or more load generator hosts.
4. Scale gateway until TCP connection target is reached.
5. Scale command-api and Kafka partitions until write target is reached.
6. Scale query-api until conversation/history P95 is stable.
7. Pause one `stream-consumer`, verify lag rises, resume it, verify lag recovers.


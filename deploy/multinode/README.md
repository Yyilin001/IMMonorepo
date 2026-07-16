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
- `valkey`: six nodes, three primaries plus one replica per primary
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

Copy the inventory template once for each application node and edit the local
identity fields. The Cell endpoint maps must remain identical across all nodes
in that Cell, while `IM_NODE_SUFFIX`, `IM_GATEWAY_NODE_ID`, and
`IM_COMMAND_NODE_ID` identify the local host.

```bash
cp deploy/multinode/inventory.example.env deploy/multinode/inventory.node-a.env
cp deploy/multinode/inventory.example.env deploy/multinode/inventory.node-b.env
vim deploy/multinode/inventory.node-a.env
vim deploy/multinode/inventory.node-b.env
```

Render environment files:

```bash
bash deploy/multinode/render_env.sh \
  deploy/multinode/inventory.node-a.env \
  /tmp/imserver-multinode-node-a

bash deploy/multinode/validate_inventory_set.sh \
  deploy/multinode/inventory.node-a.env \
  deploy/multinode/inventory.node-b.env

# Cross-Cell gate. Supply every node inventory from every Cell. It verifies
# the shared control plane and rejects physical conversation-shard reuse.
bash deploy/multinode/validate_multicell_inventory_set.sh \
  deploy/multinode/inventory.cell-a-node-a.env \
  deploy/multinode/inventory.cell-a-node-b.env \
  deploy/multinode/inventory.cell-b-node-a.env \
  deploy/multinode/inventory.cell-b-node-b.env

# Full deployment gate: multi-Cell topology validation plus production role
# preflight for every supplied inventory.
bash deploy/multinode/preflight_multicell_inventory_set.sh \
  --require-ha \
  deploy/multinode/inventory.cell-a-node-a.env \
  deploy/multinode/inventory.cell-a-node-b.env \
  deploy/multinode/inventory.cell-b-node-a.env \
  deploy/multinode/inventory.cell-b-node-b.env

# Real deployment gate: strict secret validation is enabled by default.
bash deploy/multinode/preflight_inventory_set.sh \
  deploy/multinode/inventory.node-a.env \
  deploy/multinode/inventory.node-b.env
```

Copy the generated files to each node:

```text
/tmp/imserver-multinode-node-a/common.env
/tmp/imserver-multinode-node-a/roles/<role>.env
/tmp/imserver-multinode-node-a/preflight/<role>.env
```

The generated `preflight` files merge `common.env` with the selected role file;
they are input to `IMServer/scripts/production_env_preflight.sh`, not files to
install on hosts. Run `bash deploy/multinode/render_env_test.sh` to validate the
template and its complete generated consumer topology.

Install the existing systemd units on each host, but keep only the unit for that
host's role enabled. Example gateway node:

```bash
sudo IMSERVER_ENABLE_DEFAULT_UNITS=false bash deploy/ubuntu/50_install_systemd_units.sh
sudo install -d -m 0750 /etc/imserver /etc/imserver/roles
sudo cp common.env /etc/imserver/common.env
sudo cp roles/gateway.env /etc/imserver/roles/gateway.env
sudo systemctl enable --now imserver-gateway
```

For a stream consumer, copy the generated group file unchanged to
`/etc/imserver/roles/`, then start the matching instance. For example:

```bash
sudo cp roles/stream-consumer-realtime_delivery_consumer.env \
  /etc/imserver/roles/stream-consumer-realtime_delivery_consumer.env
sudo systemctl enable --now imserver-stream-consumer@realtime_delivery_consumer
```

Enable exactly one consumer group per process.

On a multi-node consumer host, configure the operational audit with the enabled
instance suffixes, for example:

```bash
AUDIT_STREAM_CONSUMER_INSTANCE_UNITS=realtime_delivery_consumer \
  sudo bash deploy/ubuntu/77_operational_audit.sh
```

For stream consumers, deploy one role env per group:

```text
stream-consumer-summary_projection_consumer.env   IM_STREAM_CONSUMER_GROUPS=summary-projection-consumer
stream-consumer-realtime_delivery_consumer.env    IM_STREAM_CONSUMER_GROUPS=realtime-delivery-consumer
stream-consumer-domain_delivery_consumer.env      IM_STREAM_CONSUMER_GROUPS=domain-delivery-consumer
stream-consumer-changes_log_consumer.env          IM_STREAM_CONSUMER_GROUPS=changes-log-consumer
stream-consumer-search_index_consumer.env         IM_STREAM_CONSUMER_GROUPS=search-index-consumer
stream-consumer-notification_consumer.env         IM_STREAM_CONSUMER_GROUPS=notification-consumer
stream-consumer-repair_replay_consumer.env        IM_STREAM_CONSUMER_GROUPS=repair-replay-consumer
```

Each process must run exactly one group in production.

## Capacity validation checklist

1. Deploy the role split above. Do not omit `domain-delivery-consumer` or
   `realtime-delivery-consumer`; they own durable owner delivery and active
   realtime fanout respectively.
2. Confirm all `/internal/metrics` targets are scraped by Prometheus.
3. Run the multi-device release gate from a trusted host:

   ```bash
   cd IMServer
   ./scripts/multidevice_release_gate.sh \
     --env-file LoadTests/staging-baseline.env \
     --profile staging-baseline \
     --staging-baseline \
     --require-redis
   ```

4. Run `tools/loadtest/im_loadgen.py` from one or more load generator hosts for HTTP and mixed read/write pressure.
5. Scale gateway until TCP connection target is reached.
6. Scale command-api and Kafka partitions until write target is reached.
7. Scale query-api until conversation/history P95 is stable.
8. Pause one `stream-consumer`, verify lag rises, resume it, verify lag recovers.

Every node inventory must declare `IM_AVAILABILITY_ZONE`. A Cell rendered from
two or more inventories must span at least two values; the inventory validator
rejects same-zone Gateway/command replicas before deployment. This is a
placement guardrail, not application routing: keep Cell IDs, shard ownership,
and private ingress maps independent from the availability-zone label.

## Kafka Topic Specification

Every multi-node inventory declares the event and dead-letter topic name,
partition count, replication factor, `min.insync.replicas`, and retention.
The inventory validators require the complete specification to match across all
nodes and Cells. Before traffic, run the reconciler in dry-run mode:

```bash
bash deploy/multinode/reconcile_kafka_topics.sh --validate deploy/multinode/inventory.cell-a-node-a.env
```

It validates the desired specification without connecting to Kafka. To compare
or create topics on a Kafka-compatible cluster, provide a private bootstrap
endpoint and the vendor's CLI-compatible `kafka-topics.sh` and
`kafka-configs.sh` paths, then use `--apply`. Existing topics are never altered
by this tool: a partition, replication, retention, or `min.insync.replicas`
drift fails closed. Increasing partitions can remap a conversation key, so use
a reviewed new-topic generation or Cell migration rather than an in-place
partition change.

Multi-device release details live in `IMServer/docs/im-multidevice-release-gate.md`.

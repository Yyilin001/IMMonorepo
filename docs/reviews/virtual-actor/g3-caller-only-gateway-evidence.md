# G3 caller-only Gateway TCP verification

Status: runner prepared; the full Linux run must use an `IMV2ServerApp` binary containing the caller-only Factory fix. No execution is claimed here yet.

Run the existing disposable application stack with `--remote-gateway`:

```sh
python3 IMV2/scripts/test_v2_virtual_actor_application_stack.py \
  --remote-gateway \
  --context colima-imv2-vapor5 \
  --scratch-dir /absolute/exclusive-linux-swiftpm-scratch
```

If the four Linux Release products were already built from **business-identical source and Package.resolved**, omit `--scratch-dir` and provide `--products-dir /absolute/readonly/release` plus `--products-metadata /absolute/metadata.json`. The metadata must contain `sourceSHA`, `lockfileSHA256`, and a `products` object mapping each product name to its SHA-256; a previous successful application-stack `result.json` with `revision`/`packageResolvedSHA256` is also accepted. The runner requires that source commit locally, checks `git diff` from it through the current checkout over package/production sources, vendor, Core, compression and SQL inputs, rejects staged/unstaged or untracked changes in those inputs, verifies the lockfile and every product digest, and records **both** the binary source SHA and runner SHA. This permits a later script/doc-only change without recompiling seven products while rejecting a changed business binary.

The mode creates one real `IMV2ServerApp` `actor-host` container with a Host ID and separate `IMV2ServerApp` `gateway` container whose Actor configuration has `hostID: null`; Account is also caller-only. Gateway retains its service permissions for background maintenance, trusted content review, and special-account audit without receiving lease authority. The Actor host has no published host port. The existing Account HTTPS, Gateway TLS/protobuf direct send and recipient room-log read, Operator disable, and Account nickname/invite/media HTTP checks run unchanged. Gateway and Actor host container IDs and start timestamps are recorded, so the same process cannot satisfy both roles.

Immediately after the black-box direct send/read, a PostgreSQL query starts from every persisted message room and left-joins `im_v2.room_activation_leases`. It requires at least one message room and requires every such room's **live** lease `host_id` to equal the private topology's `actor-host` Host UUID. `result.json` records room IDs, epochs and host ID but no credentials or message bodies. This SQL condition is stronger than an HTTP readiness check: the Gateway cannot pass merely by accepting TCP while secretly hosting its own room. The run uses random loopback published ports, a unique Compose project, private generated keys and database, and cleans only its own resources.

After execution, append the exact source SHA, Linux product SHA-256 values, result directory and phase outcomes here. A successful run proves the G3 Gateway TCP send/read topology and persistent lease ownership; it does not alone establish relative throughput/p95/p99 parity or the complete 21-fault matrix.

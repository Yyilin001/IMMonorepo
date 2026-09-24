# G3 caller-only Gateway TCP verification

Status: **Linux Release end-to-end passed** on 2026-09-24. Static validation passed Python compilation, the three-node host/caller/worker permission checks, and `docker compose config --quiet` with the generated independent `actor-host` service.

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

## Executed result

The passing run used verified prebuilt products and did **not** rebuild Swift:

```sh
python3 IMV2/scripts/test_v2_virtual_actor_application_stack.py \
  --remote-gateway --context colima-imv2-vapor5 \
  --products-dir /Users/yyl/.codex/virtual-actor-builds/candidate-release-wiring/products \
  --products-metadata /Users/yyl/.codex/virtual-actor-builds/candidate-release-wiring/result.json
```

Evidence: `/Users/yyl/.codex/virtual-actor-builds/application/run-f07027826d80448d951e262188aed4d9/result.json`, `smoke.log`, `actor-http-smoke.log`, `startup.log`, `cleanup.log`. Exit code 0; `ACTOR_APPLICATION_STACK_OK`; private directory removed. Runner revision `7da66de75841eb70de59bce130efa6769ffa05d0`; business binary source `5765185e21ce36fa192ceda782b4eaa3906aa488`; Package.resolved SHA-256 `3af1e16190f46bdd8fad3de86c6b386dc196443291463355bf36edb62b7fd15c`. `result.json` records the four product digests, fixed Swift image and distinct boot/container identities. The Actor Host was container `703b5bdbd80f…`, Gateway was `821c42ed272d…`; Gateway's validated configuration had no Host ID. A direct message room `44a2c8fa-4d33-45e2-9149-1bb0c213d4e3` had a **live epoch-1 lease** held by Actor Host `0a61b37f-1863-4e5d-9d1b-f50b6fd98dd0`, matching the private topology and differing from the Gateway caller. `smoke.log` records the authenticated TCP/TLS direct send and recipient room-log read, Operator disable, and TLS 1.3; `actor-http-smoke.log` records `ACTOR_HTTP_SMOKE_OK nickname invitation media_send_download`.

The generated Compose project `imv2-va-app-35a7d28a58d5` was removed; explicit post-run checks found zero containers, networks, or volumes with its project label. An earlier run failed at the **test assertion only** because PostgreSQL returned the UUID in uppercase while the generated topology stored lowercase; Gateway send/read and the actual lease owner already matched. The runner now compares UUIDs case-insensitively, and the passing run above used the committed fix.

This proves the G3 Gateway TCP send/read topology and persistent lease ownership. It does not establish relative throughput/p95/p99 parity or the complete 21-fault matrix.

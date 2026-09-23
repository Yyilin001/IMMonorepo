# V1 fault harness handoff

W0 status: the topology and network injection are implemented; no Actor host, probe or persistent-result assertions exist yet. `bash IMV2/scripts/run_v2_virtual_actor_faults.sh config` validates the Compose topology. `up` exits 78 until real host/probe images and an integrated contract are supplied. `run` exits 78 until the scenario coordinator and result adapter are implemented. Neither exit is an acceptance result.

`IMV2/docker-compose.virtual-actor-tests.yml` has two separate host containers, a probe and three PostgreSQL processes. Each host has its own private link to each database. The two hosts share only the `actor` network, so `isolate host-a peer` preserves its database connections, while `isolate host-a owner-primary` or `isolate host-a control` changes only one host's selected DB link. No host ports are published. The probe's `/fault-control` bind mount is the test-only stage channel; the production server has no new debug route. The fault script verifies Docker's actual before/after network attachment and fails when a requested transition did not occur.

Integration owner contract: build a Linux image with a long-running `IMV2ServerApp` at `/usr/local/bin/IMV2ServerApp` and an image with a long-running `IMV2VAFaultProbe` at `/usr/local/bin/IMV2VAFaultProbe`. Wire the Compose `IMV2_VA_FAULT_*` values to actual server database and Actor transport configuration; Actor transport must advertise/use only `host-a:7337` or `host-b:7337` on the `actor` network. Implement the probe's `file-v1` barrier protocol from `fault-scenarios.json`, where each barrier is emitted only after the real host reaches that exact operation stage. The probe must wait for the matching release file before allowing that operation to continue. Supply a JSON contract with `schemaVersion:1`, `status:"integrated"`, the two executable paths, `barrierProtocol:"file-v1"` and `actorNetworkAddressOnly:true`. Set `IMV2_VA_FAULT_HOST_IMAGE`, `IMV2_VA_FAULT_PROBE_IMAGE`, `IMV2_VA_FAULT_CONTRACT_FILE` and a new empty `IMV2_VA_FAULT_ARTIFACT_DIR` outside the repository before `up`.

The coordinator can then call `inject <scenario-id>`: it waits for an exact, valid operation barrier, disconnects the target network, records the observed Docker transition under `injections/`, and atomically writes the matching release file. `restore <host> <link>` reconnects the selected link. A final scenario runner still needs to check the durable database result, idempotent retry, boot/epoch transitions and exit codes against the task-card matrix. Its report must include revision, lockfile hash, image digests, boot IDs, room and operation IDs, activation epoch, stage, persistent result and exit codes, with no credentials or message body. Until those checks exist, successful `up` or `inject` is only infrastructure evidence.

The namespace defaults to `imv2-va-v1`; `down` keeps volumes, while `purge` removes volumes only with `IMV2_VA_FAULT_DATABASE_IS_DISPOSABLE=1`. The Linux build/test wrapper uses a separate `imv2-va-v1-linux` project, preserving the existing isolated test Compose behavior. Neither command starts the fixed-port local-account stack.

Both scripts accept a per-invocation `DOCKER_CONTEXT` and never run `docker context use`. On a VM whose Docker volume partition is constrained, set both `IMV2_VA_LINUX_CACHE_DIR` and `IMV2_VA_LINUX_SCRATCH_DIR` to distinct absolute host paths. The wrapper rejects paths inside the source tree, ancestors containing it, symlinks to either, and cache/scratch nesting. The optional Compose overlay binds only `/tmp/cache` and `/tmp/swiftpm`; `/workspace` stays read-only. For example:

```bash
DOCKER_CONTEXT=colima-imv2-vapor5 \
IMV2_VA_LINUX_CACHE_DIR="$HOME/.cache/imv2-va-v1/cache" \
IMV2_VA_LINUX_SCRATCH_DIR="$HOME/.cache/imv2-va-v1/scratch" \
bash IMV2/scripts/run_v2_virtual_actor_linux.sh build IMV2ServerApp
```

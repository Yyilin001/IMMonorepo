# G5 Linux functional evidence: room recovery and bounded handshake

Source: `99792d9e7dd2f0bd3134e8bd3b72ce7d868665e5` (based on integrated candidate `888fed4b43493e9cd90f600d3f0a078659ce63c3`). This is functional evidence for that source, not a capacity measurement or a claim about later integrated commits.

## Reproduce

On macOS with Docker context `colima-imv2-vapor5`, the following command exited `0`:

```sh
DOCKER_CONTEXT=colima-imv2-vapor5 \
VA_G4_MODE=linux \
VA_G4_LINUX_CLIENT_FIRST=1 \
VA_G4_LINUX_SCRATCH_DIR=/Users/yyl/.codex/virtual-actor-builds/p0 \
bash IMV2/scripts/test_v2_virtual_actor_business_probe.sh
```

The runner uses pinned `swift:6.4-jammy@sha256:a6053d2de72091906bfa064f76f145e3f28830664cae250e1b84aa8c499a8ee6`, mounts source read-only, and builds `VirtualActorBusinessProbe` in a separate host-bind scratch with `-c debug -j 2`. It creates a private Docker network, task-owned PostgreSQL 16 container, temporary CA and signing identities, and two separate Linux host/client process containers. It removes only those task-owned containers/network and signing secrets. `VA_G4_MODE` defaults to the original native-process mode; the default native command below also exited `0`:

```sh
DOCKER_CONTEXT=colima-imv2-vapor5 bash IMV2/scripts/test_v2_virtual_actor_business_probe.sh
```

With `VA_G4_LINUX_CLIENT_FIRST=1`, the client enters its first request before the host exists. The runner checks that `va-host` has no address in the private Docker subnet, then starts the host. This Colima environment returned a synthetic `198.18.0.45` address for the absent name, so an NXDOMAIN-only assertion would have been invalid. After first send/log/subscription success, the runner SIGKILLs the host, waits for the lease to expire according to the database clock, starts a new host at the same DNS name and port, then checks replay and stale-token fencing.

The exact-source evidence is in `/Users/yyl/.codex/virtual-actor-builds/g5-runs/imv2-va-g4-1790176099-85737-evidence/`. `source-sha.txt` matches the SHA above; `environment.txt` records Linux/client-first and the image digest. `client.log` contains `G4_SEND_AND_LOG_OK epoch=1` and `G4_REPLAY_AND_SQL_FENCE_OK epoch=2`. `lease-expiry.txt` records the database-clock expiry. `result.json` records different host incarnations, membership revision `1` and subscription high watermark `1` across recovery, exactly one message row for the repeated client ID, and `staleBusinessWriteRejected: true`. `final-sql.txt` independently records activation epoch `2` and message count `1`.

## Actor checks and failure fixed

Linux Debug `swift test --scratch-path /build -c debug -j 2 --filter V2RoomClusterDiscoveryTests` exited `0`: four tests, with five cases because the handshake regression covers both a TCP peer that closes before responding and a peer that keeps the connection open. The latter waited for the initiating handshake's ten-second watchdog to close the channel before binding the replacement host on the same port. Log: `/Users/yyl/.codex/virtual-actor-builds/p0/g5-evidence/linux-cluster-discovery-close-stall-final.log`.

The selected Linux Debug Host/Lane/Directory/Reservation/Budget suites passed `49/49`, and signed authentication passed `11/11` using `--filter 'V2RoomActivationHostTests|V2RoomTurnLaneTests|V2RoomDirectoryTests|V2RoomReservationCoordinatorTests|V2RoomCommandBudgetTests|V2ActorAuthenticationTests'`. Log: `/Users/yyl/.codex/virtual-actor-builds/p0/g5-evidence/linux-key-actor-tests.log`. `bash -n` and `git diff --check` also passed. The native business probe passed on the same source changes; log: `/Users/yyl/.codex/virtual-actor-builds/p0/g5-evidence/native-business-probe-regression.log`.

Before the transport fix, an actual Linux restart run failed after the old host was SIGKILLed: repeated joins logged `Handshake in other state: inFlight` until the caller timed out. The vendor initiator now reports channel close/error or a missing response once, and `ClusterShell` removes the failed/rejected outbound handshake so a later join can reach a new incarnation. NIO's existing Happy Eyeballs `connectTimeout` covers DNS resolution and TCP connection; the new watchdog covers the interval after connection. The failed diagnostic run remains at `/Users/yyl/.codex/virtual-actor-builds/g5-runs/imv2-va-g4-1790174131-53973-evidence/` and is not counted as a pass.

This run did not build all production Apps in Release, run the Account/Gateway/Operator HTTP stack, or sample performance. The shared Colima context has 4 CPUs and 12 GiB, so it is not an eligible capacity-baseline window under the V1 baseline protocol. The integrated candidate after this source must rerun its own Linux checks.

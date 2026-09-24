# P0: DistributedCluster compatibility evidence

Status: **G0 passed for the compatibility probe**. This is a transport and resource-lifecycle probe, not a Room Virtual Actor implementation or a production security approval.

## Fixed dependency and build graph

- Clean source baseline: `f1cdd78d6a21bf0ae23da627c0710c65115236aa`; P0 branch started at `8839f6709e961853d377a2b60ba7231c325fc6b4`. No uncommitted code from the original checkout was used.
- `swift-distributed-actors` is fixed to `50e789fbb6db9a9869a60b1915e659bd752e1d42` (upstream 2026-06-22 main), with product `DistributedCluster`. `Package.resolved` adds that revision plus `swift-cluster-membership 0.4.0`, `swift-service-discovery 1.5.0`, and `swift-backtrace 1.3.5`. All existing pins, including Vapor `5.0.0-beta.2`, FluentKit `1.57.0`, SwiftNIO `2.101.3`, Logging `1.14.0`, Collections `1.6.0`, Atomics `1.3.1`, Crypto `4.5.2`, and ServiceLifecycle `2.11.0`, remain unchanged. The local `Vendor/postgres-nio` is unchanged.
- Upstream tag `1.0.0-beta.3` (`d816a10b70a6d537b2aa666ff735888b7ba40ab4`) was rejected by the real `swift package resolve`: it requires `swift-async-algorithms 0.0.3..<1.0.0`, whereas ServiceLifecycle `2.11.0` requires `1.1.3..<2.0.0`. The fixed main revision resolves with exit code 0.
- Linux image: `swift:6.4-jammy@sha256:a6053d2de72091906bfa064f76f145e3f28830664cae250e1b84aa8c499a8ee6`, on Docker context `colima-imv2-vapor5`. The source mount was read-only; SwiftPM scratch was bind-mounted from `/Users/yyl/.codex/virtual-actor-builds/p0`. The real `IMV2Server` and `IMV2ServerHTTP` targets compiled as dependencies of the Release probe, including the existing Vapor and PostgreSQL vendor graph. Build command and exit code:

  ```sh
  docker --context colima-imv2-vapor5 run --rm --name imv2-va-p0-build \
    -v "$WORKTREE:/repo:ro" -v /Users/yyl/.codex/virtual-actor-builds/p0:/build \
    -w /repo/IMV2Server \
    swift:6.4-jammy@sha256:a6053d2de72091906bfa064f76f145e3f28830664cae250e1b84aa8c499a8ee6 \
    swift build --scratch-path /build -c release --product VirtualActorCompatibilityProbe -j 2
  # exit 0
  ```

  The full graph emitted the pre-existing SwiftPM warning that local and remote `postgres-nio` have the same package identity; it did not fail. No dependency or vendor workaround was applied.

  The same Linux image and scratch path also built the unmodified production `IMV2ServerApp` product with `swift build --scratch-path /build -c release --product IMV2ServerApp -j 2`; exit code **0** (`evidence/app-release-build.log`).

## Two-process Linux Release run

Run `IMV2Server/Tests/VirtualActorCompatibilityProbe/run-linux-release.sh` from the repository root. It uses only Compose project `imv2-va-p0`, two separate Linux OS processes in separate `host` and `client` containers, and a dedicated PostgreSQL 16 container. It generates short-lived test CA/certificates and Ed25519 keys under `/Users/yyl/.codex/virtual-actor-builds/p0/evidence`, runs the Release binary, then removes only this project's containers/network/database. The final run exited **0** with `P0_PROBE_OK` in `run-4.log`.

Observed assertions in the saved logs:

| Evidence | Observation |
| --- | --- |
| `client.log`: `REMOTE_OK` | Client decoded an ActorID emitted by the host and invoked a real remote `distributed func` with the production `RoomID` type and Codable request/result. |
| `client.log`: `DOMAIN_ERROR_OK rejected`, `payloadTooLarge`, `protocolMismatch` | Registered Codable domain error crossed the wire with its code; a 65,537-byte request and wrong protocol version failed explicitly. |
| `client.log`: `TIMEOUT_OK RemoteCallError` | A 150 ms remote-call budget failed while the host method delayed for 1 second. |
| `negative-tls.log`: `UNTRUSTED_TLS_REJECTED` | A separate client trusting a different CA could not invoke the host. |
| `client.log`: `SIGNED_CALL_OK`, `TAMPER_REJECTED`, `WRONG_SERVICE_REJECTED` | The distributed inbound adapter accepted a signed typed envelope, rejected changed payload bytes and a false service identity, and the client verified the host-signed response. |
| `client.log`: `STALE_REF_FAILED`, `NEW_REF_OK` | After host container restart at the same address, the old physical ActorID failed within the 2 s remote-call budget. The new ActorID and a fresh `cluster.join` reached the new process; the returned host incarnation changed. |
| `host-old.log`, `host-new.log`: `DB_READY`, `HOST_READY`, `HOST_DRAIN`, `HTTP_STOPPED`, `ALL_STOPPED` | Each host ran the cluster, a live PostgreSQL pool and Vapor HTTP endpoint in one process. `/health` performed `SELECT 1` through that pool. SIGTERM drained HTTP before database resources, the borrowed database EventLoopGroup, and ClusterSystem closed. |
| `host-startup-failure.log`: `PROBE_FAILURE` | Invalid database endpoint produced nonzero process exit after cleanup of the created ClusterSystem/database resources. |
| `client.log`: `CLIENT_STOPPED` | Caller ended after the remote-loss/rejoin sequence. |

The upstream `ClusterSystem` creates and owns its own EventLoopGroup in `init(settings:)`, overwriting the supplied `settings.eventLoopGroup`. Vapor/Fluent use a separate EventLoopGroup in this probe. Production lifecycle wiring must preserve that ownership split and close each resource once. This was verified in the process run; sharing one group is not an available public integration path at this revision.

The client needed an explicit new `cluster.join` after the old node was downed. Merely resolving the new ActorID timed out in the first run. `RoomRef` relocation therefore needs a bounded join/association step before calling the new physical reference. The successful final run includes it.

## Trust and protocol boundary for C0/R3

The pinned transport accepts `ClusterSystemSettings.tls: NIOSSL.TLSConfiguration`. The probe used a private CA and client/server certificates. On the server side, upstream changes `.fullVerification` to `.noHostnameVerification` because it does not yet know the peer's name; the public handshake path does not expose a peer-certificate-to-claimed-`Cluster.Node` binding callback. The outgoing client verifies the target host name. A cluster node claim must not become an application service principal.

The runnable adapter demonstrates the implementable application boundary: a trusted `serviceID -> role/public signing key` map, Ed25519-signed typed request body containing service ID, role, target host incarnation, attempt ID, method, `RoomID`, complete payload, protocol version, and remaining budget. The distributed actor verifies it before business execution. Its typed response or error body is signed by the host key and binds the same attempt ID and host incarnation; the caller verifies it against the expected host key. The probe uses canonical sorted-key JSON to make the signed bytes deterministic and has positive/tamper/false-service checks. C0 should freeze a versioned canonical encoding, the trust-map/configuration port, response/error envelope, and replay/attempt deduplication with bounded budgets. R3 must apply the check to every externally callable distributed method, not only send. The test keys are ephemeral and shared only by the isolated probe volume; production key distribution must keep private keys separate.

The 65,537-byte case proves an explicit application rejection after transport decoding. It does **not** establish a pre-deserialization frame limit. C0/R3 still need an outbound encoded-size preflight and a bounded inbound transport/admission limit before accepting arbitrary cluster traffic. Likewise, this P0 probe does not supply persistent room activation, transaction fencing, or production capacity evidence.

Primary upstream code inspected at the pinned revision: [ClusterSystem resource ownership](https://github.com/apple/swift-distributed-actors/blob/50e789fbb6db9a9869a60b1915e659bd752e1d42/Sources/DistributedCluster/ClusterSystem.swift), [TLS settings](https://github.com/apple/swift-distributed-actors/blob/50e789fbb6db9a9869a60b1915e659bd752e1d42/Sources/DistributedCluster/ClusterSystemSettings.swift), [transport TLS and handshake pipeline](https://github.com/apple/swift-distributed-actors/blob/50e789fbb6db9a9869a60b1915e659bd752e1d42/Sources/DistributedCluster/Cluster/Transport/TransportPipelines.swift).

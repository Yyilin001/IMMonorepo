# G2/G5: two live Hosts, lease takeover, and stale-token fencing

Run `DOCKER_CONTEXT=colima-imv2-vapor5 VA_G6_NATIVE_SCRATCH_DIR=/tmp/va-receipt-metrics-build python3 IMV2/scripts/test_v2_virtual_actor_multihost_probe.py` from the repository root. The runner creates its own PostgreSQL 16 container and network, installs the canonical schema and a two-room fixture, builds `VirtualActorBusinessProbe` with `-j 2`, and leaves evidence in the printed directory. It removes only its own containers, network, and TLS secrets. `VA_G6_MODE=linux` uses the same phase barriers with four process containers; it requires a separate `VA_G6_LINUX_SCRATCH_DIR` and was **not executed** in this native run.

The probe exercises two related races. First, two actual Host OS processes use distinct configured Host IDs and call the production PostgreSQL activation store for an unused room. A dedicated SQL session holds that room's row lock. The runner observes **two distinct PostgreSQL backends blocked in the `FOR NO KEY UPDATE` acquisition** before terminating the lock holder. This proves the acquire calls overlap; merely starting two clients would not prove that both Hosts reached the persistence fence. It requires one `acquired`, one `occupied`, identical tokens, and one epoch-1 lease row. The direct store race is a test-only diagnostic; it does not claim both Hosts restored an actor for this diagnostic room.

Next, two real client processes with opposite Host candidate preferences cross a file barrier while the business room has no lease. Both send the same stable `clientMessageID` through `V2RoomRef`; the runner requires accepted and idempotent results with one `messageID` and one live lease. It sends `SIGSTOP` to the actual lease holder without closing its database connections, waits for `expires_at <= clock_timestamp()` from PostgreSQL, and sends the original operation through a new client preferring the surviving Host. It requires the new Host ID, epoch increment, an idempotent result, and one message row. After `SIGCONT`, the original Host process itself attempts renewal, release, and a new scoped SQL message write with its old token. All three must reject while the replacement lease and message row remain intact.

Native run on 2026-09-23 from base `7a72b64d` passed with evidence `/private/tmp/imv2-va-g6-69357-8567c0ae-evidence`:

| Barrier or assertion | Observed evidence |
| --- | --- |
| Concurrent first acquire | PostgreSQL backend 111 waited on tuple lock and backend 112 on transaction-ID lock; Host B acquired, Host A saw occupied; one lease row at epoch 1. |
| Concurrent client send | One accepted and one idempotent outcome shared message `01A0CEE0-5713-7052-A087-C8EA6C9DABA9`; first business lease belonged to Host B at epoch 1. |
| Paused owner and takeover | PostgreSQL clock marked Host B's epoch-1 lease expired while its process was stopped; Host A acquired epoch 2. |
| Resume and replay | The original operation replayed idempotently on Host A; Host B's old-token renew, release, and scoped business write were rejected; final message count and distinct message ID count were both 1. |

The native run did not isolate Host-to-Host transport while keeping each Host connected to PostgreSQL. `SIGSTOP` tests the stronger stale-owner case where an unreachable process retains its connections and later resumes, but is not itself a peer-only network partition. A peer-only partition needs a dual-network Linux setup and a dedicated replay of these barriers; it remains open.

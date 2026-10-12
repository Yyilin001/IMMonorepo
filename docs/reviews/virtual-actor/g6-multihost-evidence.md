# G2/G5: two live Hosts, lease takeover, and stale-token fencing

历史 SQL 房间租约方案的 G6 验收记录。对应启动器已删除，不再提供基于租约过期的 pause/接管/unpause 执行入口。以下观测保留原始含义，不作为当前原生 Actor 的崩溃排除或自动接管证据。当前状态见[房间分布式 Actor 合同](../room-virtual-actor-contract.md)。

The probe exercises two related races. First, two actual Host OS processes use distinct configured Host IDs and call the production PostgreSQL activation store for an unused room. A dedicated SQL session holds that room's row lock. The runner observes **two distinct PostgreSQL backends blocked in the `FOR NO KEY UPDATE` acquisition** before terminating the lock holder. This proves the acquire calls overlap; merely starting two clients would not prove that both Hosts reached the persistence fence. It requires one `acquired`, one `occupied`, identical tokens, and one epoch-1 lease row. The direct store race is a test-only diagnostic; it does not claim both Hosts restored an actor for this diagnostic room.

Next, two real client processes with opposite Host candidate preferences cross a file barrier while the business room has no lease. Both send the same stable `clientMessageID` through `V2RoomRef`; the runner requires accepted and idempotent results with one `messageID` and one live lease. Native mode sends `SIGSTOP`/`SIGCONT`; Linux mode uses Docker pause/unpause on the actual lease holder. Both retain its database connections, wait for `expires_at <= clock_timestamp()` from PostgreSQL, and send the original operation through a new client preferring the surviving Host. The new Host must hold the next epoch and return the idempotent result with one message row. After resumption, the original Host process itself attempts renewal, release, and a new scoped SQL message write with its old token. All three must reject while the replacement lease and message row remain intact.

Native run on 2026-09-23 from base `7a72b64d` passed with evidence `/private/tmp/imv2-va-g6-69357-8567c0ae-evidence`:

| Barrier or assertion | Observed evidence |
| --- | --- |
| Concurrent first acquire | PostgreSQL backend 111 waited on tuple lock and backend 112 on transaction-ID lock; Host B acquired, Host A saw occupied; one lease row at epoch 1. |
| Concurrent client send | One accepted and one idempotent outcome shared message `01A0CEE0-5713-7052-A087-C8EA6C9DABA9`; first business lease belonged to Host B at epoch 1. |
| Paused owner and takeover | PostgreSQL clock marked Host B's epoch-1 lease expired while its process was stopped; Host A acquired epoch 2. |
| Resume and replay | The original operation replayed idempotently on Host A; Host B's old-token renew, release, and scoped business write were rejected; final message count and distinct message ID count were both 1. |

The native run does not isolate Host-to-Host transport. Linux mode adds one shared Actor network and one private DB network per Actor process; PostgreSQL joins all four DB networks. The configured `va-host-*` aliases exist only on the Actor network, while every process resolves `va-pg` on its private DB link. After the initial business-room lease, the runner disconnects the owning Host from the Actor network only. It verifies both network attachments before, the owner's DB-only attachment during, and the original Actor IP after reconnection. A verified TLS 1.3 handshake to the peer must succeed before the cut and fail during it. The owner must still read PG and renew its original token; the survivor must serve a different room but fail to use the isolated owner's room, while PG shows the same unexpired lease, epoch, and one business message. Reconnecting the original Actor IP must recover the same idempotent result without a second write. These checks run before the pause/expiry/takeover case, so peer-only partition and process suspension are independently exercised.

Linux run on 2026-09-23 from base `86f0c4d9` passed with evidence `/Users/yyl/.codex/virtual-actor-builds/g6-runs/imv2-va-g6-18289-af888ee2-evidence`:

| Barrier or assertion | Observed evidence |
| --- | --- |
| Host collision | Backends 106 and 107 both waited in first-acquire SQL; one `acquired`, one `occupied`, one epoch-1 lease row. |
| Peer-only cut | Host A changed from Actor+private-DB attachments to private-DB only. Its verified peer TLS handshake changed from TLS 1.3 success to EOF; `va-pg` continued resolving to its private DB-network IP. Colima's external DNS synthesized `198.18.0.16` for the disconnected peer name, so `getent` success alone was not used as proof of reachability. |
| DB and writer fence | Host A read PG and renewed its epoch-1 token. Host B accepted a message in a different room; a new client could not use A's room. PG kept A's same unexpired lease and exactly one message in each room. |
| Rejoin | Actor IP `172.20.0.2` was restored; the original operation returned its idempotent result on Host A at epoch 1, with one primary-room row. |
| Suspension and takeover | After Docker pause, PG clock marked A's lease expired; Host B took epoch 2 and replayed idempotently. After unpause, A's stale renew, release, and scoped business write were rejected. |

The Linux run's task-owned containers and five networks were absent after cleanup. A second native run passed after these additions at `/private/tmp/imv2-va-g6-2856-1e5bddf5-evidence`.

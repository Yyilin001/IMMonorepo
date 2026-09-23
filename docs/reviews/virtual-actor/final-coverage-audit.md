# Room Virtual Actor 最终合同、写者与故障证据审查

审查代码基线 `fd979e68`，并核对集成分支 `8231a079` 新增的 `a13d246d` 双房间 COMMIT ACK 丢失证据。此文是只读审查，不把测试源码的存在等同于执行通过，也不把计划文档的旧状态等同于当前代码缺口。验收条件以[并行方案 G1–G5](../../../IMV2/docs/00-foundation/virtual-actor-parallel-plan.md)及[任务卡的 21 项故障矩阵](../../../IMV2/docs/00-foundation/virtual-actor-task-cards.md)为准。等级：**fake** 指进程内替身；**PG** 指真实 PostgreSQL 与生产 store/批处理器；**进程** 指多个实际 OS 进程；**Linux 栈** 指 Linux Release 应用或多 Host 容器。下表未特别说明的测试名称表示源码中的测试，执行结果只从所引证据文件取得。

## 2026-09-24 集成后的差距处置

下表是对本次审查的后续处置；后文保留审查时的原始判断，以便核对当时证据，不能再把已关闭的条目当成当前缺陷。

再次按原方案逐句核对 `5c2d5509` 后，除五类相对性能和 #19 单 owner 查询故障之外，尚须取得以下直接证据：#11 生产 Host 的热房间及节点队列饱和、健康房间前进与资源回落；#17 真实 PostgreSQL 重启；#18 生产 Host 在满队列和待处理 shared batch 下排空；#21 review/import 各自临界点接管；最终源码的一次完整 Linux required checks 全绿记录。这是该提交的差距清单；后续进展必须以新增执行证据逐项关闭，不能由代表路径提前标记完成。原 #7 的真实成功 COMMIT ACK 截断已处于“DB 提交与 RPC 返回之间”，不额外要求 Actor 网络帧丢失；#13 的真实 PG 双房间 unknown 与 Host 退役分层证据保留，不增加无原文要求的同场组合。已有真实 OS SIGTERM→App drain 的证据，与待补的生产 Host 队列/batch 状态验证分别证明信号接线与排空行为。

| 原差距 | 新证据与当前边界 |
| --- | --- |
| 当前合同/状态未登记 | [当前 Room Actor 合同](../room-virtual-actor-contract.md)已进入正式合同索引；系统地图、schema 53 与三个 App 的组合已登记。G1 的 hot 性能预算已由三轮 main 冻结，其他四类仍待实测冻结。 |
| G3 Gateway 自身也是 Host | [caller-only Gateway Linux 应用栈](g3-caller-only-gateway-evidence.md)通过：Gateway 无 Host 身份，真正 TCP/TLS send/read 经过独立 Host，数据库 live lease 与独立 Host UUID 一致。随后[真实远程合批](g3-remote-batch-evidence.md)也通过：两 TLS 连接、两房间的 8 请求合为 4 原子批，PG 连续序号、唯一消息/completion、原 ID 重放及非成员拒绝均验证；25 ms 为功能专用配置，非默认延迟性能结论。Account 房间 HTTP 与 Operator 流程同时通过。性能单独验收。 |
| #1/#2/#8/#9/#11 的 Host 恢复/回收层次 | [实际 Host/Factory/PG 生命周期](g2-host-pg-lifecycle-evidence.md)覆盖 acquire 后恢复中失租、共享恢复只取消一方、恢复/激活限额及 idle 关闭竞争；不是两个 OS 进程全组合。 |
| #18 只有 fake drain | [真实 Host/PG 慢事务 drain](g5-host-pg-drain-evidence.md)已通过：超时不早释 lease，SQL 完成后关闭与释放，旧清理不影响继任 token。[真实 Linux App busy SIGTERM](g2-real-app-sigterm-evidence.md)也已通过：Actor Host 的房间事务被 PG 行锁阻塞时接收 TERM，解锁后仅一次持久消息/完成记录，Host 正常退出并释放旧 lease，原 Gateway 保持在线且重启 Host 后原操作幂等重放。该 App 运行不是满队列、慢 SQL、待处理 batch 三者同场注入。 |
| #15/#16 查询与 pair 交错 | [真实 Host/Factory/PG reservation](g2-pg-query-reservation-evidence.md)已通过：获准 B 恢复独立 flush、A 等待、对向 pair 统一次序、等待取消归还许可；实际 SQL 后注入 unknown 使两实例退役并以新 epoch 重放原消息。这里的 unknown 明确是测试注入，真正成功 COMMIT 丢 ACK 由原 #7/#13 的 wire proxy 独立验证。 |
| #14 暖额度与 refill/fence 次序 | [生产 direct append 的真实 PG 屏障](g5-credit-refill-fence-evidence.md)原生与 Linux 均 2/2 通过：暖额度耗尽、另一连接的 refill 等待业务 fence、回滚返还及旧 epoch 拒绝。unknown 子场景只检查本地 discard，实际成功 COMMIT 丢 ACK 仍引用 #7/#13 的独立证据。 |
| 无效 V1 总入口 | 已删除未实现探针的旧 scaffold，当前[故障入口](v1-fault-harness.md)逐项指向真实可运行脚本；没有宣称覆盖全部 21 项。G6 已接入 Linux 进程恢复 CI。 |
| #10/#21 取消和后台 writer 接管 | [真实 Host/Factory/PG 取消与 retention](g2-pg-cancellation-maintenance-evidence.md)通过：执行中的取消不早释 lease/许可，排队取消无持久写；后台 trimLog 持 fence 时第二 Host 不能接管，旧 token 在新 epoch 下被拒绝。随后在 `d4f173df` 加入 review/import 各自临界点屏障，同 suite 原生真实 PG **4/4** 通过：实际 worker 的失败 job 可重试、目标 import 的持久接收与终态唯一，新 epoch 重放保持原结果；这两项 Linux 仍待最终全量运行。 |
| #20 跨入口禁用账号 | [真实 Linux 三入口应用栈](g5-cross-entry-disable-evidence.md)已通过：独立 Actor Host、caller-only Gateway、Account/Operator HTTP；两条旧 Gateway 会话在暖房间及 Operator 请求前仍活，禁用提交后被主动关闭，固定新操作无消息/完成记录，Host epoch 未变。此轮因主动关闭而未在禁用后实际派发房间命令；不等同于成员 revision 或媒体授权的同场实测。 |
| #17 独立 owner/control DB 链路 | [真实双 Host、caller 与三个 PostgreSQL](g5-database-edge-evidence.md)通过：单独断开 Host A 到 control 或 owner-a，B 继续业务服务，A 在 control 故障期间持续续租、owner 失租后无持久写；恢复按原操作 ID 仅一次效果。真实 DB 重启将使用该拓扑的独立阶段；容量 fault 只承担 #19 的部分 owner 查询，不能把它当作尚未运行的数据库重启证据。 |
| #19、容量与 Linux required checks | #19 部分 owner 查询仍按下方历史矩阵的验收边界核对。容量功能 canary 不等于性能结论。[G5 Linux 回归记录](g5-linux-regression-evidence.md)列出初始完整运行的实际失败、针对性修正后的聚焦通过和最新 discovery/合同检查通过；不能把它们合称为同一提交的一次全量全绿 required run。 |

## G1–G4 可完成范围

| Gate | 已有可核对证据 | 仍缺的验收证据 |
| --- | --- | --- |
| G1 契约与所有权 | `IMV2ActorContracts` 的 Administration、Creation、Invitations、Messaging、Receipts、Recovery/Directory/Log、Forwarding、MediaAuthorization、Maintenance 等 wire 家族及 `IMV2ActorRuntime` 已编译；相应 `V2Actor*ContractTests`、`V2Actor*WireTests` 做字段往返/非法值检查；[capability catalog](capability-catalog.md)、[writer ledger](writer-ledger.md)、[file ownership](file-ownership.md)与 `scripts/check_v2_virtual_actor_inventory.py` 给静态唯一归属。Linux Release 应用构建见[应用栈证据](i1-application-smoke-harness.md)。 | [基线协议](v1-baseline-protocol.md)仍明确写着“no capacity numbers measured or approved”；G1 所要求的性能与资源预算冻结不能从配置文件/静态检查推断。应在看候选结果前固定阈值，并留下 main 基线测量。正式业务合同索引 `docs/reviews/README.md` 尚未登记已实现 Room Actor 合同；`virtual-actor-contracts.md` 仍自称草案。 |
| G2 激活、接管、排空 | [G6](g6-multihost-evidence.md)已有真实 Linux 双 Host、PG 锁屏障、peer-only Actor 网络分区、DB 可达期间续租、旧 Host 暂停/恢复及旧 token 的续租/释放/写入拒绝；`PostgresV2RoomActivationTests.bothCommitSchedules` 是 PG 两种提交顺序；`V2RoomActivationHostTests` 覆盖恢复和 drain 的 fake 状态机。 | 正常 SIGTERM 在满队列、慢事务与待处理 batch 下的**实际 Host/PG 排空**尚未在上述 G6 中演练；恢复失败/恢复中失租、回收竞争和调用取消也主要是 fake。p0 正补这些真实 Host 证据，本审查不重复实现。 |
| G3 远端 send/read | [G4 业务探针](g4-business-probe-evidence.md)、[G5 Linux 恢复](g5-linux-functional-evidence.md)、[G6](g6-multihost-evidence.md)证明独立 caller→Host 的真实 RoomRef 发送/日志读取、持久幂等与故障恢复；[Linux 应用栈](i1-application-smoke-harness.md)证明 Gateway TCP/TLS 私聊发送/接收方日志及 Account HTTP 昵称、邀请、媒体；`V2ActorGrantedMultiLaneBatchTests` 与 PG `actorGrantedTwoRoomBatch` 保留共享合批。 | 原 G3 字面条件是“**Gateway 不在 Actor 节点**时 send/read”。当前 `IMV2ServerApp/main.swift` 将 Gateway 配为 `hostsRooms: true`；应用栈中的 Gateway 即 Host，caller-only 独立探针不是 Gateway TCP 入口。因此有远端 RoomRef 证据，但没有精确拓扑的 Gateway TCP 端到端证据。还缺同拓扑下权限/序号/微批与旧合同的汇总断言及相对性能基线，不能仅据现有探针宣告 G3 全过。 |
| G4 写者/查询/后台 | [writer ledger](writer-ledger.md)已把 W01–W30 的当前 production entry、room-scoped lane/fence 与 control/workflow/projection 例外逐一标出。Gateway main 的 send/receipt/forward/maintenance 经 RoomRef/Factory，Account main 使用 `hostsRooms:false` 的 RoomRef 昵称/邀请/媒体端口；Operator 只保留 durable workflow 处理。D4、D5、D6 各自 PG 测试及 Linux Account HTTP 冒烟见[组合证据](i1-composition-progress-evidence.md)、[D6](d6-maintenance-evidence.md)、[应用栈](i1-application-smoke-harness.md)。本轮未发现三个 App 构造的已确认裸 room-fact writer。 | 静态清单与局部 PG 测试不证明所有生产分支在多 Host 接管临界点安全。W21–W23 转发交付/媒体复制和 W25–W27 review/retention/housekeeping 的**后台 writer 与接管同阶段**故障注入未见实际多 Host 证据；批量查询与 reservation 的交错及单 owner 故障也未见真实多 Host 证据。 |

W14/W15 的固定 roomID 开房是房间尚无 activation 时的封闭 bootstrap；W02 的 credit refill、W23 的 provider media copy、W24 的 grant/session、W28 的派生投影、W30 的过期 audit 副本处理有各自控制域/工作流语义，不能因为没持 Room token 就报“裸房间写”。W06 旧 `V2SpecialAccountMessagingService` 在基线台账中出现，但没有证据表明三个实际 App 仍构造它；生产消息审计通过已 fenced 的新能力处理。这里的“未发现”来自入口构造与调用图审查，不能替代全分支动态覆盖。

## 21 项故障矩阵

| # / 场景 | 当前最强证据与层级 | 仍需的实际证据 |
| --- | --- | --- |
| 1 并发首次访问 | [G6](g6-multihost-evidence.md)：**Linux 多进程+PG**，两 Host acquisition 同时卡在数据库锁，一获准一 occupied；两个 caller 同 operation 同时得到 accepted/idempotent 且仅一条消息。`V2RoomActivationHostTests.sharedRestore`：**fake** 同 Host 多等待者。 | 同 Host 多等待者的真实 Host/PG single-flight 与失败者重定位还没有与 G6 同等级的阶段屏障。 |
| 2 恢复失败/恢复中失租 | `V2RoomActivationHostTests.restoreFailure`、`restoreTimeout`、`safetyExpiry`：**fake**。 | 真实 Host 在 acquire 后 ready 前被阻断/失租，确认半实例不公开及下一次能恢复；p0 正补。 |
| 3 SIGKILL 接管 | [G5](g5-linux-functional-evidence.md)：**Linux 独立进程+PG**，客户端先起、杀已激活 Host、替代 Host 恢复，已提交操作可核对。 | 未见同一注入中未知进行中命令的独立持久对账；可与 #7/#10 组合。 |
| 4 Actor 网络分区且 DB 可达 | [G6](g6-multihost-evidence.md)：**Linux 四进程+独立 Actor/DB 网络**，TLS 由成功变 EOF，旧 Host 仍读 PG/续租，另一 Host 只服务健康房间，原房间无第二 writer，重连后结果唯一。 | 此项已有对应故障注入与数据库断言；无需误报为“未做网络分区”。 |
| 5 旧实例复活 | [G6](g6-multihost-evidence.md)：**Linux 多进程+PG**，pause→DB clock expiry→新 epoch→unpause，旧续租/释放/业务写均拒绝。 | 此项已有直接证据。 |
| 6 事务/接管两种顺序 | `PostgresV2RoomActivationTests.bothCommitSchedules`、`lockWaitCrossesExpiry`：**PG**，真实锁与数据库时钟。 | 尚未组合两个实际 Host 进程在两个提交位置同时写，但 SQL fence 的两种排序已被真库验证。 |
| 7 提交后回复丢失 | `V2RoomActivationCommitAckLossTests.committedSendWithLostAck`：**PG wire proxy** 在成功 COMMIT CommandComplete 后截断 ACK，独立连接查到唯一消息和原 ID 重放。[组合证据](i1-composition-progress-evidence.md)有执行日志。新增 `V2SharedRoomSendCommitAckLossTests.committedTwoRoomBatchWithLostAck`：**PG+生产 send batcher**，两房间同事务 ACK 丢失，两个 turn unknown、消息/完成记录各一次、原 ID 重放一致；[组合证据](i1-composition-progress-evidence.md)记录 native 1/1，CI 开关见 `.github/workflows/verify.yml`。 | 共享批次测试本身没有实例化真实 Host；Host 的 unknown 退役另由 `V2RoomActivationHostTests.uncertainTurn` 等 **fake** 覆盖。若要求 RPC 层“DB 已提交、远端回复丢失”，仍需实际 Host 通信阶段注入。不要把 deferred-trigger COMMIT 错误当成成功提交的 ACK 丢失。 |
| 8 回收/新请求竞争 | `V2RoomActivationHostTests.idlePassivation`、`lateAcquireAfterDrain`、`V2RoomTurnLaneTests.drainRace`：**fake**。 | 真 Host 的 idle close/admission 和新请求阶段屏障、旧清理不删新 epoch；p0 正补相关恢复/排空。 |
| 9 共享激活等待者取消 | `V2RoomActivationHostTests.sharedRestore`、`waiterDeadline`：**fake**。 | 真 Host 多等待者只取消一方，观测其余完成与 permit/continuation 回收；p0 正补。 |
| 10 命令取消 | `V2RoomTurnLaneTests.queuedCancellation`、`inFlightCancellation`，`V2HostRoomReceiptBatcherTests.cancellationAndAdmission`：**fake**；#7 是真 PG unknown 但非 caller 取消。 | queued/事务中/提交后实际 Host+PG 取消及结果对账；p0 正补。 |
| 11 热房间/冷激活过载 | `V2RoomActivationHostTests.boundedActivation`、`boundedRestores`、`V2ActorGrantedMultiLaneBatchTests.sharedPendingLimit`、`V2HostDatabaseWorkAdmissionTests`：**fake/本地调度**。 | 有界真实 Host 压测：热点满队列时健康房间继续服务、恢复池满后降载和资源回落。另有性能预算缺口。 |
| 12 shared batch 混旧 token | `PostgresV2RoomWriteStoreIntegrationTests.actorGrantedStaleMixedBatch`：**PG**，两房间消息均未写；`V2ActorRoomQueryExecutorIntegrationTests` 的 mixed-stale receipt：**PG**，旧行无写且有效 sibling 保留；`actorHostReceiptBatchFence` 同样是 **PG**。 | 异库另一路同时健康、旧库失败的实际 Host 分区/批次证据未见；不要把 send 全回滚套到 receipt 逐行语义。 |
| 13 shared batch 提交未知 | 新增 `V2SharedRoomSendCommitAckLossTests.committedTwoRoomBatchWithLostAck`：**PG+生产 batcher**，真实成功 COMMIT 丢 ACK，两项 unknown、原操作重放唯一；`V2RoomReservationCoordinatorTests.sharedUnknown` 与 Host unknown：**fake**。 | 同一实 Host 的全部参与 turn 暂停/换 epoch 仍由分层测试推导，未被同一端到端注入覆盖。 |
| 14 Credit refill/业务 fence | `activationRoomCreditIsolation`、`directRoomLogCommandCreditsPreserveShardCapacity` 及 direct authorization ACK 失败测试：**PG**，额度绑定 token、容量/未知结果不返还。 | 暖额度耗尽、跨连接 refill 等待、回滚与 Host 接管交错的统一阶段屏障；不能仅由正常额度测试推出无自等待。 |
| 15 批量查询/reservation 交错 | `V2RoomRecoveryBatcherLifecycleTests.onePermitPerRecoveryBatch`、`earliestSelectedSQLDeadline`，`V2RoomReservationCoordinatorTests.oppositeDirection`：**fake**；`V2ActorRoomQueryExecutorIntegrationTests` 有 **PG** 读/receipt，但未将 A/B 查询和 reservation 同步交错。 | query 已持 B、reservation 已持 A 的真实 Host/PG 屏障与无等待环、独立 flush 证明。 |
| 16 对向转发/协调器失联 | `V2RoomReservationCoordinatorTests.oppositeDirection`、`beforeDispatchFailure`、`sharedUnknown`：**fake**；`V2RoomActorForwardingDatabaseTests.v2RoomActorForwardPairFenceAndReplay`：**PG** 单对；`V2RoomActorForwardImportDatabaseTests`：**PG** 跨 owner import。 | 两实际协调器对向 A→B/B→A 与 SQL 前后断联、未知 reservation 换 epoch 的多进程注入。 |
| 17 owner/control DB 故障 | `PostgresV2RoomActivationTests.connectionLossRollsBack`、`V2RoomActivationTransactionDeadlineTests`：**PG**；`directControlConnectionLossChild` 是基线 direct authorization **子进程/PG**，非完整 Actor 拓扑。 | 三个独立数据库实例下分别切断 Host→某 owner/control、重启/锁等待/提交连接丢失，并验证健康 owner 仍服务；当前 native PG 多 schema/库不能替代独立网络故障。 |
| 18 SIGTERM/排空超时 | `V2RoomActivationHostTests.drainWithExecutingTurn`、`reservationDuringDrain`、`releaseRetry`：**fake**。 | 真 Host 收到 SIGTERM 时满队列、慢 SQL、待处理 batch，证明共享资源最后关闭且 lease 不早释；p0 正补。 |
| 19 批量查询部分 owner 失败 | `V2RoomRefClientsTests` 的 recovery partial-results：**fake**，`V2ActorRoomRecoveryMapperTests` 的 unavailable/retry 保真：**wire**，`V2ActorRoomQueryExecutorIntegrationTests`：**PG** 正常结果。 | 一 owner 实际不可用而另一 owner 继续成功的 Host/PG batch 查询证据。 |
| 20 跨入口及权限变更 | `directSendControlAuthority`、`directControlPolicyFence`：**PG**；[应用栈](i1-application-smoke-harness.md)：**Linux** Gateway TCP send 与 Account HTTP 昵称/邀请/媒体；`V2RoomActorMediaAuthorizationDatabaseTests`：**PG** 可见性重检。 | Actor A、Gateway B、HTTP C 三个不同进程的同一权限变更时序，特别暖缓存/禁用账号后的远端 send 与媒体授权，没有统一黑盒屏障。 |
| 21 后台写者与接管 | `V2RoomActorMaintenanceTests.activationFencedRetention`、`activationFencedBookkeeping`、compactor 两种锁顺序：**PG**；D5 forward import 与媒体快照 **PG**，见[D6](d6-maintenance-evidence.md)。 | retention/review/import 分别在持久提交临界点遇到实际第二 Host 接管的故障注入，以及保留窗口/幂等结果验证。 |

## 值得先处理的非故障矩阵差距

1. **验收状态入口失真。** `docs/reviews/virtual-actor/README.md` 的 G1“业务 DTO 仍在整理”、G3“完整领域合同尚未验收”与当前已编译 wire/PG/应用栈不一致；G2 在 `8231a079` 已修正 Linux/分区描述，但 G1/G3 尚未重新按原 gate 逐条判断。[应用栈说明](i1-application-smoke-harness.md)开头仍称“完整应用运行尚未登记”，下文却有两次 Release 实跑。`IMV2/docs/README.md` 仍将整体列作“待实施”；方案/任务卡的“草案/待实施”可保留为历史计划，但正式当前状态须从实际证据入口同步。否则会产生假缺口。
2. **生产旁路判断应依构造图，而非旧类名。** `IMV2ServerApp/main.swift`、`IMV2AccountServerApp/main.swift`、`IMV2OperatorServerApp/main.swift` 的当前构造与 [writer ledger](writer-ledger.md) W01–W30 对照，未查到确认的裸 room-fact writer。`PostgresV2ReadReceiptStore` 在 Gateway 的剩余构造用于 control preference/reader；`PostgresV2DirectMessagingStore` 的开房 bootstrap 是封闭例外；投影与 media session 是另一个事实域。若未来改 App composition，应重跑 W01–W30 的入口审查，不要靠 `rg V2Routed` 零命中判断覆盖。
3. **综合 V1 harness 尚非执行证据，宜最小清理。** [v1-fault-harness](v1-fault-harness.md)说明 `run_v2_virtual_actor_faults.sh`/Compose 总入口仍是 scaffold。脚本的 `require_integration` 要求不存在的 `/usr/local/bin/IMV2VAFaultProbe` 和 `barrierProtocol=file-v1` 合同，`up`/`run` 必然在运行故障前 exit 78；这不是失败的生产故障演练。原 C0 任务卡允许决定是否保留执行期脚本。建议撤下这两个死入口及其未实现 contract/fixture 的“可运行”表述，保留历史设计记录；当前重跑入口明确指向 `test_v2_virtual_actor_multihost_probe.py`、`test_v2_virtual_actor_business_probe.sh`/`run_v2_virtual_actor_linux.sh`、`test_v2_virtual_actor_application_stack.py`、专用真 PG ACK-loss/领域 suites，不复制一个仅改名的新拓扑。尚未覆盖的 #2、#8–#10、#17–#21 仍需逐项新增可运行屏障，不把专项脚本的覆盖说成完整 21 项。CI 已登记成功 COMMIT ACK 丢失的单/双房间测试，但 G6 Linux 多 Host/peer partition 与完整应用栈尚未被相同等级的 required gate 周期运行覆盖。相对性能预算也未测定，因此不应宣称 G5 完成。

审查没有启动测试或修改生产文件。证据等级与待验边界可供根集成时逐项勾销；尤其 p0 正在做的真实 drain/取消/恢复，应以其实际运行报告更新 #2/#8–#10/#18，不能提前标通过。

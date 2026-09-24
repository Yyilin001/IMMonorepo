# Room Virtual Actor 工作包与派工卡

状态：待实施。先读[总方案](virtual-actor-parallel-plan.md)与[公共契约](virtual-actor-contracts.md)。所有“新增”目录、类型、suite 和脚本都是计划交付物；本文不声称它们已经存在或通过验证。

基线固定为 `f1cdd78d6a21bf0ae23da627c0710c65115236aa`。实施代理从 C0 发布的契约提交及后续指定集成提交开始，不从原目录未提交的 Distributed Actor 改动开始。每包的独占文件列表由 C0 落成清单，以下为必须覆盖的文件与边界。

除完整路径外，下文 service/store 文件相对 `IMV2Server/Sources/IMV2Server/`；测试相对 `IMV2Server/Tests/`。

## P0 兼容性验证

**输入：** 干净 main、固定 Swift 6.4 Linux 镜像、Vapor 5 beta.2、现有 PostgreSQL vendor 补丁。与 C0 清点、V1 基线可并行。

**所有权：** 拟新增 `IMV2Server/Tests/VirtualActorCompatibilityProbe/` 与独立 probe 说明/脚本；manifest/lockfile 由 C0 独占，P0 提供确定的依赖补丁，由 C0 合入后回传 SHA。不要复制锁文件给不同代理自由解析。

**交付：** 一个固定版本或 revision 的 DistributedCluster 依赖建议、完整依赖差异、可重复的双进程 Release probe、启动/关闭资源图。探针可先用独立最小 package 定位问题，但最终必须在真实 IMV2Server 依赖图验证。

**验收：**

- 两个独立 OS 进程发现彼此并调用真正 `distributed func`；请求、结果、领域错误、引用传递/解析能够编解码，使用真实房间 ID 表示和最小业务 DTO。
- 大小、超时和协议不匹配有明确失败；验证可信节点身份绑定及认证加密支持，给 C0 可实现的接口。
- 停止目标进程、重启新 incarnation 后，旧引用有界失败，新引用成功；不复用旧实例身份。
- 同时运行 Vapor HTTP 和数据库资源；SIGTERM、启动失败、远端失联能结束，没有双重 EventLoop 关闭或活事务下释放资源。
- Linux Release 真正运行，而非只 Debug 编译；检查 NIO、Logging、ServiceLifecycle、Collections、Atomics、Crypto 等共享依赖。不得静默降级 Vapor 或移除 vendor 补丁换取通过。

**失败处理：** 把兼容问题和最小复现交 C0，先修复 G0。不得声称 Virtual Actor 已成立，也不得让 R3 基于未确定 API 全面编码。另选 transport 是显式设计变更，不是代理自己的降级捷径。

## C0 契约冻结与并行准备

**Owner：主代理。输入：** 本组方案、P0 结果、业务台账、V1 基线。P0 未完成时可做清点和领域接口草案。

**独占：** `IMV2Server/Package.swift`、锁文件、新 Contracts 目标、公共配置/错误/metrics 定义、跨领域 executor dispatch、既有共享文件的无行为抽取、后续 I1 共享文件。

**交付物：**

1. 按总方案创建 Contracts/Runtime/Cluster 目标和测试目标，形成无环依赖；分别放置 client、hosting、scheduling、coordination 子目录。
2. 可编译的身份、lease、host、executor factory、RoomRef、command/query/result、reservation、错误和 cancellation API；包含可替换 fake store/transport/executor。只在真实隔离边界定义协议，不为每个具体类型机械套协议。
3. 完整 capability/DTO 清单：每个现有入口映射到 command/query、业务结果、是否持久幂等、retry class、授权/事务边界、领域 owner。全量类型先由 C0 冻结，生产行为可以分波次实现。
4. 明确生产 dispatch 不接受未实现能力；开发 stub 只在测试中使用，不能成功返回空结果掩盖缺实现。具体 handler 与 mapper 交领域包，公共 dispatch 由 C0 接入。
5. 精确到文件的所有权清单、集成提交 SHA、稳定共享 fixtures。`PostgresV2RoomWriteStore.swift` 等跨领域巨文件按责任先抽成同模块独立扩展/primitive；无法安全抽取则指定唯一编辑者，其他包提交接线请求。
6. 配置的有限默认值、时间预算关系、指标名/低基数标签、版本协商策略和身份认证端口。基线性能阈值在候选测量前固定。
7. 执行期文档目录建议为 `docs/reviews/virtual-actor/`，包含契约变更记录、writer ledger、ownership、基线及各包证据；正式权威合同另在 reviews 索引登记。不要复制一份“当前实现状态”。

**验收：** 所有目标编译、DTO round trip 与错误/未知版本测试通过；领域代理能只依赖冻结接口编译 fake；独占文件无重叠。C0 发出 `contract SHA` 后进入 W1。

## R1 租约与事务资格

**依赖：C0。独占：** 新 `PostgresV2RoomActivationStore.swift`、`V2RoomOwnerTransactionFence.swift`、`IMV2/sql/schema.sql`、`V2SchemaReadiness.swift`、`IMV2/scripts/current_v2_schema_contract.sql`、`scripts/test_v2_postgres_schema_bootstrap.sh`，及专用 `PostgresV2RoomActivationTests` 测试文件。不直接改 D1 的发送 batcher/业务 SQL。

**交付：** 数据 owner 库内持久 lease、单调 epoch、acquire/renew/release/locate；业务事务可调用的统一 fence helper；供批量 SQL 使用的 token 行输入和锁顺序合同；错误映射。schema 四处联动，沿用全新建库而非历史升级脚本。

**验收：** 真实 PostgreSQL 两竞争者只有一个有效 token；release/renew 完整比对代次；epoch 不因回收归零；恢复期间续租；事务回滚与连接丢失；多房间 canonical lock order。必须分别测试“旧事务先持锁→新 acquire 等待”和“新 epoch 已提交→旧事务迟到拒绝”；锁等待跨越 expiry 后，以拿锁后的 DB 当前实际时间拒绝过期 renew/write。schema 缺失/字段漂移拒绝启动，仅更新表数量不算通过。

**交接 D1–D6：** 明确在哪个事务和锁之前调用 helper、批量 SQL 如何取得/持有相同 fence、事务时间限制。逐包确认集成，不假定 helper 存在就已覆盖所有 writer。

## R2 本地激活与执行运行时

**依赖：C0，先 fake 后接 R1。独占：** 新 `IMV2ActorRuntime/Hosting/`、`Scheduling/`、`Lifecycle/`、`Coordination/`，对应测试文件；不得改 R3 的 Client 子目录。

**交付：** 单节点 single-flight、restore-before-ready、容量许可、一个 FIFO lane/一个未决 turn、连续兼容 send 微批、独立续租、idle/passivation、drain、uncertain/retire、双房间 reservation API。恢复状态通过注入 factory 获得；依赖 PostgreSQL 的恢复 adapter 由 C0 的共享 executor 接线及领域 handler 提供。

**验收：** 不依赖 actor await 自然串行；故意在 await 点挂起，证明同房间 turn 不重叠；send/membership/send 不跨屏障；两次等批不叠加；一个等待者取消不杀共享激活；队列/字节/恢复上限；热房间不饿死其他房间；旧回调不删新 activation；passivation 前后新请求都有明确归宿。

**Reservation 验收：** A→B/B→A 无死锁；source=target 只预约一次；等待失败安全释放；已派发 SQL 后 timeout 不恢复同 epoch 执行；协调器死亡通过 uncertain→retire→新 epoch 恢复，迟到 finish/release 无效。真实数据库语义与 D5/V1 联调。

## R3 逻辑引用与集群传输

**依赖：P0、C0，先 fake host 后接 R2。独占：** 新 `IMV2ActorRuntime/Client/`、`IMV2ActorCluster/`、对应 transport/ref 测试。

**交付：** RoomDirectory/RoomRef、代次感知的 bounded resolver cache、host discovery/capacity placement、具体 distributed RoomActor、wire adapter、cluster service lifecycle。有效 lease 指向不可达 host 时有界失败，不能仅凭 membership 变化抢占。

**验收：** 业务 caller 无需知道 host/shard；真实跨进程 command/query/领域错误；旧 ActorID 失效后原逻辑 RoomRef 可以重新定位；stale 响应不覆盖新 epoch；明确未接受才自动重定位，未知结果保留原 operation ID 和 retry class；本地路径与远端路径执行相同授权/限额。

**交接：** 给 I1 提供资源所有权与 start/readiness/drain/stop API；给 D3 提供 grouped resolve/query 扩展点；不将 Gateway socket 或响应 closure 传进远程 Actor。

## D1 消息与发送合批

**依赖：C0，真实执行依赖 R1–R3。独占：** 新 `RoomDomain/Messaging/`；`V2SendMessageService.swift`、`V2MessageEditService.swift`、`V2MessageWithdrawalService.swift`、`V2MessageReactionService.swift` 及其独立 store；`V2SendMessageAdmissionBatcher.swift`、`V2ShardedSendMessageAdmissionBatcher.swift`、`V2RoomAdmissionCommandCreditPool.swift`、`V2ShardAdmissionCommandCreditPool.swift`；C0 抽出的房间写 SQL/message primitive。`V2SpecialAccountMessagingService.swift` 的发送/审计适配由 D1 独占，开房调用 D4 冻结接口。

**交付：** 上述命令的 handler/DTO mapper、恢复/失效贡献、现有持久 primitive 的 activation context 接入；same-room microbatch 与 cross-room shared batcher 对接。房间顺序由 runtime 控制；节点共享数据库连接池和合批保留。

**验收：** 普通/暖 fast append/冷 batch/大群集合写；稳定 operation ID 与 payload conflict；序号、room-log、受众、projection/outbox 原子性；edit/撤回/reaction 终态与权限顺序；旧 token 混入 send batch 按原合同整批回滚；同房间热写合批不降为逐条事务。特殊账号的 room-scoped 审计也受 fence，不能藏着裸 store writer。

**Credit 验收：** 遵守公共契约的先预留、后业务锁边界，联合 R1 证明 warm credit refill 不跨连接自等待；旧 activation 的预留不可复用，rollback/release 不重复返还；room_admission 与共享 shard admission 的容量和现有窗口语义不变。不能对辅助额度预留机械套用外层业务锁。

**交付测试：** 独立 `V2RoomActorMessagingTests`，相关已有 send/mutation/Postgres suites；共享集成测试 support 由 I1 修改，勿与其他领域同时编辑。

## D2 成员与群管理

**依赖：C0，集成 R1–R3；与 D1 共享语义由契约连接。独占：** 新 `RoomDomain/Administration/`；`V2RoomMembershipService.swift`、`V2GroupCapabilitiesService.swift`、`V2ModerationService.swift` 及对应 store；C0 从 profile presentation 混合文件抽出的群昵称部分。联系人备注保持用户域。

**交付：** 成员/角色/公告/置顶/moderation/群昵称 handler 和 mapper；trusted moderation 能力接受稳定 operation ID、expected content revision 和可信主体；全部事务核验当前 activation。HTTP 接线交 I1，worker 调用交 D6。

**验收：** 成员 revision、角色 baseline、冻结/解冻、成员移除与 send/edit 提交顺序；重复请求与昵称 replay；活跃 Actor 期间 account disable/block/control policy 变化仍有效；可信审核不能凭旧内容版本覆盖新编辑；Account HTTP 在另一节点时群昵称成功且授权相同。

**交付测试：** 独立 `V2RoomActorAdministrationTests` 及相关 membership/capabilities/moderation/profile suites，不重写原有业务可见性规则。

## D3 已读、查询与订阅

**依赖：C0，集成 R1–R3。独占：** 新 `RoomDomain/Receipts/`、`Queries/`、`Subscriptions/`；`V2ReadReceiptService.swift`、`V2ReadReceiptBatcher.swift`、独立 read-receipt store；group event log、membership directory、group-role baseline、room recovery/state/latest-visible 的独立文件。用户披露偏好 store/传播保留用户域。

**交付：** 已读命令、读者查询、日志 pull/subscribe、目录/角色基线、状态/摘要批量 API；host/物理库级 query batcher；可到期、可重新建立的 Gateway 兴趣注册，socket 留 Gateway。只在需要更新的缓存上保存版本，保留授权重检。

**验收：** 单次最多 100 房间的既有批量路径仍集合读取，统计 RPC/SQL 和 cold activation；只聚合已获 read turn 的项目、有界独立 flush，batch query A/B 与 reservation A→B 交错无等待环；单 owner 故障保留健康项；不把 unknown/unavailable 当无权或空；分页 cursor、成员 revision、读者隐私及媒体依赖查询的快照语义；已读批处理失效 owner 保持逐行结果，不套用 send 全批回滚。

**订阅验收：** Actor 回收/接管后 Gateway 重订阅；NATS/提示丢失后 durable cursor 补拉；断连兴趣释放，不泄漏 pin；慢消费者不阻塞业务事务完成。独立 `V2RoomActorQueryTests`、`V2RoomActorSubscriptionTests`。

## D4 创建、邀请与全局配额

**依赖：C0，可先 fake；集成 D1/D2。独占：** 新 `RoomCoordination/Creation/`、`Invitations/`；direct/group creation、`V2GroupAudienceImportService.swift`、`V2GroupRoomCreationIntent.swift`、`V2GroupInvitationService.swift`、独立 invitation store/directory、创建恢复和 quota 恢复 worker。跨领域 routed wrapper 与 HTTP 接线由 I1 处理。

**交付：** Creation Coordinator 与 Invitation Coordinator；固定 roomID/manifest 的 staged begin/append/finalize/cancel；token→roomID、全局配额/intent 在 control 域，房间端预检/提交/审批通过同一 RoomRef 能力；后台恢复复用前台协调器。

**验收：** resolve 不存在房间不触发创建；创建响应丢失恢复原 roomID；finalize 崩溃重放；invite creation intent 与目录绑定；审批事务原子性、approve/cancel 竞态与配额恢复；主/后台无第二套路由；恢复失败不标完成。独立 `V2RoomActorCreationTests`、`V2RoomActorInvitationTests` 及既有 invitation/Postgres suites。

**边界：** 开房 bootstrap 是尚无 activation 的封闭例外，使用原幂等和 owner 合同；房间持久创建后所有普通修改进入 activation。不能为绕过未知房间错误增加公共裸 writer。

## D5 转发与房间媒体授权

**依赖：C0，可先 fake；集成 R2 reservation、D1/D2。独占：** 新 `RoomCoordination/Forwarding/`、`MediaAuthorization/`；`V2ForwardMessagesService.swift`、`V2CrossOwnerForwardService.swift`、`V2ForwardImportEndpoint.swift`、delivery/export/inbox/receipt/media-import 工作流及对应 store/compactor；独立 media visibility 授权逻辑。若 forward primitive 原在 `PostgresV2RoomWriteStore.swift` 内，必须消费 C0 抽出的独立文件，不能与 D1 同改原文件。

**交付：** 每次 source-target 的同库 reservation 协调与原子授权/接受；跨库沿用 durable export/inbox/receipt；后台目标 import 经 RoomRef 幂等命令；媒体 locator/session 的房间可见性能力。设备权威、provider 字节传输仍留现有 media/control 域。

**Replay 写入不能遗漏：** 将 `replayedResults` 中覆盖全 source×target 的修复写拆成逐 pair 操作；`clientMessageID`、接受、`markResult` 和 replay 修复均在对应 reservation/fence 下执行。可保留纯批量观察，不为修复申请超过两个房间的 reservation。测试接受成功但 markResult 丢失、进程重启后批量恢复、source=target，以及来源后来不可见时仍返回既有成功结果。

**验收：** 同库转发与两侧独立命令并发；对向转发无死锁；一个 target pending 不取消兄弟 target；跨库重复投递和 import 响应丢失；源授权竞态、终态压缩 replay、媒体复制恢复；session 签发/兑换前后授权快照保持，不能以一次缓存永久放行。

**必须联合 R2/V1 验证：** reservation 已获取后协调器死亡、SQL dispatch 后失联、commit 后通知丢失，旧 token 迟到提交/finish/release 被正确隔离。不得把逐 source-target 原子范围扩大为整个请求，也不得改为同库先后两个独立事务。独立 `V2RoomActorForwardingTests`、`V2RoomActorMediaAuthorizationTests`。

## D6 后台维护与用户投影衔接

**依赖：C0 可先盘点和编排；集成 D1–D5。独占：** 新 `RoomMaintenance/`；`V2RoomLogRetention.swift`、`V2ContentReviewWorker.swift` / `V2RoutedContentReviewWorker.swift` 的调用适配；C0 拆分的 room housekeeping；用户 projection/outbox 的必要衔接文件。D4 独占邀请/创建恢复 worker，D5 独占 forward 工作流，D6 不再次编辑它们。

**交付：** scanner/claim 与房间事实提交分离；retention trim、room-scoped housekeeping、trusted moderation 都经房间能力；业务在 D1/D2，D6 只接 worker 入口。为保留在外部的 user/control/projection writer 补逐表理由和版本/失效合同。

**验收：** room-log floor 推进/删除与热房间并发；旧 activation 的后台任务不能在接管后生效；持久 operation 保留/压缩窗口不变；content review apply 失败不能完成 job；NATS 不可用时 outbox/日志仍可恢复；投影压缩改变 body 引用后没有无版本缓存悬挂。独立 `V2RoomActorMaintenanceTests`。

## 业务迁移台账

实施时 C0 将下表展开成逐 writer 行，增加 `实际入口 → Room能力 → handler/store事务 → fence位置 → 测试证据 → 状态`。下表是完整性清点起点，不是“已覆盖”证明。

| 入口/写者 | Owner | 去向与必须保留的边界 |
| --- | --- | --- |
| Gateway 普通发送、send batch、edit/withdraw/reaction | D1 | RoomRef → turn → 实际业务事务；受众、幂等、序号、outbox 不变 |
| room_admission / shard admission command credit pools | D1 + R1 锁合同 | 有界容量预留先于业务持锁；room credit 绑定 activation，shard pool 为共享配额，不替代写资格 |
| 特殊账号开房/发送/审计 | D1 + D4 接口 | 开房 coordinator；room-scoped 审计不能裸写 |
| membership、roles、moderation、公告/置顶 | D2 | 同一房间 lane；control 身份与房间权限都检查 |
| Account HTTP 群昵称 | D2，I1 接线 | RoomRef；联系人备注继续用户域 |
| 已读推进与读者列表 | D3 | 房间进度/候选由房间处理，用户偏好/隐私在 control 域复查 |
| 日志订阅、成员目录、角色 baseline、房间状态/摘要批量 | D3 | logical room query、集合查询、稳定 cursor/修订、Gateway connection sink |
| direct open、staged group finalize 与 recoverFinalizing | D4 | 持久创建 coordinator，固定 roomID/manifest |
| invite create/revoke/preview/submit/approve/reject/cancel | D4 | 全局 token/配额协调与房间接受分离；恢复同一路径 |
| foreground same-store forward | D5 | 每 source-target reservation + 单事务双 fence |
| forward clientMessageID / markResult / replay 修复 | D5 | 逐 pair 资格覆盖辅助持久写；保留历史成功结果重放 |
| cross-store export/inbox/receipt、ForwardImportEndpoint | D5 | 保留 durable workflow，目标房间接受经 RoomRef |
| forward media import/compactors | D5 | 自有 workflow lease 可独立；房间接受/幂等终态使用房间能力 |
| Account/Media HTTP 下载授权与 session | D5，I1 接线 | 房间可见性快照重检；设备与媒体字节服务不搬入 Actor |
| content-review claim/reviewer/trusted moderation apply | D6 + D2 接口 | claim 在 worker；可信 apply 经房间命令与内容版本检查 |
| room-log retention | D6 | scanner 找候选；floor 更新和事件删除在房间维护 turn/fence |
| ControlPlaneHousekeeping 的 room operations/content-review 清理 | D6 | 拆分 room-owned 与 control-owned 部分；Actor 不永久缓存回执 |
| message projection body compaction/GC | D6 审计 | 衍生投影维护；不作为 Actor 恢复权威，不缓存无版本 body 指针 |
| direct-room profile propagation | D6 审计 | 继续用户 projection/checkpoint；检查多 owner 枚举，不误归 room writer |
| read-receipt preference propagation | D6 审计 | 继续用户 outbox；不是所有带 roomID 的写都进 Actor |
| account disable、social/block、policy 更新 | D2/D6 审计 | control 事实保留；活跃房间不能绕过持久策略版本 |
| favorite、conversation pin/archive/mute、sync/snapshot | D3/D6 审计 | 用户域保留；涉及房间可见性调用明确 room capability |
| push、user-event outbox、group wake、typing/presence | D3/D6 | 自有 checkpoint/lease 保留；提示不能成为完成/恢复权威 |

## V1 验证与证据

**所有权：** 拟新增 `IMV2/docker-compose.virtual-actor-tests.yml`、`IMV2/scripts/run_v2_virtual_actor_faults.sh`、`IMV2Server/Tests/VirtualActorFaultHarness/`，现有 `.github/workflows/verify.yml` 的相关接入、隔离测试配置及独立 evidence 文件。Package 注册由 C0 完成；执行期测试脚本是否保留为最终产品由 C0 明确。

**提前交付：** main 性能与资源基线、可控阶段屏障、两个 Actor host + Gateway/probe + 三个独立 PostgreSQL 的拓扑。能分别隔断 actor 网络、某 host→owner DB、某 host→control DB；不是只会 kill 整个容器。故障控制通道仅在测试存在，不增加生产未认证调试 API。

**故障矩阵：**

| 场景 | 注入点 | 核心断言 |
| --- | --- | --- |
| 并发首次访问 | 两 host 与同 host 多等待者 | 唯一有效资格、single-flight 不挂死、失败者重定位 |
| 恢复失败/恢复中失租 | acquire 后、ready 前 | 不发布半实例；旧 token 不 ready；下次可恢复 |
| 强杀并接管 | SIGKILL 已激活 host | 已提交状态与幂等结果恢复；未知命令可核对 |
| Actor 网络分区 | 旧 host 仍可访问 DB | 不能只因 membership 不可见制造双 writer |
| 旧实例复活 | SIGSTOP、另一 host 接管、SIGCONT | 新 epoch 后旧写/续租/释放全部失效 |
| 事务/接管两种顺序 | 旧事务持锁；或新 epoch 先提交 | 允许旧先完成新后授予，拒绝新授予后旧提交 |
| commit 后回复丢失 | DB 提交与 RPC 返回之间 | 原 operation ID 得到同一持久结果，一个业务效果 |
| 回收/新请求竞争 | idle 判定、关闭 admission、排空 | 无请求进退休对象、旧清理不删新实例 |
| 共享激活等待者取消 | 多调用者只取消一个 | 其余正常完成，许可/continuation 无泄漏 |
| 命令取消 | 队列中、事务中、提交后 | 取消不等于未提交；持久结果与重试分类正确 |
| 热房间与冷激活过载 | 房间/节点队列满、恢复池满 | 容量硬上限，健康房间仍可服务，恢复后资源下降 |
| shared batch 混入旧 token | 同库多个 room、异库另一路 | 原 send rollback/receipt 逐行合同分别保留 |
| shared batch 提交未知 | 多房间共享事务 commit 后丢结果 | 通知全部参与 turn，全部暂停后续执行并核对/恢复 |
| Credit refill 与业务 fence | 暖额度用尽、回滚、接管 | 不跨连接自等待，旧额度不复用且不重复返还 |
| 批量查询与 reservation 交错 | query A/B 已持 B，reservation 已持 A | read batch 独立 flush/释放 B，不等待整个请求所有 turn |
| 对向转发/协调器失联 | A→B、B→A，SQL 前后故障 | 无死锁；unknown reservation 通过 fence/换 epoch 隔离 |
| owner/control DB 故障 | 断连、重启、锁等待、提交连接丢失 | 不确认未提交；健康 owner 可服务；失租封闭写入 |
| SIGTERM 与排空超时 | 满队列、慢事务、待处理 batch | 保持租约到正确排空；最终才销毁共享资源 |
| 批量查询部分失败 | 一 owner 不可用 | 成功项保留，失败项真实，不伪装空或无权 |
| 跨入口与权限变更 | Actor A、Gateway B、HTTP C | 发送/昵称/邀请/媒体授权同路径，暖缓存不沿用禁用账号权限 |
| 后台写者与接管 | retention/review/import 在临界点 | 所有生产写入均受 token 约束，原幂等/保留窗口不变 |

用明确阶段 barrier 等待注入位置，不用固定 sleep 猜事务阶段。缺 DB、缺第二进程、零个匹配测试、故障未触发必须失败。证据记录 revision、锁文件摘要、镜像、boot ID、room/operation/epoch、注入阶段、持久结果与退出码；不含凭据或消息正文。

**相对性能：** 同房间热写、多房间同库、混合读写/批量查询、冷激活回收、故障恢复峰值；至少三轮 main/候选交错。报告吞吐、p95/p99、SQL/命令、batch 大小、CPU、RSS、队列、恢复时间和测试配置。阈值由 C0 在候选测量前冻结，基线噪声超预算先修测量，不随候选调宽。

可复用 `IMV2/scripts/run_v2_gateway_load_guarded.sh`、`run_v2_high_active_10000.sh` 与 PostgreSQL profile 工具，但要先检查实际参数和平台限制。降低 connections-per-worker 不等于降低业务速率；带固定部署地址的 runner 不能直接指向未知环境。

## I1 集成与最终收口

**Owner：主代理。独占：** `IMV2ServerApp/main.swift`、`IMV2AccountServerApp/main.swift`、`IMV2OperatorServerApp/main.swift`、`V2GatewayDomainCommandHandler.swift`、跨领域 HTTP 路由接线、旧共享 routed 文件、共享测试 fixtures 与文档索引。代码路径均在 `IMV2Server/Sources/` 下的相应 target 内。

**逐波交付：**

1. 接入真实 lease/runtime/transport，先完成两节点最小激活/恢复/关闭。
2. D1/D3 可用即接通一条真实 remote send + room-log read，不等所有领域完成才发现 composition 不可行。
3. 依次接入 D2、D4/D5/D6，替换 Gateway、Account HTTP、Operator 和 worker 的全部房间入口。用户域原服务保留；基础设施可保留内部 data-owner resolver。
4. 删除无 activation context 的生产房间 writer 入口与过渡 routed wrapper；逐项检查台账，不能只按类名扫描。假实现不进入生产 composition。
5. 更新生命周期配置、readiness、指标/告警、正式合同与现有当前状态入口；运行 G5 并汇总真实证据。

**最终交付：** 实施 commit 序列、完整 writer ledger、G0–G5 证据、依赖 pin、干净 schema 与故障演练说明、未验证的部署/生产容量边界。未通过关键 gate 不标完成；无须为未改动的 iOS 页面另做全套设备验证，但既有 CI required checks 不删除。

## 验证命令与环境隔离

以下为 main 已有入口。每个代理将示例 project 名替换成自己的唯一值；Server tests 会重装共享 schema，不能对同一数据库并发运行。不要多个代理共用固定 `imv2isolatedtests` 项目名的包装脚本。

相关快速测试示例（过滤名称在 main 已存在）：

```bash
swift test --disable-automatic-resolution --package-path IMV2Server --no-parallel \
  --filter 'V2DatabaseWorkAdmissionTests|V2RoomWriteBatchRouteCacheTests'
```

真实数据库的独立 Compose 示例：

```bash
docker compose -p imv2-va-r2 \
  -f IMV2/docker-compose.isolated-tests.yml run --build --rm \
  -e 'V2_TEST_PACKAGES=IMV2Server' \
  -e 'V2_SERVER_TEST_FILTER=V2HTTPServiceTests|V2DatabaseResourcesTests|V2TaskDrainDeadlineTests|PostgresV2RoutedRecoveryFaultTests|PostgresV2RoomRecoveryTopologyTests' \
  swift-tests
```

R1 另外执行 schema gate；bootstrap 的 Docker 模式从宿主运行，已有测试容器没有 Docker socket。脚本使用带进程 ID 的独立项目名；需要 Docker/可丢弃测试环境的步骤按其现有约束运行：

```bash
bash scripts/check_v2_schema_readiness_tables.sh
bash scripts/test_v2_postgres_schema_bootstrap.sh
```

集成候选执行现有 Linux 广覆盖入口，不代替拟新增双进程故障 harness：

```bash
docker compose -p imv2-va-final \
  -f IMV2/docker-compose.isolated-tests.yml \
  up --build --abort-on-container-exit --exit-code-from swift-tests swift-tests
```

同时在固定 Linux Swift 6.4 镜像构建现有五个 Release 产品，以及 C0 新增的 probe/harness 产品；不能用 macOS build 代替 Linux。以下示例用于 CI 的可写 checkout：

```bash
for product in IMV2AccountServerApp IMV2OperatorServerApp IMV2ServerApp IMV2LocalGatewayProbe IMV2GatewayLoadGenerator; do
  swift build --disable-automatic-resolution --jobs 4 -c release \
    --package-path IMV2Server --product "$product"
done
```

若在现有只读源码挂载的隔离 Compose 中构建，V1 提供专用 wrapper，沿用 runner 的 HOME/cache 初始化并指定 `--scratch-path /tmp/swiftpm/IMV2Server`；不要为了 `.build` 改成可写源码挂载。C0 新增产品一起进入该 wrapper。

Gateway 接线按 `IMV2/scripts/verify_v2_local_account_stack.sh` 对应场景冒烟，由 I1 在专用窗口串行执行。当前 local-account 栈有固定镜像 tag 与宿主端口，换 Compose project 名仍可能冲突；禁止子代理直接重建默认开发栈。需要并行时 V1 先参数化镜像、端口与 probe 地址。

不自动扩展到每包运行全部媒体/10k 容量套件。相关检查通过且无新变化后停止重复测试。最终 V1 增加的故障脚本、suite 在实际存在并接入后才能写为运行证据。

只清理自己的可丢弃项目：

```bash
docker compose -p imv2-va-r2 \
  -f IMV2/docker-compose.isolated-tests.yml down --volumes --remove-orphans
```

原生 PostgreSQL 脚本的三库可能位于同一服务器，不能代替三个独立实例的网络/故障验证。隔离 Compose 的源代码只读挂载与独立构建卷保持不变。

## 可直接使用的派工模板

主代理先创建隔离 worktree，并把实际路径、契约 SHA 和任务卡 ID 填入，不能留占位符派发。

所有实施/验证/审查子代理统一指定 `model: "gpt-6-sol"`、`reasoning_effort: "high"`。使用 `fork_turns: "none"`，在任务消息中完整传入下面的基线、文档路径和文件边界；不要依靠默认继承改变用户指定模型。每次最多三个子代理并行，按总方案波次复用槽位。

```text
任务：实施 Room Virtual Actor 工作包 <ID>。
子代理配置：GPT-6 Sol，High；不自行切换模型或推理强度。
工作目录：<独立 worktree 绝对路径>。
代码基线：f1cdd78d6a21bf0ae23da627c0710c65115236aa。
启动提交：<C0 契约或指定集成 SHA>；禁止引入原目录未提交的 DA 改动。

先读 IMV2/docs/00-foundation/virtual-actor-parallel-plan.md、
virtual-actor-contracts.md，以及 virtual-actor-task-cards.md 中本包条目。
遵守仓库 AGENTS.md，按 Swift 后端/并发任务选择相关 skill。

只编辑 ownership 清单分配的文件和本包独立测试。
公共 DTO、manifest、入口和其他 owner 文件需要变化时，把准确变更请求发给主代理；
不要自行改签名或用成功 stub 绕过依赖。可以先对冻结端口使用测试 fake。
遇到缺失的业务语义，先对照 main 与既有 reviews 合同，交主代理统一处理。

完成本卡全部交付和相关验证。每个关键进展说明事实、剩余依赖和阻塞点。
最终返回：commit SHA、contract SHA、文件列表、能力/事务边界、
实际执行命令/退出码、证据路径、未验证项、需要集成 owner 完成的接线。
不宣称 fake 测试等于真实跨进程验证；不扩展到部署/发布或无关业务重构。
```

每包结束用统一交接格式，主代理检查后再分派下一波：

```text
Package / owner:
Base SHA / contract SHA / delivery SHA:
Owned files changed:
Capabilities and invariants delivered:
Commands run and results:
Evidence paths:
Shared-file integration requests:
Remaining dependencies / unverified items:
```

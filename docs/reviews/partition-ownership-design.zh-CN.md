# 执行分区所有权：现状、事务证明与迁移规格

日期：2026-10-03。本文是基于当前工作树的只读设计，不表示下面的新类型、表或协议已经实现；没有改生产代码、启动服务或执行数据库迁移。实现前应以实际冻结 revision 校对行号。

## 1. 建议与目标边界

保留显式数据分片路由，把“哪个进程执行房间”从逐房间数据库租约改成物理源数据库内的有限执行分区租约。房间 Actor、单房间业务事务、成员权限、连续日志、共享订阅 fence 和客户端 H/G/C 闭环继续存在。

执行分区的接管只能授予执行资格，不能授予某个用户阅读房间的权限。第一步可以停止逐房间执行租约 acquire/renew/release；尚未实现分区权限 cut 证明前，现有按房间批量读取 H/controlVersion 的权限续期证明必须保留，并明确它仍是 O(活动房间) 的过渡成本。不能把这个查询改名为“分区续租”后宣称已经完成所有维护规模转换。

最终稳态目标是：执行租约续期随所拥有分区数增长；变化消费随 owned 分区内 pending 变化增长；房间权限快照随实际订阅/变更增长。消息业务事务和房间顺序仍随实际命令增长，不承诺把业务写入变成无数据库锁。

## 2. 当前确有的机制与缺口

| 事实 | 当前代码证据 | 不能据此宣称的能力 |
| --- | --- | --- |
| 数据位置是 room_shard_id + owner_epoch，控制目录保存显式 route_epoch | `IMV2/sql/schema.sql:1919`、`:1960`；`V2PostgresRoomShardRouter.swift:34` 从 room_owner_routes 查询，不重新 hash 已有房间 | 没有执行分区表，也没有分区 epoch |
| 数据 owner 与执行 host 已分离 | `V2RoomActivationIdentity.swift:35` 的 DataOwner；`:65` 的 HostIdentity；`:78` 的 Token 包含逐房间 activationEpoch | 不能直接把 activationEpoch 解释成 partitionEpoch；Wire/Gateway 当前比较的是旧模型 |
| 激活授权保存在房间实际数据库 | `PostgresV2RoomActivationStore.swift:9`、`:42`、`:59`、`:72` | 控制目录或 Cluster member discovery 都不构成业务写资格 |
| 逐房间 lease epoch 永不删除重置；接管增长 epoch | `schema.sql:2800`；`Room/Activation/V2RoomActivationLifecycleSQL.swift:99`、`:105` | 一次批量 SQL 不等于分区租约；底层仍是一房间一行 |
| 当前事务先锁房间，再锁精确 activation lease，然后读 DB clock | `V2RoomOwnerTransactionFence.swift:65`、`:81`、`:98`；优化路径 `V2RoomActivationTransaction.swift:403`、`:425`、`:429` | 普通 SELECT epoch 或缓存 token 不能提供同等提交围栏 |
| 每活动房间创建 renewTask | `V2RoomActivationHost.swift:594`、`:610`；批量 renewal SQL 仍访问 rooms 和 room_activation_leases | 批处理减少往返，但管理规模仍是房间数 |
| 退休先 close/join executor，再 release DB lease | `V2RoomActivationHost.swift:733`、`:737`、`:741` | join 在线 RPC 不代表所有 Gateway 本地旧权限立即失效 |
| dirty 已从 pending 索引开始，但再逐候选匹配 host 的房间 lease | `PostgresV2RoomSubscriptionDirtyHeadStore.swift:36`、`:42`、`:49` | 扫描结果有界，不保证扫描工作只落在 owned 分区；其它 host/inactive pending 仍可能被遍历 |
| 订阅续期同时验证精确 token、H、roomControlVersion | `V2RoomSubscriptionOwner.swift:206`、`:219`、`:221` | 有执行权不能替代权限连续证明 |
| 同 H 控制变更经 fresh cut/terminal actual receipt 才完成 | `V2RoomSubscriptionOwner.swift:358`、`:372`；dirty CAS `PostgresV2RoomSubscriptionDirtyHeadStore.swift:103` | dirty offer、网络发送开始或 peer body ACK 都不能代替撤权完成 |

以上 Swift 路径除另注明外均位于 `IMV2Server/Sources/IMV2ServerInfrastructure`、`IMV2ActorContracts`、`IMV2ActorRuntime` 或 `IMV2ServerApplication` 对应模块。后续实施不得漏掉 `V2RoomActivationTransaction` 中优化的 single/cohort 路径，只修改公开 scalar helper 无法替换真实生产围栏。

## 3. 三个 namespace

**数据分片**决定在哪个物理 Database/schema 存储业务行。沿用控制目录显式房间归属与 rooms 上的 owner_epoch，数据搬迁才推进这层 epoch。改变执行宿主不能改 room_shard_id，也不能重新分布已有业务行。

**执行分区**是同一物理源/schema 内固定、版本化的 RoomID 映射，决定哪个已认证宿主有权执行。建议第一版使用 256 个分区，复用当前 `realtime_topic_partition('roomEvents', uuid::text)` 的稳定映射，避免新增不一致 hash。该函数实际是带版本/长度的字节 fold，不是语言 Hashable 或 SQL 预分配 id，见 `IMV2/sql/realtime-change-journal.sql:98`。合法 UUID 使用 SQL 小写文本与 Wire canonical key；用测试锁定跨语言结果。分区数或算法不能随着可用节点数变化；扩容通过重新分配固定分区，不重新 hash 房间。

**Journal 分区**当前用于 control 发布者、序号、消费者 coverage。即使数值映射相同，它的 publisher lease 也不能授予房间执行权。执行分区 key 应含物理 source_id/database_incarnation、schema、映射版本及 partitionID；执行 lease 与 Journal publisher/session token 是不同类型。物理源身份现有获取入口见 `GatewayJournalSourceCatalog.swift:45`、`:47`，数据库克隆不能复用另一个源的授权。

## 4. 新持久契约与 token（拟实现）

在每个物理 room 源安装固定数目的 `room_execution_partition_ownership` 行，主键是 mappingVersion/partitionID（表已处于 source/schema 作用域）。字段包括持久正整数 executionEpoch、hostID、hostIncarnation、expiresAt、phase、handoffNotBefore。无 holder 的行仍保存 epoch，禁止 DELETE/reseed 回到低 epoch。行完整性约束禁止不完整身份；epoch 溢出明确拒绝。

拟新增：

- `V2RoomExecutionPartitionID`、`V2RoomExecutionPartitionToken`、`V2RoomExecutionPartitionLeaseStore`。LeaseStore 提供 locate/acquire/renew/beginDrain/releaseExact，返回数据库观测剩余预算，不把本地墙钟作为授权。
- 房间执行 token 保留 RoomID、DataOwner，新增真实 partition token，并含宿主内部 roomExecutionGeneration。不要保留两个可独立授予执行权的 activation lease 分支。
- 同一分区 incarnation 内，每次恢复房间从分区本地单调 generation allocator 取得新的 generation；跨房间共用计数器即可，无需逐房间 DB 续租/永久 tombstone。旧 room executor 必须 close/join 后才可替换。该本地 generation 防缓存 ref/晚包混用，不是数据库租约，DB 不宣称凭它判断房间恢复代次。
- Gateway fence 比较顺序为 DataOwner epoch、同映射分区的 executionEpoch、同 host incarnation 的 roomExecutionGeneration，再到 shared subscription generation。相同 executionEpoch 的不同 host 为冲突，不能按 host 字符串/UUID 排序为“较新”。partition 改映射或迁移必须经 DB 目录裁定。

Host 收到分区并完成恢复资格后才向 Directory 返回房间 token。cached ref 只省去重复 location lookup；每次业务事务仍检查实际 DB 分区围栏。用户身份、authenticated callerGateway、serviceOwnedShard、成员权限等认证全部继续执行。

## 5. 事务内 epoch 围栏与接管证明

推荐第一版使用 Read Committed 的短业务事务。按 `(source, schema, mappingVersion, partitionID)` 去重排序，先对涉及的 ownership 行 `SELECT ... FOR SHARE`，再按 RoomID 排序取得现有 rooms 业务行锁。取得全部 ownership 锁后读取 `clock_timestamp()`，比较完整 source/分区/epoch/host incarnation/phase/有效期；然后验证 rooms 的 DataOwner 与确定性分区映射、执行业务写入、写入同事务 canonical dirty/control 责任，最后提交。所有锁持有到实际 commit/rollback，数据库 loan watchdog、lock/statement timeout、提交结果 unknown 分类与实际 join 沿用当前物理事务 helper。

分区 acquire/renew/drain/release 用 `FOR UPDATE` 或等价冲突 UPDATE，在取得行锁后读 DB clock。租约仍有效且非合法已完成 drain 时，其他 host acquire 返回 occupied；过期或允许交接时，推进 executionEpoch 后授予新 host。续租只允许 exact 当前且未过期 holder；已过期 token 必须新 acquire，不能恢复旧 epoch。unknown outcome 不授予额外期限，须重新定位。

共享 ownership 锁允许同分区不同房间的普通业务事务并行；不能给每条消息 `FOR UPDATE` 同一 ownership 行，否则会把整个分区串行化。`FOR KEY SHARE` 也不足，因为常规 epoch/expiry UPDATE 未必改变 key。续租的 UPDATE 会短暂与共享业务锁冲突，这是第一版必须真实测量的成本，不声称免费。

证明是提交顺序：旧业务事务持有共享锁时，新 epoch 的接管事务不能提交；新 epoch 已提交后，新的旧-token 事务读取当前冲突行并被拒绝。等待锁期间越过 expiry 的旧事务也要在取得锁后读取 DB clock 再拒绝。只在事务前或 MVCC 快照里普通读取旧 epoch，会允许“旧事务读 E → 新宿主提交 E+1 → 旧事务提交业务”的反例。不要用网络健康检查修补该反例。[PostgreSQL 16 锁规则](https://www.postgresql.org/docs/16/explicit-locking.html)说明共享行锁与 UPDATE 的冲突及持有到事务结束；[Read Committed 规则](https://www.postgresql.org/docs/16/transaction-iso.html)说明等锁后目标行可更新，RR 的旧 cut 不能代替新授权。

单事务 room/log/idempotency receipt 等仍原子提交。发送 ACK 依赖业务提交和持久责任，不等待 Gateway fanout。这里保证旧写与接管的提交排序，不保证在 DB expiry 墙钟的精确瞬间强行中断已持锁事务；期限/watchdog 限制其尾部，接管只能在该事务实际结算后完成。

## 6. 写路径覆盖及本地房间恢复

需要同时替换：scalar `v2RequireRoomActivation(s)`、configured single/cohort transaction、`V2RoomActivationWriteScope`、restoration validator、Factory 内所有 send/mutation/reaction/membership/admin/receipt/forward/recovery 写入适配。多房间 cohort 先锁分区再锁房间，不能保留旧 room→partition 的相反锁序。跨物理数据库继续原有分库结果/unknown 规则，不伪造跨库原子提交。

新建房间尚没有 rooms 行时，从将要创建的 UUID 确定分区，先验证真实 creation service 的 shard 权限与分区 token，再在该事务插入带正确 DataOwner 的业务行/目录责任；不能以“无房间可查”为由绕过 ownership。后台维护若写同一业务域，也要使用明确的 owner token 或独立的受限 maintenance 权限，不能默认为拥有所有 room。

本地 room eviction 不释放分区所有权；先关闭 room admission、join DB/work/pump，再替换 generation。分区失权一次关闭该分区所有 room admission，join 所有实际任务，保持其余分区工作。closeAndRelease 的既有顺序可复用，但层级从 room entry 移到 partition owner；SQL task 被逻辑 remove 不等于 join。

本方案的 DB 围栏保证针对全部生产受控写入 API。持有数据库任意 SQL/admin 权限的进程不是新 token 的认证主体；如果还允许旧二进制/绕过 helper 的 writer 与新模式共存，仅修改 Swift helper 不足。迁移必须停旧进程并由 schema readiness 拒绝旧协议；若部署要求在数据库层拒绝任意绕过入口，实施时必须加 mandatory 写触发器/受限存储过程和角色权限，不能在测试里只拒绝 Actor RPC 后声称原始 SQL 同样被拒绝。

## 7. 权限与 Gateway 授权仍是另一条证明

现有 snapshot 在同一 MVCC cut 读取 H、成员状态与 roomControlVersion，另外 fresh 检查 exact activation 和 DB clock，取 old-cut/fresh-proof 预算较小值再减全程 elapsed，见 `PostgresV2RoomSubscriptionSource.swift:213`、`:229`。新实现把其中房间执行 lease 检查换成 exact partition lease，保留一致 cut 和保守期限。初次 subscribe/reset 仍读取实际成员；subscribe→Gateway trusted install→activate 两阶段不能省略。

分区 lease 的剩余预算是用户 grant 的上界，不是用户 grant 本身。正常角色/成员控制有连续 room-log 证明时逐用户 revoke；同 H 或缺失历史控制无法证明时，仍保留 ordered authorizationInvalidated，等待实际 Gateway receipt 或已安全过期的旧 budget。终端发送开始不完成 dirty。租约过期/needsBaseline 后必须 trusted reset，不能拿同 fence 或更大的 H 恢复 Ready。

计划交接需特别处理外部授权：executor/pump join 后，Gateway 本地旧 permit 仍可能活到原保守 deadline。第一版 release/beginDrain 应保存 `handoffNotBefore >= 原 DB lease expiresAt`，除非已经逐 shared fence 收到 terminal actual receipt 的完整证明；不以“close 返回”直接把外部窗口置零。接管最迟等待原授权窗口到期，预算有限；崩溃接管也等 expiry。不要把新 partition epoch 当作旧 Gateway 已即时获知的撤权通知。

## 8. 从逐房间证明到按变化维护的最终路径

ownership 第一阶段上线后，当前 `PostgresV2RoomSubscriptionSource.leaseProofs:322` 仍逐 active room 读取 H/controlVersion；把 lease JOIN 改成 partition JOIN 只能消除逐 room lease 行，不能消除逐 room权限 proof。该保守过渡可交付，但必须保留待退出事项。

最终建议在唯一 canonical 控制源的既有分区元数据中添加 **已提交 control generation**，不新增重复 outbox。room/member control 的原业务事务同步更新该分区 counter 与原 control outbox/dirty 行。counter 用普通持锁行 UPDATE，不能用 nextval/MAX 提前分配 id。跨分区控制事务固定锁序；body-only 事务不更新这个 counter。它是验证“没有漏掉已提交权限变更”的低维 cut，不是执行租约、用户授权或 Journal 已发布序号。

分区消费者从 owned partition 的 pending partial index 按公平 limit 取实际变化，exact epoch pin 后调用当前 Source/Owner 连续 ingest 或 fresh cut/terminal 路径。dirty CAS 比较 H/controlVersion/revision 与 exact 分区 epoch，旧宿主无权清新责任。对应 room permissions 已 processed 且要求的 terminal receipt 已完成后，才在一致 cut 确认该 generation 以内没有未完成控制责任，推进本地 appliedPartitionControlGeneration。后来的 commit 必须使 fresh DB generation 不同；不可因一次查询“当前没有 pending”就延长未知权限。

一个物理 host 的周期 proof 批量读取其 partition leases + fresh control generations。只有 local applied generation 等于该 fresh committed generation、exact holder live、该共享用户/fence Ready 且其权限 control ACK 满足时，才允许延期已存在 grant；初次或 stale/reset 仍走成员 snapshot。该全局 cut 会保守阻塞同分区未受影响用户的轻续期，但开销与分区数增长，后续可优化而不放松证明。Journal `published_through` 不能直接当 fresh committed generation：事务已提交但 outbox 尚未发布的控制必须阻止延期。

pending 查询应按具体 owned partitionID 的索引 range seek，不能先扫所有 pending 再逐房间 lease/host 过滤。若一个 room 无订阅/无本地 Actor，不新建长期 room task；责任可保持 pending，或经受限临时 fresh cut 在证明没有仍活跃旧外部 grants 后完成，H/controlVersion 仍保留在 durable 行/业务记录中。该 inactive 策略需独立真实测试，不能把“当前 entries 没有它”当成没有权限持有者。

## 9. 迁移、退出与验收顺序

1. 完成新 DB schema/token/lease store、DB 并发围栏测试及严格 readiness；不要默认启用新分区 token。
2. 显式维护窗口停止并 join 旧 room runtime，等待旧外部 grant 的安全预算或完整终端确认；保留所有 rooms/log/memberships/canonical dirty。用有限事务安装固定 mapping/epoch 行与新 mode，作一次 dirty responsibility 转移。
3. 同一次部署切换 Directory、签名 Actor RPC、Client/ref、Factory/write scope/事务 helper、Source、Relay/Gateway fence 到新契约。读 token 与写 token 不允许独立开关。旧 token 明确 stale，旧二进制 readiness 拒绝。禁止同时跑逐 room lease 与 partition lease 两个自主所有者。
4. 新 Host 每分区拥有一个有生命周期/背压的 owner、批量 renew/checker、bounded room map 与唯一变化消费者。停止 `V2RoomActivationHost` 的每 room acquire/renew/release producer，以及 Source/dirty 对 room_activation_leases 的所有 JOIN；过渡权限 H/control probe仍留并明确计数。
5. 按第 8 节提交 fresh control-generation 证明，关闭周期全 registered room probe；只保留订阅/真实变化读取与故障重建，证明通知全部丢失也能 indexed repair。
6. 观察并通过退出断言后，显式清理旧 lease 表/旧 mode adapter/旧配置/旧 schema readiness；不是只把旧任务设置 nil。legacy room wake 退出使用已有 publication migration，不再加第二套 outbox 或 per-Gateway room scanner。

旧 room lease 表保持期间只供审计，不能续租或作为 fallback 权威。迁移不需要保留旧 wire 兼容，但需保证保留业务日志与规范 dirty 责任，回滚部署不能重用更低 epoch。若要退回旧结构，需要新的显式迁移和全新执行授权，不能仅切配置。

## 10. 必须通过的测试与验收计数

- **真实 PG 同分区多房间并行：** 两个业务事务可同时持 ownership SHARE；同 room 顺序仍串行。记录阻塞/查询计划，拒绝把 partition FOR UPDATE 的串行实现当成功。
- **真实 PG 接管交错：** 持有旧 writer 到 commit，接管须等其结算；接管提交后旧 token 的单条、batch/cohort、membership/mutation/receipt/forward 等每个生产路径拒绝写；等待锁跨 expiry、过期 renew、旧 release、wrong source/partition/host incarnation 都拒绝。
- **unknown outcome / 生命周期：** acquire/renew commit reply loss 不延期旧 budget；DB cancellation、late completion、partition drain join、一个分区死亡不停止其它分区；room eviction 旧 generation 不再执行或发包。
- **真实权限链：** 同 H remove/role controls、通知丢失、control commit 未发布、held terminal RPC、旧 permit socket submission，证明 ownership proof 不能延期旧权限；正常连续 new-H 成员控制不全量 reset。
- **索引与规模：** 其它 host/partition 大量 pending 不能成为 owned 查询主扫描；bounded/fair limit 不饿死冷分区。扩大活动房间数而 owned 分区不变时，执行 renew DB 行数/后台 task 数不随房间线性增长；最终权限 proof 也需单独证明不随全部房间增长。
- **迁移真实数据：** 旧 pending/leased wake 与同 H control责任转移、不删 businesshistory、stale CAS不清newcommit、重复安装不backfill、旧协议/混合模式拒绝、timeout整体回滚。
- **真实 TCP 多宿主：** 有实际流量的故障目标房间；冻结 Server/Account/Loader；foreground 无客户端 pull/retry/grace；所有 ACK、客户端最终游标、notification discard/repair、actual host takeover、旧 host写拒绝均有低基数 witness。只有最终 quality 通过且目标真的持有并处理过业务，才计宿主故障通过。

第一阶段验收不能宣称“零逐房间维护”，第二阶段没有 fresh committed control generation 与实际撤权完成证明则不能撤掉权限 probe。这个限制来自当前权限链的安全条件，而不是 Actor transport 的实现偏好。

## 11. 当前审查引用索引

以下是本次实际读取的工作树文件，行号指向关键入口；新设计类型与表未列作已实现事实。

| 文件 | 关键行 |
| --- | --- |
| `IMV2/sql/schema.sql` | 1919 rooms；1960 显式数据路由；2800 逐房间 lease |
| `IMV2/sql/realtime-change-journal.sql` | 98 topic 映射；107 控制触发器 |
| `IMV2Server/Sources/IMV2ActorContracts/V2RoomActivationIdentity.swift` | 35 DataOwner；65 host；78 token；100 比较规则 |
| `IMV2Server/Sources/IMV2ActorContracts/V2RoomActivationLeaseStore.swift` | 25 持久权威；29 协议；41 过期续期规则 |
| `IMV2Server/Sources/IMV2ServerInfrastructure/V2PostgresRoomShardRouter.swift` | 34 单房间显式路由；56 批量目录 |
| `IMV2Server/Sources/IMV2ServerInfrastructure/PostgresV2RoomActivationStore.swift` | 19 构造；42 acquire；59 renew；72 release |
| `IMV2Server/Sources/IMV2ServerInfrastructure/V2RoomOwnerTransactionFence.swift` | 65 多房间围栏；98 锁后 DB clock；142 scalar围栏 |
| `IMV2Server/Sources/IMV2ServerInfrastructure/Room/Activation/V2RoomActivationTransaction.swift` | 329 cohort rooms；373 cohort leases；403/425 单房间优化围栏 |
| `IMV2Server/Sources/IMV2ServerInfrastructure/Room/Activation/V2RoomActivationLifecycleSQL.swift` | 60 房间锁；70 lease锁；99 acquire；175 持久变更 |
| `IMV2Server/Sources/IMV2ActorRuntime/Lifecycle/V2RoomActivationHost.swift` | 594 per-room renewTask；603 保守deadline；610 renewLoop；733 closeAndRelease |
| `IMV2Server/Sources/IMV2ActorRuntime/Client/V2RoomDirectory.swift` | 54 transport；277 有界 location解析 |
| `IMV2Server/Sources/IMV2ServerInfrastructure/PostgresV2RoomSubscriptionDirtyHeadStore.swift` | 36 pendinghost查询；103 exact CAS |
| `IMV2Server/Sources/IMV2ServerInfrastructure/PostgresV2RoomSubscriptionSource.swift` | 213 fresh leaseproof；229 readLease；322 批量逐roomproof |
| `IMV2Server/Sources/IMV2ServerApplication/V2RoomSubscriptionOwner.swift` | 206 renew；221 H/controlversion匹配；358 processControlCut；372 terminalcompletion |
| `IMV2Server/Sources/IMV2Server/Composition/Room/V2RoomServerActivationFactory.swift` | 740 hostchecker；783 独立执行proof与变化分开 |
| `IMV2Server/Sources/IMV2ActorContracts/Realtime/V2RoomSubscriptionWire.swift` | 5 fence；8 actual activation |
| `IMV2Server/Sources/IMV2ServerGateway/Gateway/V2GatewayRoomSubscriptionAuthority.swift` | 191 actualtoken较新/冲突规则 |
| `IMV2Server/Sources/IMV2ServerApp/GatewayJournalSourceCatalog.swift` | 45 readiness；47 物理源身份 |

仅此文档是本轮新增编辑。后续实施和验证交由 root 在用户重新授权继续后分配。

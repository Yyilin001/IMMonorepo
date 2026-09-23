# Room Actor 组合与真实数据库阶段证据

本页记录已经执行的局部验证。Gateway 与 Account App 已切换并编译，真实远端业务探针已通过；G2–G5 的完整验收仍在进行。基线是 `f1cdd78d6a21bf0ae23da627c0710c65115236aa`，不使用原工作目录的 Distributed Actor 实验。

## 具体执行器与恢复

`b06c9f3` 接入 `V2RoomServerActivationFactory`、owner resolver/lease-store adapter，以及发送、消息修改、房间管理、查询、回执、邀请、特殊账号审计的实际数据库 handler。每个物理 owner 共享池和 batcher，每次激活恢复 handler 并验证持久 token；没有把成员或策略快照当作永久权威。Server 依赖 Runtime，Runtime/Cluster 不依赖 Server。

实际命令使用两个独立 disposable PostgreSQL 16 数据库，原生 Swift 6.4、jobs=2：

```sh
swift test --package-path IMV2Server --disable-automatic-resolution -j 2 \
  --filter 'actorFactoryRestoresSendAndQueries|actorCreationDraftReadiness|V2ActorAuthenticationTests'
```

`/tmp/imv2-va-factory-final.log`，退出 0：Server 2 项、认证 8 项通过。Host + 真实 SQL 验证发送、恢复状态查询、非成员日志拒绝、退休、新 incarnation/更大 epoch 恢复同一 clientMessageID，仅存在一条消息。该测试在同一进程内直接调用 Host，不是 Cluster 远端业务证据。认证测试包含普通网关不能伪造邀请 control grant、协调服务可以提交，以及直接 `.create` 不能绕过 control intent。

测试使用当前创建合同的正数 membership revision；通用历史写入 fixture 的零 revision 不能用作房间恢复测试的有效初始状态。

`V2ActorGrantedSendBatchAdapter.retire(token)` 的 Factory close 接线已加入上述提交，随后与 D6 统一入口另行编译验证；不把此前通过的测试误记为该新增一行的验证。

## 合批与旧 token

`33107986` 合入有界 activation 追踪、未知 SQL 结果隔离、同房间 scalar/partition fallback 保序及真实数据库测试。数据库测试发现 large-group PostgreSQL 优化支路仅在配置 ownerRoutes 时调用 fence，导致只有 activationScope 的调用绕过校验；`0e8307d` 修复该条件。

子代理在独立 PostgreSQL 16 的两个数据库执行 `--filter actorGranted`：4/4、退出 0。覆盖同房间 3 次发送一个原子批、同 owner 两个房间一个原子批、旧 token 混入时整个批次零写入，以及 COMMIT 阶段错误时后继请求不再使用该 token 执行。独立 batcher 10/10、既有 send service 27/27 通过。deferred COMMIT trigger 实际使事务回滚；它证明不确定结果的隔离路径，不能证明“提交成功但响应丢失”。

## 控制面创建与审计

`daa6c13` 将 canonical schema 升至 `im-v2-current-53`。控制库中的 group creation draft 不再外键引用本地 `rooms`，允许房间建在另一 owner 数据库；完成状态仍要求非空 roomID。readiness 和 schema drift 检查会拒绝重新引入该本地外键。`/tmp/imv2-va-cross-owner-schema.log` 的全新 bootstrap、导出/恢复与 drift 检查退出 0；Factory suite 也实际验证 readiness 拒绝错误外键。

`cb67b0b` 的特殊账号审计，在操作锁后、重放或写入前验证完整 token。真实 PostgreSQL `activationSpecialAccountAudit` 1/1 通过，日志 `/tmp/imv2-va-audit-postgres.log`：发送后记录审计，旧 token 的审计重放被拒，继任 token 恢复同一审计且没有重复操作行。该用例没有独立验证旧 token 的全新审计请求。

D6 的独立维护与压缩竞态证据见 [后台维护验证](d6-maintenance-evidence.md)。转发所有阶段的 scoped import hook 已提交 `8ed6f7f`，跨库实际执行仍由 D5 的专项验证补齐。

## 后续集成回归

- `9183524` 将 D6 维护能力加入总 Request/Response、Factory 和独立 `roomMaintenance` 服务权限。`/tmp/imv2-va-client-maintenance-integration.log` 退出 0：Gateway/batcher/maintenance suites 共报告 77 项、认证 9 项通过。该次没有 PostgreSQL 环境变量，maintenance SQL 用例入口跳过数据库部分，不能计作数据库验证；数据库证据仍以 D6 专项页为准。
- `9361e47` 清理 recovery batcher 已完成/取消的用户定时器键，改用不可复用的 UUID 识别晚到回调；标量已读旧 token 从每行 store error 恢复为 Runtime stale-activation failure，批量逐行结果合同不变。`/tmp/imv2-va-receipt-stale-timers-postgres.log` 的真实数据库 query/receipt suite 7/7、退出 0。
- `84d9ded` 增加发送/编辑/撤回/表态的逻辑 RoomRef 门面。`/tmp/imv2-va-clients-lifecycle.log` 的新门面与定时器生命周期测试 3/3、退出 0。
- 集成上述 batcher、Factory close/retire 与 D6 dispatch 后，使用实际两个 PostgreSQL 数据库运行 `--skip-build --filter 'actorGranted|actorFactoryRestoresSendAndQueries|actorCreationDraftReadiness'`：`/tmp/imv2-va-factory-granted-current.log` 6/6、退出 0。

文档链接、结构检查与 `check_v2_virtual_actor_inventory.py` 已通过。新的生产路由仍在接线，这些结果不关闭 G2–G5。

## Gateway 生产接线阶段

`9de9bd7` 将 Gateway 现有房间命令、状态/最新可见查询、转发源端准备/回执和目标导入、内容审核执行、日志保留及房间簿记清理接到 RoomRef/预约协调器。创建通过封闭 bootstrap port 与固定控制面意图；没有为未知 roomID 隐式创建普通 Actor。多物理 owner 共享各自的数据库池、信用池及 granted batcher。现有工作流队列认领、媒体复制和用户投影仍使用其独立的权限/租约。

应用现在需要 `IMV2_ROOM_ACTOR_CONFIGURATION_FILE` 指向有界 JSON 信任配置。`IMV2ActorApplication` 封装私有 CA 的双向 TLS、服务签名、固定 peer/shard 映射和自动发现；Account 使用独立 caller-only node。关闭必须同时等待 Directory 的真实 owner/lease 查询和 Cluster/Host 的实际调用完成，超时不释放底层池。

实际验证：

- Gateway target build：`/tmp/imv2-va-gateway-live-composition.log` 和显式 PostgresKit 依赖后的 `/tmp/imv2-va-gateway-postgreskit-dependency.log`，均退出 0。
- `--filter 'IMV2ActorRuntimeTests|IMV2ActorClusterTests|IMV2ActorApplicationTests|V2GatewayRoomActorCompositionTests|V2GatewayDomainCommandHandlerTests|V2RoomRefClientsTests'`：`/tmp/imv2-va-gateway-actor-integration.log` 退出 0。Server 74、Runtime 49、Cluster 21、Application 2，共 146 项通过。Cluster 包含真正网络传播与同端口连续重启，但仍在一个 OS 进程中。
- 已读 candidates 改造后再次设置实际 disposable PostgreSQL 16 URL，`--skip-build --filter V2ActorRoomQueryExecutorIntegrationTests`：`/tmp/imv2-va-receipt-candidates-postgres.log` 7/7、退出 0。此前误用环境变量名的一轮没有运行 SQL，不纳入数据库证据。
- 独立事务 primitive `2713985b` 的 PostgreSQL 16 用例覆盖连接池等待、累计语句总截止、锁等待、取消及 COMMIT 阶段分类；全部 scoped store 的实际接线仍在进行。

目前没有完整 Gateway TCP + Account HTTP + 多进程故障闭环验收。房间日志的 prepared-page 快路径暂时返回经过 RoomRef 授权的普通页面；多个物理 owner 的 batcher 指标汇总、现有多 lane 性能参数与读回执合批等仍需在 G5 对照基线确认，不能据上述功能测试宣称性能不退化。

- 巨型消息存储唯一事务 wrapper 已传入 `useRoomDeadline: activationScope != nil`，因此标量发送、同库转发、跨库 import 各阶段与原子批次进入独立的有界事务。`/tmp/imv2-va-giant-sql-deadline-postgres.log` 退出 0：5 项真实 PG 写入/Factory 用例通过；同次 primitive suite 缺少其专用变量而跳过，不计入。随后用 `IMV2_ACTOR_TRANSACTION_DATABASE_URL` 与 `IMV2_ACTOR_TRANSACTION_TEST_DATABASE_IS_DISPOSABLE=1` 重跑，`/tmp/imv2-va-deployment-transaction.log` 的 primitive 1 项（内部 8 场景）实际通过。
- [本地配置生成器与应用启动配置](i1-deployment-configuration.md)生成私有 CA、每节点独立密钥与固定拓扑。OpenSSL 校验两份叶证书通过；设置 `IMV2_ROOM_ACTOR_TEST_DEPLOYMENT_DIRECTORY` 后 Application 3/3 测试实际读取生成文件通过。没有运行或重建用户的本地 Compose 服务。

## Account 与独立进程业务验证

`31f03b3a` 将 Account 的邀请、昵称更新和消息媒体可见性检查接到 caller-only Actor node。邀请创建仍经过控制面意图；媒体下载在捕获、签发、认领、完成及返回 provider URL 前重新检查房间可见性、控制面设备状态与当前 owner route。非消息下载继续使用原有媒体服务。Operator 只处理独立工作流队列与控制面操作，因此没有创建空置的房间 Host。

子代理独立 PostgreSQL 双库用例验证正常下载、provider 执行期间可见性撤销、设备撤销及 owner route 变化，4/4 通过；邀请恢复/审批竞态及 Vapor 路由用例通过。Account 与 Operator target build 均通过。日志保留在 `/Users/yyl/.codex/virtual-actor-builds/p0/i1-account-build-final.log`、`i1-operator-build.log`、`i1-invitation-test.log`、`i1-actor-invitation-test.log`、`i1-account-test-final.log`。这些结果没有包含真实 Account HTTP 进程的启动测试。

`92f782c1` 的[真实业务进程探针](g4-business-probe-evidence.md)使用实际 Application/Factory、签名发现、私有 CA mTLS 和 PostgreSQL。调用进程保持存活，Host 被 SIGKILL 后等待数据库租约到期，再以新 incarnation/epoch 启动；同一 clientMessageID 重放得到同一 messageID，数据库仅一条消息，旧 token 新写被拒，订阅资格与日志水位恢复。原生执行退出 0；Linux 版本正在独立验证。

## 事务期限与合批窗口收口

`14e0b544` 将同一调用的绝对截止时间传入 Factory 恢复/执行、granted send、recovery batch、租约及其余 scoped SQL。批次采用实际参与项目的最早调用截止时间。每次重试重新借连接，不能重新获得完整时间预算；只有已证实回滚的失败可按未接受结果返回，COMMIT 无 ACK 保持 unknown。根集成工作区 `/tmp/imv2-va-final-sql-integration.log` 退出 0：真实 PG 事务期限 1 项（内部多个故障场景）、RoomRef 门面 9 项、聚合指标 2 项，共 12 项。

`a53fb2f5` 在媒体控制 SQL/owner route await 的成功及抛错之后复查取消和原截止时间，并在最终 URL 返回前复查；子代理真实双库媒体 5 情景通过，包括 provider 跨越调用期限。`9bdd36cc`/`888fed4b` 将所有物理 owner 的发送指标作为只读快照聚合，最多并发采样 8 个 owner，不提供虚假的消息准入入口。

Runtime 现在立即派发已排队的连续发送，物理 owner batcher 消耗唯一合批窗口，仍以第一次入队时刻为上限。原实现先在 lane 睡满窗口，导致 host 收到的 deadline 已过；这会使跨房间和 adaptive 合批失效。App 的窗口从现有发送/高活跃/回执配置取最大值，各 batcher 继续使用自己的较短延迟。`/tmp/imv2-va-single-batch-window.log` 退出 0：Runtime lane/预约 19 项与读取实际生成配置的 Application 3 项通过，包括 FIFO 屏障、执行中取消/unknown、预约超时，以及新请求把剩余窗口交给 host。

`c1ae992d`/`a76252a9`/`2315618` 恢复 Host 回执合批和发送多 lane/adaptive 配置。关闭 append batch 的原配置 0 映射为单条 scoped SQL，不再被静默转成大小 2。回执在真实批次处获取一次数据库许可，各项保留自己的 ingress 时间、token 和调用截止；组/私聊的多事务处理中若发生无法归属的失败，全批保持 unknown。`/tmp/imv2-va-host-batching-integration.log` 退出 0：Server 15 项、Runtime 13 项通过，Gateway/Account 产品也参与构建。`/tmp/imv2-va-owner-batching-postgres.log` 退出 0：实际 PG 多 lane 同库原子批、回执 stale/有效 sibling、Factory send→receipt→recovery、昵称旧 token/接管共 4 项通过。

`/tmp/imv2-va-candidate-mutation-fences.log` 实际运行特殊账号审计与编辑/撤回/表态 3 参数场景。该次昵称因缺少其专用环境变量被跳过；随后上述 owner-batching PG 日志正确设置 D2 变量并运行通过。CI 的既有串行 PostgreSQL step 已显式启用 D2/D4/D5/事务期限专用 URL 与 disposable 开关，不能把默认跳过当作验收。

入口审查新增 W30：审核审计副本原来只在控制库清理，遗漏其他 owner。新的 OwnerModerationAuditRetentionStore 使用所有 physical owner 的维护数据库、每轮共享行数预算与轮换起点。该副本不用于 Actor 恢复/幂等，过期清理保留为明确的外部例外。`/tmp/imv2-va-owner-audit-retention.log` 退出 0：既有维护时钟/参数委托及新多 owner 预算/失败公平性共 5 项通过；没有把这些内存 store 测试写成 PostgreSQL 验证。

## Host 数据库准入与成功 COMMIT 丢回执

Gateway RoomRef 入口不再占用等待 Host 的数据库许可。普通房间读写在物理 Host SQL 边界准入，send/receipt/recovery 按实际批次准入，同库 forward 在两个 reservation 获批后准入。Account 调用与 Gateway 调用使用同一 Host 约束。receipt 等待许可沿用原调用截止时间；较短策略等待超时报 overload，调用期限耗尽报 deadlineExceeded。

根工作区 `/tmp/imv2-va-final-admission-wiring-verified.log` 退出 0：4 suites、76 tests，包含真实 PostgreSQL 成功 COMMIT 丢 ACK。测试代理观察 PostgreSQL 的 COMMIT CommandComplete 后截断回执，生产 scoped send 返回 V2RoomTransactionOutcomeUnknown；独立连接确认消息/completion 各一行，原操作 ID 重放返回原 messageID，事件仍一行。新 ACK-loss suite 已显式接入 CI 与隔离 Linux 数据库环境。该结果不代替多房间 shared-batch 丢回执和完整进程故障矩阵。

## owner 激活身份容量

`19046774` 将所有 send lanes 的 activation token 容量合并为 owner 共享硬上限。单 lane 与多 lane 都保留已完成身份，直到 Host 清理对应 credit pool 后 exact retire；未知结果和仍在执行的退役身份继续占位，旧 epoch 不释放新 token。独立 native 新容量测试 4/4、granted 回归 20/20 通过。deadline 回归分别验证 Host 合批窗口先到时执行 SQL、调用截止先到时返回 typed 拒绝且不进入 SQL；没有放宽生产截止时间。Linux 集成结果随后登记。

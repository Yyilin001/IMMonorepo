> 2026-10-06 消息 Owner SQL 合并：普通单聊已合并最终幂等读取与房间预检，并将消息、完成事实及协议回执合并持久化；详见本文末尾“普通单聊 Owner SQL 合并”节。

> 2026-10-06 最新实现：权限读取已改为不带租约的版本化内存快照，变更主动推送；本文件中的周期续租、失效后重拉和冷加载调度描述属于此前实现。见 [完整改造与验证](policy-versioned-memory-snapshot-implementation.zh-CN.md)。

# 消息发送调度重构落地记录

> 2026-10-06 权限热路径修正：节点共享 scope 缓存已接入，首次加载后本地复用，提交后通知失效，后台续租。实现与验证见 [节点权限缓存说明](policy-node-memory-cache-redesign.zh-CN.md)。此前 R23 为修正前的性能记录，本轮尚未重新验证容量。

日期：2026-10-05。基于本地工作树，未提交；仓库已有的大量修改保留。本文件只描述此次修改与验证，不将 HEAD 的其他差异归为此次工作。

## 当前边界与待完成要求（2026-10-06）

当前新增工作遵循用户再次要求的范围收敛，仅处理授权内存状态。核验发现 `V2HostRoomReceiptBatcher` 仍会组合不同房间的请求：可控执行屏障下，peer 回执等待 slow 房间，复现测试在 `/tmp/imv2-receipt-room-isolation-before.log` 实际 exit=1（2 个问题，2.005 秒）。这属于原链路方案尚未完成的跨房间耦合问题。本轮未修改生产回执实现；新加的失败测试撤出当前测试集，其草稿保存为 `/tmp/imv2-deferred-receipt-room-isolation.swift`，不是通过或修复证据。重新进入回执工作时应恢复复现并修复，不能据此宣称所有房间互不阻塞。

下文按实施过程保留历史记录。旧 registration、房间撤销等待的实现记录不代表当前授权目标；当前账号、关系、陌生人设置边界以 [授权内存状态](policy-memory-state-redesign.zh-CN.md) 为准。当前装配选择 `roomDrainRequired: false` / `usesCurrentState: true`，已提交且仍有效的状态在修改事务期间继续可读；新修改成功提交并发布内存后再回复。

原消息链路重设计没有因此缩减为缓存改造：

| 原方案要求 | 当前证据与尚待完成的工作 |
| --- | --- |
| 房间唯一写顺序、各类有序 writer、同房间批处理边界 | 已保留 `V2RoomTurnLane` 并有发送与屏障回归；全部 writer 的逐项覆盖与唯一顺序职责仍需完整核验。 |
| 不同房间准备独立推进、保留命令/字节/截止/实际任务责任 | 单房间准备任务已落地；R15 暴露冷状态等待占满准备器 128 个任务槽。现已接入分阶段准备，预读与内存探测结束后将缺失状态注册到冷队列，保留原命令/字节/房间/截止；生产发送与局部取消、关闭测试通过。R16–R18 已重跑，R18 冷状态队列平均等待仍约 2.30 秒，容量失败尚未解决。 |
| 物理数据库公平代理统一准入与连接租借 | 已按物理配置共享预算，Owner 等待需求与执行分开；准入和实际连接租借仍有两个边界，统一代理尚未完成。 |
| 单房间短事务、稳定身份/回执/围栏、取消和未知提交 | 有实际 SQL、响应丢失、恢复及关闭回归；仍需按原方案逐项核验全部入口，不能用授权测试代替全链路证明。 |
| 有界提交后投递、慢房间/目标 Gateway/客户端及重连隔离 | 保留已有持久责任与独立 worker；原方案列出的全部负载与隔离验证尚未完成。 |
| 10,000 在线、1,000 新消息/秒、共同 60 秒窗口及质量/游标/资源结算 | 用户随后要求先测试性能，最新 R23 启动时 10,000 连接就绪，11/12 loader 最终报告，完整共同窗口为零；已知区间约 20 秒，局部 ACK 12,888 / 发送 18,312，p95 8,575–8,958 ms。quality/steady/drain 失败，清理 settled=true 但一台 Gateway 强制 kill；容量目标未通过。R21/R22 暴露的 Release 通知回调栈溢出已修复，独立 Release 回归通过，不能替代容量证明。详见 [本次性能记录](performance-10000-online-1000msg-20261006.md)。 |

局部测试通过只证明其覆盖的边界，整体目标仍实施中。授权模块的真实环境部署切换、传播和故障接管不是用户当前要求的完成条件。

### 房间等待 FIFO 的索引化

核对生产 Host：普通请求经 `V2RoomActivationHost.invoke` 进入对应 activation 的 `V2RoomTurnLane`；仅具体 `.roomLog(.pull)` 可走受 lifecycle pin 保护的纯读取旁路。`turnSchedulingClass` 只将 durable send 与有效 profile visibility 请求归为可共享 turn，其余请求作为屏障。跨房间协调使用 `reserve` 进入同一 lane 的 FIFO 屏障。这是入口结构的核对，尚不能替代全部 writer 的数据库锁顺序审计。

发现 Lane 等待队列仍使用数组，头部出队搬移剩余条目，排队取消扫描并搬移数组。本轮替换为 lane 内按请求 UUID 索引的双向 FIFO：头部出队与按 ID 取消不扫描剩余队列；合批只检查当前 `maximumCommandsPerTurn` 内的已有请求。执行中条目、未知结果、reservation 及原始截止继续由 Lane 保留，未增大任何命令或字节上限。

新增 `indexedQueueWithdrawalOrder` 在执行屏障阻塞时依次取消排队头部、中部、尾部，验证剩余请求 ordinal/FIFO、实际单 turn 执行以及只释放取消请求的预算。重新构建（44.62 秒）后 `V2RoomTurnLaneTests`、`V2RoomActivationHostTests`、`V2RoomCommandBudgetTests` 共 55 项测试通过（1.032 秒），日志 `/tmp/imv2-room-indexed-queue-tests.log`，实际进程 exit=0。受影响文件 diff whitespace 检查通过。

该修改消除等待队列的线性搬移/取消扫描，未证明吞吐提升。Lane 当前仍有每条等待请求的 deadline task，统一最近截止唤醒尚待落实；物理数据库代理与完整容量验收也仍未完成。本轮没有运行压测或真实环境部署。

### 房间统一截止唤醒

继续替换原 Lane 的逐条 deadline task：命令及 reservation 使用按请求 ID 索引的最小堆记录截止，入队/取消/完成按 O(log n) 更新，不积累已取消的堆记录。Lane 仅保留一个当前截止唤醒任务；更早的新截止替换旧唤醒，旧回调凭 generation ID 失效。取消最早条目可保留更早的安全唤醒，到时重新查看当前堆，不会按旧请求触发超时。

唤醒覆盖 queued、executing 和 held reservation。等待条目到期返回明确未接受并归还其预算；实际执行到期只退出调用并返回 unknown，保留执行 turn 与预算直至实际结果；reservation 到期仍退役该 epoch，不直接放行后继。截止处理跨预算 actor 等待时继续拥有处理责任，重入的新条目在处理结束后重新调度。

新增 `sharedDeadlineWake`：实际 turn 被屏障阻塞，队列中部更早的截止先到期，头部取消，尾部仍按序执行；检查截止记录归零、唤醒取消及实际预算保留/归还。`V2RoomTurnDeadlinesTests` 使用正反插入、相同截止和任意位置撤除，对照存活请求的最小截止验证无遗留条目。重新构建（46.92 秒）后，堆、Lane、ActivationHost、CommandBudget 共 57 项测试、4 个 suite 通过（1.034 秒），日志 `/tmp/imv2-room-shared-deadline-tests.log`，实际进程 exit=0；包含原执行超时、reservation 到期、取消、未知结果、屏障和宿主关闭回归。

本节落实上一节尚未完成的房间统一计时要求。物理数据库代理、全部 writer 锁顺序审计、投递隔离与容量验收仍未完成；没有以这组运行时测试声明整体目标完成，也未运行新的容量压测。

### 选择物理池时复用当前可用额度

发现 `V2EventLoopBalancedDatabase.nextEntry` 原来固定轮转到一个 EventLoop 池，再申请该池 loan gate；选中的池已满时，即使另一个池此刻空闲也会排队或拒绝。现将选择与 loan 请求合并：从共享 cursor 开始轮转候选池，调用 gate 的原子 `requestIfAvailable` 尝试获取原有额度，成功即使用该池；所有池都不能立即获准时，仅在原轮转池注册一个有界等待需求。

`requestIfAvailable` 与原 request 共用 `canGrantImmediately`，保留已有排队竞争者、分类限制、activation 上限、renewal 预留与实际结束后归还。失败候选不创建 observation ticket、不记为请求拒绝；只有最终真实请求保留原拒绝语义。class/source facade 共用同一 cursor 和 gates；选择过程中直接取得实际 loan，不依赖可能过期的容量快照，不额外签发连接额度。

`availablePoolSelection` 的 4 类测试保持池 0 的实际 driver future 未结束，先完成池 1 的短借用，将轮转指针转回池 0，再证明后续借用进入空闲池 1。两个池同时满时第三个请求按原 queueFull 规则拒绝，每池实际 driver peak=1；仅在 future 真正完成后归还，关闭后 inFlight=0。重新构建（40.26 秒）后 LoanGate、DatabaseWorkAdmission、PhysicalDatabaseWorkAdmission、HostDatabaseWorkAdmission 共 26 项测试、4 个 suite 通过（0.027 秒），日志 `/tmp/imv2-available-pool-selection-tests.log`，实际进程 exit=0；受影响 diff whitespace 检查通过。

这组测试使用可控 driver future，证明资源选择和归还，不是 PostgreSQL 性能或容量证据。改动避免选择时已有空闲池的等待，但全部池忙时需求仍绑定一个池；上游工作准入与底层 loan gate 仍是两个边界，完整物理数据库代理尚未完成。没有增加池容量，也没有运行新的压测。

### Owner 等待中的跨池借用

在已有即时空闲池选择之外，新增 `V2PhysicalDatabasePoolBorrower`：Sendable 房间执行保留原 pool gate 的有界等待票据，共享协调器只记录这些已接受需求。原池继续按原分类 FIFO 处理；任一 peer 池归还实际额度后，协调器可将需求转交该池。无需另建等待任务、排队额度或连接容量。立即 queueFull / timeout / closed 的请求同步排除，不在协调器留下记录。

`V2EventLoopBalancedDatabase.withScheduledConnection<Value: Sendable>` 接入此路径，`v2WithRoomPhysicalConnection` 在具体 balanced facade 上调用它；Owner 和其他使用该 Sendable 房间物理执行 helper 的路径据此借用。class/source facade 共享协调器及原 gates。Fluent 的通用 `transaction<T>` / `withConnection<T>` 允许非 Sendable 结果，继续保留已选择的 EventLoop，不能为了迁移等待而跨循环搬运这些结果。

请求第一次注册时冻结原调用截止与 policy.maximumWait 的较小值；peer 尝试不能重置等待预算。转交成功后撤销原排队票据，不计为业务拒绝。原池和 peer 同时获准的竞态只交付一个 lease；未交付的实际 lease 随其真实回调归还，数据库操作只执行一次。竞态期间可能短暂持有两个不同池的许可，各池仍受原额度限制，不能将它描述为始终只持有一个许可。原 SQL watchdog、围栏、回执及真实 rollback/COMMIT 结算保持原责任。

资源验证 `/tmp/imv2-peer-pool-borrow-bounds-tests.log`：重新构建 39.67 秒，30 项测试、6 个 suite 通过（0.109 秒）。四类 `queuedRoomBorrowFollowsPeer` 保持原池实际 driver future 未结束，只归还 peer，证明 queued 需求进入 peer；各池 driver peak=1，原 queued 票据归零且转交不增加 rejection。补充取消、原截止到期、关闭及连续 100 次立即队列拒绝，验证未收回实际 held loan、没有遗留记录。即时可用池选择、原 gate 公平性/生命周期、准入和 FIFO 回归同时通过。

最终真实 PostgreSQL `/tmp/imv2-peer-pool-borrow-final-postgres-tests.log`：4 项测试、7 个参数用例通过（6.260 秒），覆盖具体生产房间 factory 的发送/查询/退役恢复、当前内存策略的普通/staged/preborrow 发送与永久回执、同 shard 实际独立事务、确认 rollback 与复杂回退仍复用同一物理 backend。两次测试进程均实际 exit=0；测试 PostgreSQL 25462 已停止，相关 diff 及新文件 whitespace 检查通过。

这是在原额度内避免 Owner 固定池等待的一步，不是完整 PhysicalDatabaseBroker：上游 admission 与实际 driver borrowing 仍分别管理，OwnerBatcher 在借用期间仍保留其根和房间责任；非 Sendable 通用 Future 仍绑定池。完整 writer/投递隔离审计及 10,000 在线 / 1,000 新消息每秒验收未完成。本轮没有重建 Release 或运行容量压测；多池可控 driver 的借用证据不等于实际容量提升，也未单独证明不同 EventLoop 间的运行时行为。

### 不同 EventLoop 的借用与并发归还核验

补齐上一节没有直接覆盖的跨 EventLoop 行为：`queuedRoomBorrowFollowsPeer` 使用两个独立 NIO EventLoop，各自创建不同 DatabaseContext / 可控 driver，明确检查 loop identity 不同。四类借用分别覆盖仅 peer 归还、两个实际 driver 并发归还，共 8 个参数用例；原池保持未结束时请求仍进入 peer，Sendable future 回到 facade 的 EventLoop。

并发归还用例检查等待操作实际 driver 派发计数始终为 1，两个池共只执行原来的两次 held 借用及一次等待借用，各池 driver peak=1；结束并关闭后所有 class loan inFlight=0、queued=0，转交不记为请求拒绝。该用例验证并发归还下的外部行为，没有人为暂停 permit delivery，因此不能声称每次都强制进入两个竞争 lease 同时获准的内部分支。

当前测试源码重新构建 27.52 秒，`/tmp/imv2-peer-pool-two-loops-tests.log`：30 项测试、6 个 suite 通过（0.110 秒），实际进程 exit=0；受影响测试文件 diff whitespace 检查通过。本轮只补明确缺失的运行时证据，未修改生产源码，也未运行容量压测。上游 admission 与 loan 的整体收敛仍未完成。

### R18：当前内存发布修复后的同场景验证

源码保持不变，Gateway Release `/tmp/imv2-policy-cold-publication-r18-gateway-build.log` 构建成功（188.20 秒），Account `/tmp/imv2-policy-cold-publication-r18-account-build.log` 成功（9.65 秒），Loader `/tmp/imv2-policy-cold-publication-r18-loader-build.log` 成功（13.74 秒）。运行输出 `/tmp/imv2-memory-policy-10k1000-20261006-r18`，实际进程退出码 1。

12 份 ready 合计 active/requested=10,000；12 份最终报告完整，认证 10,000，消息发送 19,984、ACK 13,660、workloadFailed 6,324。其中 63 次 `TCP_DEFERRED_RETRY_EXHAUSTED`、6,261 次 `TCP_OUTCOME_UNKNOWN_CONNECTION_CLOSED`；另有 2,818 次临时 `SERVER_BUSY` 传输事件，不能与最终失败数相加。共同窗口 20.004 秒，报告的 ACK 速率 678.62/s，仅代表失败窗口；不能外推为 60 秒能力。各报告 phase 消息 p95 为 9,190–10,000 ms，p99 均 10,000 ms。quality、capacity、steady、共同窗口和 drained 均未通过；coverageProof 单项通过不等于全链路验收完成。

严格位于完整共同窗口内的 4 个六节点指标采样，首末跨度 15.534 秒。`candidate/policy-window-diagnostic.json` 的累计计数差分显示：内存探测约 19.56 ms、policy state 约 45.80 ms、实际 state SQL 准入约 13.06 ms、SQL 事务约 30.01 ms、事实读取约 8.99 ms、Owner 预读约 19.10 ms、Owner 正文约 39.57 ms。冷队列 3,957 个完成等待样本，平均 2,300.48 ms；probe hit/miss=7,004/7,799，无 Owner 或事实驱逐。Owner 正文子阶段中，围栏约 7.65 ms、回执读取约 6.20 ms、房间预检约 6.85 ms、消息写入约 13.43 ms、回执/证明写入约 5.25 ms。范围与计数不同，且包含嵌套阶段，不能直接相加成客户端延迟。

清理 25 个进程均 settled、forcedKillCount=0；13 个服务退出码均 0，12 个负载器退出失败。测试 PostgreSQL 已停止，压测进程已结束。R17 的 Gateway 清理失败此次未复现，但没有相关关闭修复或针对性证明，不能宣称该故障已解决。

### R19：冷状态首次获取少一次 SQL

当前内存模式无缓存事实的 scope 创建/获取已合成一条 SQL，保留原事务、版本、pending、有效期和事实锁；已有事实续租仍保留原旧 tuple 校验。7 项真实数据库测试、20 个用例通过，三份 Release 重新构建成功后，使用原场景运行 R19。最终报告缺少 3、6，整体容量证据不成立；13 个服务正常退出，缺失报告的负载器在清理时收到 SIGTERM。局部采样仍显示冷队列约 1.87 秒和 Owner 正文约 38.54 ms，不能据此宣称整体吞吐提升或验收通过。实现、测试、构建和完整局部数据边界见 [授权内存状态记录](policy-memory-state-redesign.zh-CN.md#冷状态首次所有权获取与-r19)。

### R20：已准入状态读取复用（历史记录）

已准入的冷状态读取避免再次探测内存；本 scheduler、其他 scheduler、cache-only 及实际发送路径的测试通过。此前重建三个 Release 后执行 R20，最终仅 8/12 报告，共同窗口为零，容量仍未通过。缺失报告不允许推导全局吞吐；probe 计数范围改变也不能作为命中提升证据。完整证据见 [授权内存状态记录](policy-memory-state-redesign.zh-CN.md#已准入读取复用与-r20-历史记录)。该结果归档已执行工作，当前阶段继续聚焦策略状态归属与修改发布。

## 实际修改

1. `V2RoomTurnLane` 仍是房间有序写操作的权威入口。普通 durable send 默认只收集已有的相邻兼容请求，不再等待新的请求填满窗口。状态变化与 reservation 屏障、原 deadline、未知事务处理不变。配置中的 windowed 模式仅用于显式对照。
2. `V2DurableSendOperationPreparationCollector` 每个实际准备任务只处理一个房间。取消跨房间收集延迟、共用最早截止与整个 cohort 完成屏障。同房间头部完成后再轮转后继；实际准备并发与共享控制预算不增加。
3. `V2DurableSendOperationOwnerBatcher` 作为 ready 调度器，先注册不绑定房间的有界资源需求，准入获准后才挑选房间。等待期间请求可取消，房间不被标记为执行中；实际借用/SQL 结束后才归还已获准许可。迟到授权在关闭时必须实际归还后才能结束 drain。
4. 两个调度器使用按命令/字节成本的 deficit 轮转，以及包括实际执行的每房间保留额度。单房间命令上限至少容纳协议允许的 256 命令 turn；全局上限仍优先约束，小总预算不会凭此被放大。每房间字节上限保留至少原单请求预算。
5. `V2IndexedFIFO` 支持按 ID 取消、头部删除与 ready 轮转。修改前移动字典中的队列值，再放回，避免 Swift Dictionary 写时复制把删除重新变为 O(n)。等待截止采用共享最近截止缓存，只在到期时遍历保留队列。
6. Owner 根任务指标新增 `waiting_admission`，与 `acquiring_connection`、`executing` 分开。`inFlightBatches` 表示保留根任务，不代表实际 SQL 并发；`batchesStarted/Completed` 统计实际派发的房间工作，未派发的资源需求不计入这两个累计值。
7. 生产 Owner 的资源需求上限从共享准入总容量派生，移除旧 batch 数对借用空闲读取额度的阻挡。真正的获准数量仍由原读/写/控制准入决定；有读者排队时优先补回其份额。测试明确覆盖“先借用、再交还给排队读者”。
8. 消息预检、准备快照、回执证明、消息集合写入与 Owner/activation 锁输入，向 SQL planner 提供服务端生成数组的实际条数。限制只放在输入集合，所有连接结果、行数检查和事务锁保持原语义。固定数字通过 SQLKit 整数 literal 编码，消息正文与身份仍使用绑定参数。

### SQL 执行计划证据

对第二轮压测的实际 10,000 房间数据库执行只规划、不执行的 EXPLAIN。原完整 `PlainDirectRoomLogPreflight.load` 查询的 JSON recordset 被估为 100 条，包含 `rooms` 和 `room_admission` 各 10,000 行的顺序扫描；输入限定为其实际 1 条后，这两个顺序扫描消失，总估算成本从 1271.01 降至 76.8。文件：`/tmp/imv2-redesign-preflight-plans.json`。这是计划变化证据，实际吞吐效果以之后的独立压测为准。

## 复用与边界

### 策略 Owner 与内存授权：后续完整目标的实现状态

本轮后续目标为账号/用户对策略 Owner、持久许可登记、可靠撤销与变更恢复、房间内存授权，以及最终移除普通发送的逐消息控制侧授权事务。不是仅增加 TTL 缓存。

新增 `IMV2ServerApplication/V2RoomPolicyAuthorizationGate.swift` 作为房间侧执行屏障：许可绑定 activation、Owner epoch、单调登记代次及双方/用户对版本；撤销先关闭新授权，再等待实际执行结算。过期或调用方取消不会释放已执行事务，重复撤销和 shutdown 加入同一 drain。延迟的旧撤销不能停用新登记，已撤销代次不能被刷新重新启用；记录有界，不为历史撤销保留无限集合。该组件尚未装配到生产发送链路，当前所有数据库围栏与授权意图保持原路径。

验收必须继续覆盖：控制面账号与用户对分片归属及 Owner 迁移；持久许可注册与撤销的原子裁决；撤销过程中重启、网络分区、COMMIT unknown；拉黑/关系/设置/封禁所有写入口；旧许可实际失效后才返回变更成功；特殊账号的完整策略语义；快照冷加载与有界刷新；旧/新发送路径切换；移除逐消息控制事务后的真实 PostgreSQL 正确性和一万在线压测。目前不能宣布上述完整目标完成。

房间屏障专项：`/tmp/imv2-policy-gate-final-tests.log`。测试使用确定性执行屏障与可控时钟，覆盖取消、过期、重复撤销、迁移代次、版本回退及同房间真实占用/跨房间独立性；它们不是 PostgreSQL 或分布式撤销协议已通过的证据。

新增 `V2PolicyAuthorizationLifecycle` 类型、`PostgresV2PolicyAuthorizationJournal` 和 `PostgresV2RoomPolicyLeaseFence`。控制侧按账号/规范用户对键持久记录 Owner epoch、登记许可、冻结的撤销目标、待恢复变更、永久结果与发布 outbox。登记依赖按键序持锁，封口后拒绝新登记；同身份重试不更换许可，变更 payload 冲突会拒绝。策略事实回调、版本、操作结果与 outbox 在一个事务提交，网络与 drain 位于事务外。房间侧持久 tombstone 拒绝迟到安装，实际消息事务持有许可行 SHARE 锁直至事务结束，撤销 UPDATE 等待其结算；只有撤销事务提交后才签发内部证明供控制侧确认，不能用超时或 UUID 直接确认撤销。

对应未部署的 current bootstrap 新增六张表及登记代次序列，并列入启动 schema 必需表。没有运行生产迁移；独立 PostgreSQL 实际测试覆盖登记/封口、重启恢复、Owner 接管、过期 Owner 拒绝、命令冲突、发布失败整笔回滚、迟到安装及调用方取消后的物理 SQL 阻塞。最终日志：`/tmp/imv2-policy-journal-proof-final-tests.log`（12 项、3 个 suite 通过，其中 5 项实际 PostgreSQL，另含完整启动 schema readiness 校验）。测试域事实使用专用测试表验证原子性，尚不代表拉黑/关系/设置/封禁业务入口已经接入。策略 Owner 运行时和冷加载登记组件的后续进展见下文；可靠发布 worker、所有业务写入口与发送热路径接线仍待完成，逐消息控制授权事务尚未移除。

### 策略 Owner 协调与冷加载登记

新增 `PostgresV2PolicyOwner`，按单个账号或用户对 scope 协调持久封口、并发有界撤销、确认、事务内业务回调及恢复。撤销期间不持有控制数据库事务；调用方取消不释放实际根任务，shutdown 关闭入口并等待物理工作结束。恢复只读取本 scope 的未完成命令。永久结果读取先于抢占 Owner，已提交操作在归属迁移后仍可重放，冲突负载仍被拒绝。当前回调与撤销路由尚未装配到生产业务。

新增 `registerSnapshot`，快照读取与多依赖许可登记共享事务，scope 锁保持到提交；读取失败则整笔回滚。同身份刷新也检查封口与版本，不能重新启用旧登记。`PostgresV2DirectPolicySnapshotStore` 要求发送方账号、接收方账号及规范用户对三项依赖，复用完整策略读取，包括特殊账号状态、服务消息权限及客服消息权限。旧 `withLockedPolicies` 继续使用同一读取实现。冷加载组件不代表房间发送链路已经使用该快照，现有 gate 尚需承载完整特殊账号语义。

本阶段验证日志：`/tmp/imv2-policy-snapshot-final-tests.log`，17 项、4 个 suite 全部通过，其中 11 项实际 PostgreSQL 测试，覆盖完整策略冷加载、读取失败回滚、封口等待实际登记事务、旧登记刷新拒绝、Owner 迁移后永久结果重放及既有许可撤销/恢复测试。旧控制策略读取回归 `directControlPolicyFence` 的拉黑、好友、设置、停用 4 个参数场景也全部通过，日志 `/tmp/imv2-policy-fence-regression-tests.log`。未进行容量验收。

并行实际 PostgreSQL 测试暴露启动 readiness 对其他 schema 已删除对象调用目录定义函数的竞态；通知契约查询先物化本 schema 的索引与约束 OID，再解析定义，避免触及无关测试 schema。后续仍需完成所有策略 writer 接入、Owner 路由及全局资源预算、快照发布与恢复、房间热路径切换和一万在线容量验收。

### 业务策略写入与有界 Owner 注册表

新增 `PostgresV2PolicyMutationDispatcher` 和持久化命令封装，覆盖好友/拉黑、陌生人消息权限与账号停用。命令保留原操作身份、版本基线、deadline 和指纹，不把重试时刻写进冻结 payload；恢复由数据库当前时间重新校验期限。现有业务 Store 提取事务内应用方法，继续校验账号、关系、修订基线，原子保存业务回执与传播责任。策略日志仅在持久撤销已确认、Owner 围栏有效时签发不可由业务调用方构造的 `V2PolicyMutationContext`，绑定 scope、operation 和 fingerprint。

社交、账号偏好与停用的公开写方法支持 package 内的 `usingPolicyOwners` 组合入口。新组合在控制事务之外撤销许可，业务回调不再调用跨数据库 drain；旧逐消息授权未清空时拒绝提交，不能混合两套授权权威。旧组合继续使用原方法，Account/Operator Server 的生产装配尚未切换。停用的新执行回执区分首次提交与重放，保持原接口的 disabled/idempotent 结果语义；原结果内容及时间不随重试改变。

`PostgresV2PolicyOwnerDirectory` 在进程范围限制实际根任务和缓存 Owner 数量，账号与规范用户对各自隔离。以有界索引队列常数时间淘汰闲置 Owner，不扫描全部缓存；使用计数保护实际工作，未结算 SQL 的 Owner 不可淘汰。重建使用同一进程 Owner ID，数据库 epoch 不因本地缓存淘汰而改变。取消调用方不会归还实际根任务容量，shutdown 封口后等待所有实际任务及 Owner。注册表提供持久命令恢复入口，但跨节点路由、周期 worker 与现有共享数据库准入预算的装配仍待完成。

最终针对本阶段的日志为 `/tmp/imv2-policy-domain-final-tests.log`：22 项、6 个 suite 通过，含拉黑、解除好友、陌生人设置、停用四个真实业务参数场景，真实业务 outbox 失败整笔回滚与冻结命令重启恢复，注册表闲置淘汰/实际 SQL 占用/取消/关闭，以及旧控制策略读取四个回归参数场景。核心 journal/gate/snapshot 测试同时通过。另在 `/tmp/imv2-policy-domain-legacy-tests.log` 验证凭据签发/吊销围栏，以及旧 direct/stranger/userAdd/relationship/block 的五个期限重放参数场景，2 项全部通过。不能据此宣称生产写入口装配、房间内存授权或吞吐目标已完成。

消息调度阶段没有新建数据库池、增加连接/工作并发总额或修改 schema；随后策略许可阶段新增以上 bootstrap 结构。保留已有消息/序号/回执原子提交、权限 grant、Owner/activation 围栏、永久身份冲突与关闭语义。准备和 Owner 调度中的房间占用是防御性排他与公平调度，不成为另一套持久序号来源；跨客户端顺序仍由原房间入口与数据库决定。

现有 `V2EventLoopBalancedDatabase` / `V2PhysicalDatabaseLoanGate` 已覆盖物理池共享与借用实际归还；本轮直接复用。应用工作类别准入与物理池门禁仍为两个资源边界，未宣称全部合并为一条队列。此次完成的是 ready 房间与准入等待的解耦；进一步合并需覆盖全部读、控制、续租使用者，不能绕过现有全局预算或在持有物理连接时等待第二个许可。

提交后的有界 `CommittedFactsFeed`、持久恢复、独立订阅发布、按目标 Gateway 聚合及慢连接补拉复用已有实现。没有以新消息队列、跨房间事务或更弱的确认语义代替现有合同。事务 SQL 与共享 quota 的性能优化仍须以本轮 trace / 压测证据为依据。

### 房间内存授权接入真实接受事务

新增每个房间方向、每次 activation 独立的 `PostgresV2RoomPolicyAuthorization`：合并并发冷加载，保存完整账号/特殊主体/双方关系快照，按许可代次关闭发送，等待实际执行结束，并在房间数据库撤销持久许可。冷加载在登记事务内采样数据库时钟，将许可剩余时间转换为单调时钟期限；加载、传输和安装耗时都会消耗期限。撤销可以先于安装到达，内存高水位和数据库墓碑共同拒绝旧快照复活。

`V2RoomPolicyExecution` 是由运行时生成、绑定完整消息指纹与确切 activation token 的内部执行上下文。RoomWriteStore 只在这一上下文实际执行期间使用快照，并在消息事务内持有许可 SHARE 围栏直到 SQL 完成。调用方取消不释放实际执行占用；执行结束后重用上下文被拒绝。没有通过手工构造策略字段授予发送权限。

新许可路径的标量预检移除房间库账号、停用、策略版本、特殊主体、好友、拉黑和陌生人设置查询。事务保留房间成员/禁言/准入/配对回复标记等房间事实及消息持久化；完整既有特殊主体判定与“对端已回复”规则仍由原判定器执行。新快照不填充旧策略版本缓存，不能以房间库镜像的版本作为许可有效性依据。

新增真实双数据库测试覆盖连续消息共用登记、旧逐消息授权 intent/receipt 为零、隐藏房间库策略表后仍能发送、拉黑后刷新快照并持久化拒绝、撤销先于冷加载安装、真实消息写入后等待 COMMIT 时拉黑不得提交、取消不释放执行、无关账号可继续登记、结束的上下文无法再取得许可，以及拒收陌生人但对端已回复的许可判定。

本阶段最终日志 `/tmp/imv2-room-policy-runtime-verified-tests.log`：24 项、6 个 suite 全部通过，包含上述房间运行时测试和 journal/gate/Owner/directory/snapshot/真实业务策略写入及旧控制策略读取回归。所有数据库场景使用独立可丢弃 PostgreSQL 的主、次数据库，结束后停止该实例。最初并发场景触发测试默认每日 3 条陌生人额度，调整为该场景显式的 10 条额度后通过；实际授权规则未放宽。

上述标量阶段由内部装配与测试调用。后续持久消息批次进展见下一节。生产 activation 工厂、跨节点 Owner 路由/撤销端点、可靠发布和恢复 worker 尚未接入；不能据此宣称生产逐消息控制事务已移除，或 10,000 在线 / 1,000 新消息每秒目标已通过。

### 可撤销许可接入持久消息批次

房间运行时新增 `executeBatch`，一份实际执行许可绑定最多 256 条完整消息身份与指纹。相同身份的等价重试可复用，身份相同但内容不同的输入在执行前拒绝。实际占用直到整个操作未来值结束才结算，包括消息与永久回执所在事务的 COMMIT。

`PostgresV2MessageSendOperationStore.usingPolicyExecution` 将运行时上下文绑定到现有持久操作 Store。标量操作保留许可检查，Owner cohort 在房间/activation 锁后核对上下文确切 token、每条消息指纹及执行占用，再批量持有房间库许可 SHARE 锁。批量许可检查对重复 holder 去重，有序取得全部锁后再读取数据库当前时钟；整个 cohort 只需一次加锁读取和一次时钟读取。JSON 输入条数显式暴露给规划器。

全许可 cohort 的 `PlainDirectRoomLogPreflight` 使用服务端生成的策略 JSON，移除账号、停用、特殊主体、用户策略版本、好友、拉黑和陌生人设置查询。配对回复标记、成员/禁言、准入和实际消息写入仍在房间事务内。新路径不发布旧策略缓存提示，也不写旧逐消息授权 intent/receipt；消息及永久操作回执继续使用既有原子批次合同。旧路径、混合 cohort 和复杂命令仍使用原有回退逻辑，未将新许可视为免除完整消息判定的凭据。

实际双数据库场景分别执行标量/持久批次 × 未回复/已回复四个组合，覆盖批量追加与原始回执重放、隐藏房间库策略表后仍使用 cohort（通过 accepted/replayed cohort 指标断言实际命中）、拉黑后持久策略拒绝、结束上下文不能再次授权及既有 SQL 提交屏障。测试需要混用预扣额度和直接写入，原 fixture 的 10 个分片额度被预扣全部占用而使后续屏障发送正确限流；为这个 fixture 明确设置 1000 个额度后继续验证授权协议，没有改动生产预算或压测场景。

最终日志 `/tmp/imv2-policy-durable-runtime-verified-tests.log`：30 项、7 个 suite 全部通过，含上述四个实际数据库参数场景、同一事务批量锁住多份许可并验证取消不能解除物理 SQL 阻塞、撤销/替换任一 holder 后整批拒绝而独立 holder 仍可使用，以及旧 durable Owner cohort 的分片组合、权限/拒绝/旧 activation/消息或回执约束失败/迟到 quota/COMMIT 未知回归。使用独立 disposable PostgreSQL 主、次数据库，结束后停止测试实例。

准备与执行拆分及现有入口调用边界见下一节。每个 activation 的注册表、跨节点 Policy Owner 路由/撤销端点、所有策略写入口切换、恢复/发布 worker 与万人压测仍待完成。批次组件测试通过不能替代这些生产接线证据。

### 排队准备与实际执行分离

`V2RoomPolicyPreparation` 保存运行时身份、确切 activation、原始消息集合、注册快照和单调时钟截止时间，没有执行 permit，也不计入房间正在执行的根任务。`prepareBatch` 只冷加载/登记，`executePreparedBatch` 才提升为实际占用。提升时检查运行时身份、activation、当前许可登记 ID 与策略版本；旧句柄过期或被撤销后不在执行阶段自动刷新，必须显式回到准备阶段。

持久操作 Store 新增策略准备入口：先读取房间预算和永久回执，仅未完成且未过期的消息需要策略准备。已完成消息或指纹冲突在实际房间事务里继续优先重放，无须重新加载已被拉黑/封禁的策略。截止与取消使用结构化任务组，父调用不能因截止而抛下尚未结束的实际准备工作。

标量批次、Owner cohort 和预借连接入口统一在实际执行阶段提升句柄，并将运行时生成的上下文绑定回每条消息的 Store。预借连接路径先完成现有执行准入，再提升全部策略句柄，随后借用物理连接；许可一直保留到整个 SQL/物理借用未来值完成，取消不能提前结算。多个准备句柄的提升失败会结束此前取得的占用，不留下授权根任务。

实际双数据库场景扩展为标量、显式执行上下文、排队准备、预借连接四条路径 × 未回复/已回复，共 8 个参数场景。验证准备后执行占用为零、执行准入回调时占用为零、物理连接取得时占用为一、返回后为零；拉黑前准备的未执行消息在拉黑后拒绝，物理写入连接回调没有触发；已接受消息重新准备时保持首次提交截止时间/完整原始指纹，可在策略已撤销时重放原回执且不增加冷加载次数。它们继续覆盖隐藏策略镜像表后的实际 cohort、SQL COMMIT 屏障和新策略拒绝。

最终日志 `/tmp/imv2-policy-prepared-runtime-final-tests.log`：31 项、7 个 suite 全部通过，包含上述 8 个实际数据库参数场景、既有 journal/gate/Owner/directory/snapshot/真实业务写入、跨房间准备完整操作 key、Owner cohort 权限/旧 activation/约束/迟到 quota/COMMIT 未知回归。测试实例为独立 disposable PostgreSQL，结束后停止。

新准备入口与上下文类型目前为 Infrastructure 内部接口。生产 activation 工厂尚未安装每方向的运行时注册表，准备 collector 也尚未通过跨节点策略路由调用新入口；可靠撤销端点、所有写入口切换、发布/恢复 worker 和容量验收仍未完成。不能将准备/执行边界的专项通过视为生产切换完成。

## 专项验证

最终源码使用独立 PostgreSQL 16 测试实例和两个 disposable 数据库实际执行，不以缺少数据库环境时的跳过作为通过。

覆盖：房间 FIFO 与屏障、跨房间准备独立返回、同分片两间房同时持有不同 PostgreSQL backend、资源等待期间不占房间、排队取消不启动 SQL、实际执行取消不提前释放、重复关闭、排队 deadline、热房间保留容量、回执重放、权限变化、旧 activation、提交前回滚隔离与原物理连接保持。

调度专项日志：`/tmp/imv2-redesign-verified-tests.log`（服务端 41 项、Actor 26 项通过）；资源借用专项：`/tmp/imv2-redesign-resource-tests.log`（37 项通过）。SQL 优化后最终专项日志：`/tmp/imv2-redesign-final-sql-focused.log`（42 项、5 个 suite 通过，实际 PostgreSQL）。最终 Release 构建日志：`/tmp/imv2-redesign-sql-release.log`。

扩大执行 `PostgresV2RoomWriteStoreIntegrationTests` 时，已完成 200 项通过，但出现 10 类测试、48 条 issue，随后停止剩余回归并转入失败项对照，不能记为完整通过。回执恢复、内容隔离、容量配置失败、Actor SQL continuation 指标、presence 并发和媒体扫描截止断言均有失败。撤掉本次 SQL 输入条数优化后，15 项对照测试仍产生同名 10 类、48 条 issue（其中首次用例遇到中止留下的 schema，后续已清理 disposable schema）。记录在 `/tmp/imv2-redesign-sql-tests.log` 与 `/tmp/imv2-redesign-sql-control-tests.log`。这些失败不能归因于此次输入条数优化；不能据此宣称所有本地工作树故障已解决，亦未调整预期掩盖失败。

## TCP 验收

场景：`IMV2/load-scenarios/actor-realtime-message-redesign-1000.json`。10,000 在线、配对私聊、1,000 新消息/秒、60 秒共同消息窗口、正常 drain 30 秒、hold 10 秒。沿用既有 6 Gateway / 12 Loader 及数据库预算；不与之前提前终止的 20 秒失败窗口计算吞吐提升百分比。

三轮均未达标，输出分别为 `/tmp/imv2-redesign-10k1000-20261005-run{1,2,3}`。第一轮使用原 Owner 根任务上限；第二轮派生资源需求容量；第三轮再加入 SQL 输入条数优化。

| 轮次 | 完整 Loader 报告 | 发送 / ACK | SERVER_BUSY | 终端失败 | 共同稳态窗口 |
| --- | --- | --- | --- | --- | --- |
| 1 | 12/12 | 19,881 / 11,198 | 6,971 | 8,683 | 20.002 秒，提前中止 |
| 2 | 12/12 | 19,875 / 11,437 | 5,888 | 8,438 | 20.011 秒，提前中止 |
| 3 | 11/12 | 18,315 / 13,346，仅报告子集 | 2,139，仅报告子集 | 4,969，仅报告子集 | 无完整共同窗口，提前中止 |

第三轮 barrier 证据确认所有 10,000 连接均已 warm，但 Loader 5 被 runner 终止而未产出报告，汇总只覆盖 9,167 连接，不能把子集 ACK 换算成万人容量。11 个报告的 accepted 延迟 p95 为 6,096–6,417 ms；终端失败中 43 次为重试耗尽，4,926 次为关闭时未知结果。最终 3,354 个已报告 viewer 落后提交 head。清理已结束，但一个服务被强制结束，不能记为优雅关闭通过。测试 PostgreSQL 与 runner 所有者 PostgreSQL 均已停止。

第三轮最后的 node 0 快照仍为写 5、读取 3、ordinary 物理连接 9 全部占用，Owner 54 个 turn 排队、3 个根任务等待准入、5 个正在执行，准备队列 152。因此房间相互独立不等于共享数据库无限吞吐；本轮 SQL 计划优化不足以消除整体积压。没有利用放宽时限、减少校验、增加连接池或删掉恢复协议来宣称达标。

第三轮报告：`candidate/result.json`、`candidate/service-cleanup.json`、`candidate/gateway-metrics.jsonl`；入口日志：`/tmp/imv2-redesign-10k1000-20261005-run3.log`。此场景受 runner 标记为 scaled diagnostic，不作为其要求 50,000 用户的正式容量认证，也不能外推万人群扇出容量。正式稳定性与容量验收仍未完成；全部类别准入与物理租借合并也仍是目标设计的后续阶段。

### 每次 activation 的授权运行时注册表

新增内部 `PostgresV2RoomPolicyAuthorizationRegistry`，生命周期绑定完整 room activation token，参与者来自房间持久身份。每个 direct room 最多保留双方两个发送方向，同方向复用一个运行时；不因排队句柄增加执行占用，也不按消息创建或淘汰实例。无关发送者和外来 activation 无法取得运行时。

撤销按持有者的 activation UUID 查找准确运行时，当前实例先关闭内存入口并等待实际执行结算，再完成 SQL 撤销。未找到运行时的旧 activation 直接在房间数据库写入持久撤销墓碑；不存在内存实例不能作为撤销成功的依据。路由验证房间和服务端 endpoint，重复在途撤销合并，根任务及并发数量有界，调用方取消不会丢弃实际撤销。shutdown 关闭注册表入口，同时关闭两个方向、等待所有实际工作和数据库撤销；持久清理失败可以重试，但不能重新开放入口。

消息操作 store 增加内部注册表准备入口：验证单个房间、发送方向和完整 activation 后选择运行时，再进入既有不占执行许可的准备流程。真实双数据库场景通过该入口覆盖 prepared/preborrow 两条路径，其余标量与显式执行路径也改用同一注册表取得运行时。生产工厂尚未调用这一内部入口；跨节点路由、服务级注册表退役管理、业务写入口切换、恢复/发布 worker 和万人压测仍未完成。

本阶段最终日志 `/tmp/imv2-policy-registry-verified-tests.log`：8 项测试、2 个 suite 通过，真实消息接受测试含 8 个参数场景。验证同方向实例复用、最多两个方向、无关发送者与外来 activation 拒绝、退役 activation 的持久墓碑和迟到安装拒绝、当前实例继续可用、双方向关闭及重复 shutdown。原有实际 COMMIT 撤销等待、冷加载前撤销、四类发送路径和 gate 取消/过期行为同时通过。构建成功，变更文件 `git diff --check` 通过；仍不能据此声称生产切换或容量目标完成。

### 服务级 activation 目录与撤销入口

新增内部 `PostgresV2RoomPolicyAuthorizationDirectory`，每个物理房间所有者持有有界 activation 目录。同一完整 token 的并发创建合并，实际创建任务不因调用方取消释放容量；旧实例显式退役后才能释放槽位，退役期间拒绝新取得，旧 token 的迟到退役不会关闭后继实例。创建、撤销和 room 数分别有上限，实际根任务持续保留至结算。

数据库构造入口在同一个房间事务内校验完整 activation 围栏，并读取 `direct_room_pairs` 的持久双方身份，再创建未预热注册表；目录清空后的迟到 token 必须重新通过数据库校验。普通已缓存取得不重复读全局策略。消息 store 增加目录准备入口，真实 prepared/preborrow 路径通过目录选择当前注册表和方向。

服务级撤销按 room ID 路由当前注册表，退役或缺失实例通过房间数据库持久撤销兜底。实际 SQL 锁等待期间，即使调用方取消也保留撤销根任务和容量，成功必须返回与完整持有者身份一致的撤销证明。shutdown 关闭取得入口、加入实际创建与所有注册表退役、再等待已接受的撤销工作，数据库清理失败保持封口且允许重试。

上述接口仍为 Infrastructure 内部；生产 activation 工厂和关闭回调尚未调用目录，跨节点 Policy Owner 路由、认证撤销协议、所有策略写入口切换、恢复/发布 worker 和容量验收仍待完成。

本阶段最终日志 `/tmp/imv2-room-policy-directory-final-tests.log`：11 项测试、3 个 suite 全部通过，包含 8 个真实消息接受参数场景。新增实际 PostgreSQL 测试验证创建合并、调用方取消后容量保留、创建期间退役、旧退役不影响后继实例、缺失 activation 的实际 SQL SHARE 锁阻塞与撤销容量保持。双数据库发送场景使用数据库构造入口和目录准备入口，目录退役后用错误 incarnation 重新取得由数据库拒绝，失败创建不占后续容量；旧许可可通过服务级兜底撤销。最终源码编译成功，变更文件 diff 检查通过。此前接口修改期间的一轮构建不匹配已由此最终完整重编译和测试替代。

### 生产工厂的可选策略授权装配与多方向准备

新增 package 级 `V2RoomPolicyAuthorizationService` 作为 Composition 能力边界，内部完整策略快照、许可和目录保持 Infrastructure 私有。`V2RoomServerOwnerResources.usingPolicyAuthorizations` 只能在工厂绑定前选择服务；同一物理所有者的所有逻辑别名必须共享同一个服务实例，混合装配在产生副作用前拒绝。工厂 collector 选择策略服务的批量准备入口，房间 close 退役对应完整 token，物理所有者关闭按 collector、执行 batcher、策略目录顺序结算。关闭回调仍沿用现有非抛错接口；失败的持久撤销保持封口，后续恢复/撤销路由仍须补齐，不能作为发布完成依据。

新增策略版 `prepareOwnerBatches`，一个实际多房间 cohort 共用一次额度快照读取和一次永久回执读取，并发准备上限为 8 个请求，逐请求保留结果和期限。已完成/冲突的永久身份不再次冷加载授权；同一房间同时出现双方发送时，句柄保存两个不占执行许可的策略准备。执行时依次取得各方向实际许可，围住整个 SQL future 并保留各消息对应的完整策略，不将不同方向覆写成同一份事实。单条目录准备也调用这个批量内核。

真实生产 activation 工厂测试通过 Host activate/invoke/stop 路径验证接受、拉黑后持久拒绝、原回执重放、无旧 intent/receipt，以及退役后所有已安装许可已撤销。多房间测试覆盖相同 operation UUID、永久指纹冲突、健康新消息、错误 room/token 隔离；8 个原双数据库场景中 prepared/preborrow 改为在同一批次发送双向消息，并验证每方向一份许可和三个依赖登记。

最终专项日志 `/tmp/imv2-policy-factory-verified-tests.log`：14 项测试、3 个 suite 通过。Server 工厂目标构建和变更 diff 检查通过。额外旧工厂回归 `actorFactoryRestoresSendAndQueries` 出现 3 条 durable SQL continuation 计数断言失败（实际为 0，期望 1），单独复查 `/tmp/imv2-policy-factory-legacy-metrics-probe.log` 仍失败；没有放宽这些断言，根因尚未证明，不能声称相关旧回归全部通过。

部署装配没有启用可选服务。当前服务构造依赖本进程 Policy Owner 目录，跨节点策略归属及认证撤销协议仍待实现；群聊/转发路径的策略接入、所有账号/关系/特殊账号变更入口切换、恢复/发布 worker、旧工厂计时回归及 10,000 在线/1,000 新消息每秒验收仍未完成。可选工厂路径测试通过不等于全面生产切换完成。

### 合并围栏的真实 SQL continuation 观测

上节旧工厂的 3 条计数失败已定位并修复：持久 Owner kernel 使用一条 SQL 合并操作咨询锁、房间锁和 activation 租约锁，旧测试却仍期望两个独立 SQL 观测。新增固定来源 `durable_fence_combined` 表示该实际查询；独立 room/lease 标签只用于确实独立执行的旧路径，不为合并 SQL 伪造两个计数。

另外，配置围栏上下文在成功返回时提前调用 `finishWithoutDispatch`，使合并 SQL 的恢复到后继发起区间丢失。现在成功返回保留观测，异常仍结束序列；在永久回执查询和房间策略许可锁查询真正发起前显式 `willDispatch`，记录紧邻的实际 SQL API 边界，不跨越后续未观测语句。外围事务仍负责 COMMIT/ROLLBACK 或无后继场景的结算，数据库锁、超时、提交和权限规则没有改变。

旧工厂测试改为严格断言合并查询计数为一、两个独立来源计数为零。新策略工厂对接受、策略拒绝、永久重放三次事务严格断言合并来源恢复及后继计数均为三，所有 pending gauge 为零且没有无后继观测；没有放宽原计数精度或伪造 SQL。

最终 `/tmp/imv2-policy-fence-metrics-tests.log`：17 项测试、4 个 suite 全部通过，含旧/新工厂、8 个双数据库发送参数场景、SQL future 先结算后恢复的三个场景、指标路由导出，以及 durable Owner 的多分片、权限/拒绝/过期 activation/消息及回执约束/晚到额度、单条及 cohort COMMIT 结果不明场景。之前的旧工厂计时失败由本次真实执行验证关闭；变更 diff 检查通过。全面生产切换、跨节点协议、所有业务写入口和最终容量目标依然未完成。

### 认证的跨节点持久撤销

新增 `V2RoomPolicyRevocationWire`，严格解码完整登记身份、房间、activation UUID、Owner epoch、代次、服务端 endpoint 和原始有效期。过期的登记仍是可撤销义务，过期不等于实际 SQL 已结算。Cluster signed RPC 增加 `revokePolicyAuthorization` 和精确目标的撤销响应，复用既有签名会话、接收方 incarnation、重放窗口、请求身份和请求/响应字节上限。

调用方必须以 service principal 持有独立 `policyRevocation` 权限，并通过服务端分片访问映射；用户身份或只有旧协调权限不能调用。独立撤销权限不会隐式获得房间 activate/lookup 权限。撤销作为 Host 端点操作，不依赖目标房间仍有物理 Actor；当前实例由目录关闭内存许可并等待实际事务，缺失/退役实例由持久 SQL 墓碑兜底。Node 构造入口支持可选撤销服务并传入 inbound，默认不启用。

`V2RoomPolicyAuthorizationService` 的 transport 实现仅在真实撤销证明返回后回复，而且返回目标必须与请求完全相同。Cluster client 先验证响应签名/本地能力、host incarnation、session、sequence、attempt，再校验完整目标；只有此客户端能创建不可伪造的 package 确认能力。Infrastructure 仅接受该能力或本地已提交证明生成 journal 使用的撤销证明，不能把原始 wire ACK、UUID 或到期时间转换为成功。

新增 `PostgresV2RemotePolicyRevoker`，使用服务端 route resolver 和有界请求时间调用认证客户端，供 Policy Owner 撤销回调接入。失败、取消或结果不明不会 acknowledge 控制侧的冻结目标，后续请求可以用相同完整登记身份恢复。Infrastructure 增加 ActorCluster 依赖承接该网络 adapter；Cluster/Runtime 不引入数据库和服务领域实现。

真实 PostgreSQL 测试使用两个独立 ClusterSystem，经 loopback 原生 TCP 发起撤销；消息事务实际持有许可 SHARE 锁时，远程撤销 UPDATE 被数据库阻塞，journal 拒绝变更提交。正常路径等待实际 COMMIT 后取得认证证明；取消调用方路径没有提前确认，释放 SQL 后通过另一认证客户端恢复证明。随后控制变更才能提交；旧安装仍被拒绝，替换登记代次返回结果不明且原墓碑元数据保持不变。

最终 `/tmp/imv2-policy-remote-revocation-verified-tests.log`：Server 的 2 项测试/2 个 suite（原生 TCP 撤销测试含正常/取消两个参数场景，以及策略生产工厂）和 Cluster 的 46 项测试/3 个 suite 全部通过，共 48 项。覆盖撤销独立角色、用户身份拒绝、重放拒绝、严格 wire 解码和旧 Cluster bridge/local capability 回归。最终源码编译和 diff 检查通过；测试系统、端口及独立 PostgreSQL 均按生命周期关闭。

仍未完成：AccountPolicyOwner/PairPolicyOwner 的跨节点归属和冷加载路由、endpoint resolver 的生产发现配置、Node/工厂与全部策略写入口的统一部署装配、群聊/转发策略覆盖、恢复/发布 worker 和 10,000 在线/1,000 新消息每秒容量验收。认证远程撤销通过不等于全面切换完成，部署默认入口仍未启用策略授权服务。

### 跨节点 Policy Owner 归属与冷加载路由

新增 Account/Pair 的 canonical wire identity、最多三个唯一依赖的 claim，以及 Owner lease metadata。pair 的编码和解码都归一化 UUID 顺序，自身用户对、account 带第二用户、重复 scope、零 epoch/revision 被拒绝。返回的 lease 只是冷加载元数据，不是可执行房间许可；控制 journal 在实际登记事务中继续验证当前 Owner、epoch、版本和变更封口。

认证 Host RPC 增加独立 `policyRegistration` 服务权限，用户 principal、只有撤销/旧协调权限不能申请所有权；独立策略登记/撤销权限都不隐式获得 activate/lookup 权限。请求绑定策略 endpoint 并接受现有服务分片访问校验。接收节点的 `V2PolicyOwnershipService` 转交本节点目录，目录按服务端提供的 canonical scope placement 谓词预检整个批次，在任何 SQL/Owner root 之前拒绝外来 scope；实际数据库租约仍决定跨进程的权威 epoch。Node/inbound 提供可选服务装配接口，默认不启用。

新增 `PostgresV2RemotePolicyOwners`，通过可信 route resolver 把至多三个依赖按目标 Host/endpoint/Owner ID 分组，并发调用各节点的认证 RPC。客户端验证 signed exchange 后检查完整 scope 集合及配置的 expected Owner ID，拒绝已认证但归属不符的返回值。房间授权服务增加远程 Owner adapter 的构造入口；仅冷加载/更新授权调用 resolver 和策略 RPC，普通消息继续使用房间内存快照，不逐消息争抢控制 Owner。跨节点 typed 策略变更命令的路由尚未实现，不能把这次 claim 接入当作所有业务写入口已接入。

真实 PostgreSQL + 三个独立 ClusterSystem/原生 loopback TCP 测试把发送者账号分配到节点 A，接收者账号和用户对分配到节点 B；验证三个依赖返回各自 Owner、journal 原子登记、用户对反向顺序路由相同、混合外来批次在 SQL 前被拒绝、signed response 的错误 expected Owner ID 被拒绝。强制原 Owner 过期并由另一 Owner 取得 epoch 2 后，原 epoch 1 返回值无法继续登记。第一轮测试暴露夹具未持有 distributed endpoint 的生命周期问题，修正后通过，不作为生产协议故障计入。

最终日志 `/tmp/imv2-policy-ownership-verified-tests.log`：Server 4 项/3 个 suite 和 Cluster 35 项/2 个 suite 通过；`/tmp/imv2-policy-ownership-factory-tests.log`：房间工厂及多房间授权准备 2 项/1 个 suite、同进程能力 13 项/1 个 suite 通过，共 54 项/7 个 suite。覆盖新 claim/codec/角色、旧认证与 Cluster bridge、真实远程撤销、目录生命周期、生产房间工厂和本地能力。基础 Infrastructure/Cluster 构建以及最终测试源码编译通过。

仍需完成：生产 placement/endpoint 发现配置、跨节点策略变更路由、Policy Owner 完整策略内存状态、全部账号/关系/特殊账号及封禁解封写入口的统一接入、Node/房间工厂统一部署装配、恢复/发布 worker、群聊/转发覆盖，以及 10,000 在线/1,000 新消息每秒容量验收。当前部署默认入口仍未启用新策略授权服务，不能宣称整体重构完成。

### 跨节点策略变更命令与业务写入口能力

新增不可变、有界 `V2PolicyMutationWire` / receipt，绑定 canonical scope、operation key、32-byte fingerprint 和至多 16 KiB 原始领域命令；回复绑定同一 scope/身份/指纹并保留 original receipt/replayed。签名 Host RPC 新增 `mutatePolicy`，需要独立 `policyMutation` 服务权限及 endpoint 分片授权，用户 principal、只有登记/撤销权限均被拒绝；该权限不隐式开放 activate/lookup。命令由可信业务入口完成用户/管理员身份准入后提交，不能把此服务权限发给普通用户或未受信网关。

`V2PolicyMutationService` 解码并验证冻结领域命令，校验 wire scope/key/fingerprint 全部对应，再调用分片目录。目录既有服务端 placement 检查、持久封口、房间许可撤销及 SQL 实际结算、最终短事务的领域校验/策略事实/版本/永久回执/outbox 都继续生效。接收服务不在网络等待时持有控制事务。超过 RPC deadline 的实际提交保持可恢复，返回结果不明，原始操作可重放；不得把取消视为事务已结束。

身份冲突通过绑定完整请求的认证回复返回，客户端校验后映射回领域 lifecycle identityConflict；社交写入口继续返回 fingerprintConflict，而非把确定的冲突误报成网络结果不明。新增 `V2PolicyMutationExecuting` 与远程 adapter，现有 social/preference/disable 的可选 usingPolicyOwners 能力接受本地目录或远程 adapter，不再把调用方和 Owner 强制放在同一进程。业务 store 仍负责原有回执结果及提交后投影处理；Node/inbound 新增可选变更服务装配，生产默认不开启。

原三节点 TCP 测试升级为真实双数据库和完整账号事实冷加载，在两个策略节点上领取三份依赖并原子注册完整快照、安装 room lease，再通过实际 social store 的远程 adapter 拉黑。验证墓碑拒绝重装旧许可、原回执重放只产生一次关系及 policy change、同 operation ID 的修改命令返回 fingerprintConflict，伪造 wire scope 在任何新封口/效果前拒绝。继续经实际 preference store 修改陌生人设置、disable service 停用账号；两者重放保持原回执/幂等停用结果，最终只出现三个已提交 policy change。此处 disable 仍是已有账号停用模型，不等于完整封禁/解封模型。

最终 `/tmp/imv2-policy-mutation-verified-tests.log`：真实远程业务测试 1 项/1 个 suite 和认证 21 项/1 个 suite 通过；`/tmp/imv2-policy-mutation-regressions.log`：Server 5 项/2 个 suite（四参数领域变更、事务回滚恢复、房间工厂、多房间准备、远程撤销）和 Cluster 49 项/3 个 suite（认证、bridge、本地能力）通过。去除重叠认证测试，共 55 项/6 个 suite。Infrastructure target 构建及最终测试源码编译通过。测试 ClusterSystem 和独立 PostgreSQL 按生命周期关闭。

仍未完成：Owner 完整策略内存状态、生产 placement/endpoint 发现配置、全部业务写入口和 Node/房间工厂统一启用、特殊账号规则及封禁/解封模型、恢复/发布 worker、群聊/转发覆盖及 10,000 在线/1,000 新消息每秒容量验收。跨节点变更能力通过测试，不证明生产端到端已经切换。

### Policy Owner 的发送授权内存状态与本地冷加载

新增 scope 完整发送授权事实：account 保存有效状态、特殊账号 kind/status/service/customer 标志及陌生人设置；pair 保存双向拉黑和 accepted 好友状态。`readOwnerState` 在持有 durable scope 锁时核验 Owner/epoch/revision、拒绝 pending change，再取得对应事实和基于数据库时钟的保守单调截止时间。保留旧账户/关系/设置锁名用于切换期读写排序；开启内存路径的前提仍是所有相关写入口统一进入版本边界，不能混用不推进版本的旧 writer。

每个 Policy Owner 保存一份版本绑定事实，在截止时间内复用；缺失/过期时合并实际冷加载 SQL root。变更和恢复开始时清空缓存并推进内存 generation；晚到的旧加载不能重新安装缓存。领域变更实际提交后，在原执行 root 内重新取得权威事实并发布到内存；刷新失败不撤销已提交操作，清空缓存等待下一次受围栏加载。Owner 关闭使内存失效并等待实际 root，取消调用方不释放尚未结算的 SQL。

目录增加 registrationStates，本地 `V2RoomPolicyAuthorizationService` 冷加载改用三份 Owner 内存事实组装完整发送策略。新 `register(states:)` 不再读取账号/关系/设置表，但在控制事务内继续验证三个 durable Owner/epoch/revision/seal，并登记可撤销 holder；只有此登记成功才可安装房间许可。因此内存事实本身不是消息执行权限，也不能绕过换主或版本变更检查。远程 claim 当前仍返回 lease metadata，远程房间服务仍沿用完整控制事实 SQL 冷加载；认证响应携带完整 scope facts 尚待下一步接入。

真实双数据库测试先以原 SQL reader 读取基线并预热三份 Owner 状态，再临时隐藏六张控制事实表；重复取得 Owner 状态和注册房间快照仍成功且与基线一致，证明这一路径没有再次访问事实表。恢复表后通过真实 dispatcher 修改陌生人设置和拉黑，验证 Owner 内存事实及 revision 更新、旧状态登记被 durable version 拒绝、新状态包含最新拒绝策略。另一个测试实际锁住 scope 行，验证两个状态请求合并为一个被 PostgreSQL 阻塞的 SQL root，调用方取消后关闭仍保持该 root，解锁结算后才释放。

最终 `/tmp/imv2-policy-state-tests.log` 7 项/2 个 suite，`/tmp/imv2-policy-state-remote-regressions.log` 22 项/2 个 suite，`/tmp/imv2-policy-state-runtime-regressions.log` 8 项/2 个 suite，`/tmp/imv2-policy-state-settlement-tests.log` 2 项/1 个 suite 全部通过。去除重复内存状态测试，共 38 项/5 个 suite，包含本地事实缓存、真实 SQL 生命周期、四类领域变更和恢复、工厂、多房间准备、远程策略变更、认证和消息授权并发场景。Infrastructure 和最终测试源码编译通过；独立 PostgreSQL 已关闭。

仍需完成：远程认证 claim 携带 Owner 完整事实及房间登记接入、生产 placement/endpoint 配置、全部业务写入口和 Node/工厂统一启用、特殊账号变更与封禁/解封模型、恢复/发布 worker、群聊/转发覆盖及 10,000 在线/1,000 新消息每秒验收。以上专项结果不证明整体生产切换或最终容量目标完成。

### 认证的跨节点完整策略状态

Policy ownership signed RPC 的响应现携带完整 scope facts，绑定原 Owner lease（canonical scope、Owner ID、epoch、revision、数据库有效期），并携带从 Owner 单调时钟截止时间采样的 remainingSeconds。Wire 严格限制 facts 为 1..16 KiB、剩余时间有限且在 (0,300] 内；自定义解码再次验证。事实使用 Infrastructure 的 Codable account/pair 结构，不将 SQL/database 领域实现引入 ActorCluster。

接收服务改用 `registrationStates`，所以 Owner 截止时间内的冷加载请求复用内存事实；初次加载和过期更新仍读取受 scope 围栏保护的权威数据库。Cluster 客户端验证 signed exchange、完整 scope 集合以及 configured expected Owner ID；Infrastructure 再验证 facts case 对应 account/pair scope，account facts 的 user ID 必须与 scope 相同。只有已验证的完整状态能够进入房间登记。

远程 adapter 从开始路由查询前采样本地单调时间，以该时间加上回复中的 remainingSeconds 构造保守截止时间；route resolution、握手、服务处理和返回传输全部消耗预算，不比较跨节点 wall clock，不在收到响应时重新延长租约。收到时已过期的状态被拒绝。远程 `V2RoomPolicyAuthorizationService` 与本地路径统一使用三份 states 组装策略，再通过 durable journal 检查三份 Owner/epoch/revision/seal 和登记 holder；房间侧不再读取控制事实表。普通消息仍使用既有房间快照和可撤销许可。

三节点原生 TCP + 双数据库测试先预热远程 Owner 状态，用原 SQL reader 取得基线，然后隐藏六张控制事实表；真实跨节点请求仍取得完整状态，房间 `register(states:)` 成功且策略与基线完全一致。恢复表后经真实远程 business store 处理拉黑、陌生人设置和账号停用，重新取得远程事实验证 account active/stranger 和 pair blocked 的版本更新；原状态无法再登记。测试夹具还在真实已签名响应中注入短到会在传输途中到期的 remaining lifetime，以及与 scope 不符的 account ID，验证客户端分别以 staleVersion/invalidTarget 拒绝。Owner 强制换主后的旧 epoch 拒绝仍通过。

最终 `/tmp/imv2-policy-remote-state-tests.log`：远程真实业务测试 1 项/1 个 suite 和认证 22 项/1 个 suite 通过；`/tmp/imv2-policy-remote-state-regressions.log`：Server 17 项/4 个 suite、Cluster 50 项/3 个 suite 通过。去除重叠认证测试，共 68 项/8 个 suite，覆盖本地/远程事实缓存、生命周期、领域变更/恢复、房间工厂、多房间准备、消息事务和撤销、wire/角色/身份、bridge 和本地能力。Infrastructure build、最终测试源码编译与 diff 检查通过；独立 PostgreSQL 已关闭。

仍未完成：生产 placement/endpoint 发现配置（Directory Owner ID 须与可信路由身份统一）、Node/房间工厂与全部业务写入口的统一装配和启用、特殊账号变更与封禁/解封模型、恢复/发布 worker、群聊/转发覆盖，以及 10,000 在线/1,000 新消息每秒容量验收。Owner 完整授权事实现已支持本地及远程内存冷加载，但专项验证不证明生产全链路切换及容量目标完成。

### 有界策略恢复与提交后发布任务

目录恢复不再只读取全局最早的 128 条再过滤本节点 scope。新增精确 PostgreSQL timestamp text + operation key 的 keyset page/cursor，避免经过 Foundation Date 时舍入数据库微秒。每轮记录固定上界，按有界扫描预算跨过外来 scope，跨 tick 保留位置，到达本轮上界后从头开启新一轮；持续新增记录不无限推迟失败旧记录重试。默认一次最多扫描 512、处理 128，单次上限分别 4096/128。本节点 pending command 校验冻结命令、scope/key/fingerprint，再由已有 Owner 的 durable 恢复路径执行；最多并行恢复八个 scope，逐项失败报告不会取消其他 scope。仍然不能以到期或 RPC 失败代替房间真实撤销证明。

新增 outbox publisher，采用相同有界扫描和固定上界，并在 SQL 中只暴露每个 scope 最早的未发布 revision。低版本未确认时不越过它发布同 scope 的高版本；其他 scope 可并发。索引 `policy_authorization_outbox_scope_pending_idx` 支持 scope/revision 未发布查询，已加入未发布 bootstrap schema。投递不持有控制事务；实际接收端确认后按不可变 operation/scope/revision 精确标记 published，未知/失败保持 outbox，可幂等重放。多个 publisher 的重复投递要求接收端按原始事件身份去重，publication 不承担或绕过授权撤销。

`PostgresV2PolicyCommittedEffectsPublisher` 从已提交 change 和永久回执重建后续业务投影，不依赖原 HTTP 调用方仍然存在。已应用的社交命令投递双方用户分片，陌生人设置投递对应用户；接收结果数必须完整且每项序号有效，nil/零序号不作为发布成功。账号停用已在原提交事务内写入设备撤销事件和资料 outbox，继续交给现有对应 worker；已拒绝/无效果的领域结果无需制造不存在的投影。

`V2PolicyMaintenanceWorker` 支持周期 start、合并手动 tick、独立并发的恢复和 publication，使已提交投递可以在其他策略等待撤销时推进。原生实际工作保留在 detached root 内；停止关闭准入、取消周期等待、等待实际 recovery/publication 完成并关闭 publisher，再由 Composition 关闭 Owner、RPC 客户端和数据库。周期重复 start 不生成多个 loop；各轮报告保留 scanned/attempted/completed/failed，SQL 故障保留待恢复记录。

真实双数据库测试持久化 131 条外来 pending、一个损坏的本地 command 和一个合法拉黑，逐轮追加其他节点任务；固定上界扫描仍恢复健康命令，并在下一轮重试损坏的旧命令，而不追着新增尾部无限扫描。恢复后的真实领域结果经 committed-effects adapter 投递到持久化测试用户分片接收端，nil 确认保持 policy outbox，有效确认后双方各写入一次。精确 publication 元数据错配被拒绝。另一 PostgreSQL 测试启动周期 worker，投递已在接收端持久化但确认被阻塞/丢失时，关闭保留实际 root、不给 outbox 提前 ACK；重建 publisher 后重复投递去重，先确认 revision 2 再发布 revision 3。

最终 `/tmp/imv2-policy-maintenance-verified-tests.log` 3 项/2 个 suite 通过；`/tmp/imv2-policy-maintenance-regressions.log` Server 19 项/5 个 suite、Cluster 50 项/3 个 suite 通过；`/tmp/imv2-policy-maintenance-remote-regression.log` 实际三节点策略 cold-load/变更测试 1 项/1 个 suite 通过。去除重复专项测试，共 70 项/9 个 suite。覆盖维护、持续新增公平扫描、确认丢失和版本顺序、域恢复、Owner 内存状态、工厂及多房间准备、消息许可/撤销并发、认证、bridge、本地能力和远程策略状态。Infrastructure build、最终源码编译和 diff 检查通过；测试独立 PostgreSQL 已关闭。

仍未完成：生产 placement/endpoint 发现配置、全部策略业务入口和 Node/房间工厂统一启用，以及维护 worker 的生产启动/关闭与投影 delivery 装配；特殊账号变更与封禁/解封模型、群聊/转发覆盖、10,000 在线/1,000 新消息每秒容量验收。恢复/发布组件已有实际验证，不能据此宣称生产维护链路已经启用或整体目标完成。

### 固定 Policy Owner 部署归属和认证实例路由

新增严格 Codable placement 文档：正 revision、1..4096 的二次幂分区、最多 64 个唯一 stable Host，每个分区恰好属于一个 Host/endpoint。重复/遗漏/越界分区和重复 Host 被拒绝；Host 与分区数组排序归一化。Infrastructure 使用固定域前缀 `imv2-policy-scope-v1`、canonical scope 的 SHA-256 前八字节大端值及分区掩码进行选择，不使用随机化 Swift Hasher，不以当前在线人数或空余房间容量改变账号/用户对的归属。scope 必须是 canonical account/pair UUID key。部署摘要包括算法版本域和排序后的完整配置。

新增 control `policy_owner_deployment` bootstrap 表及 startup contract store：首次记录唯一 active revision/digest，后续同配置启动幂等，任何不同映射或 revision 拒绝而不自动覆盖。配置升级/再分配必须单独进行受控部署，不能由节点各自重写 active snapshot。readiness 纳入该表。此组件尚需组合根在开启新模式前统一调用，不能把 DTO 验证等同于生产 deployment contract 已装配。

`PostgresV2PolicyDeploymentRoutes` 从固定分区取得 stable Host 和 endpoint，再从受既有认证发现保护的当前 descriptor 解析 incarnation，作为远程 claim 的 expected Owner ID。只选择所配置的 Host/endpoint，缺失/不健康/被挂起时拒绝，不改选其他有容量的 Host；availableRooms 为零不妨碍策略处理。Directory 的服务端 scope predicate 和房间/业务写入端共用同一个 placement。

Actor application 部署配置新增可选 policyPlacement，并验证 Host 在 pinned peer 集合、endpoint 属于该 peer、Caller 有显式 mutation 权限及访问集合、房间 Host 有 registration 权限、Policy Owner 服务有 mutation/registration/revocation 权限和所有房间分片访问权。没有自动扩大旧服务权限。新增 coherent `V2PolicyHostedServices` 启动能力，声明配置必须一致，房间工厂所有物理 Owner 必须启用 policy authorization；配置了新 Host 模式但缺少服务组件时在创建活动节点前拒绝，避免静默使用旧授权工厂。服务能力传入 Node 的 ownership/mutation/revocation 三个端点；Actor application 提供受部署配置绑定的 package scope state/mutation client facade。Gateway/Account/Operator 的具体组合根仍未装配这些能力，默认路径仍保持未启用。

三节点真实 TCP/双数据库测试改为使用固定 placement、服务端相同 scope predicate 和 deployment routes，三个依赖被分配到预期 Host；descriptor 空余房间为零仍能领取完整策略和执行三类变更，未知 Host/错误 endpoint 不会改选其他节点。独立测试用 Python SHA-256 得到的固定向量验证 scope 分区为 3/4/14，并验证数组顺序不改变摘要、非法 scope/placement 被拒绝。PostgreSQL contract 测试验证重复启动成功、同 revision 不同映射和不同 revision 拒绝、原单例记录保持不变。

用任务新建的本地 CA/签名材料生成真实 Gateway/Account 配置运行 application 测试，无跳过：验证旧 host/caller 配置继续加载、新 placement 解码、未知 Host/endpoint/缺失角色拒绝、新 Host 模式缺少服务组件拒绝启动。临时签名/TLS 文件仅用于本次测试，未输出密钥内容，测试后清理。

最终 `/tmp/imv2-policy-placement-verified-tests.log` Server 3 项/2 个 suite 和 ActorApplication 4 项/1 个 suite 通过；`/tmp/imv2-policy-placement-regressions.log` Server 21 项/6 个 suite、Cluster 50 项/3 个 suite、ActorApplication 4 项/1 个 suite 通过。去除重叠专项，共 76 项/11 个 suite，覆盖固定路由、配置/契约、三节点事实/变更，以及维护、缓存、工厂、多房间、许可/撤销、认证和 Cluster 回归。ActorApplication/Infrastructure build、最终源码编译和 diff 检查通过；独立 PostgreSQL 已关闭。

仍需完成：房间撤销 endpoint 的精确 Host/物理存储定位（不能把共享 room shard 的任意 Host 当成目标）、Gateway/Account/Operator 的统一生产装配与 lifecycle、所有策略写入口/特殊账号变更及封禁/解封模型、群聊/转发覆盖，以及 10,000 在线/1,000 新消息每秒容量验收。本阶段实现配置和启动能力边界，未宣称生产新模式已启用。

### 房间许可撤销的稳定 Host 与物理存储定位

新增 `V2RoomPolicyEndpointLocator`：许可 endpoint 编码 stable Host UUID 和物理房间存储别名，使用严格 canonical 编码、UTF-8/长度校验；不含 incarnation，使同一 stable Host 重启后仍能处理旧许可的持久撤销义务。注册 ID、activation ID、room Owner epoch、generation 继续由完整 holder 标识，定位信息本身不构成撤销证明。

`PostgresV2RemotePolicyRevoker` 新增 pinned roomHosts 构造入口：解析 locator 后先检查 Host/物理别名白名单，再从认证发现取得该 stable Host 当前 incarnation；缺失或不健康时失败，不按共享分片选其他 Host，也不接受裸分片名作为此入口的路由。接收端将 locator 解码后的物理别名用于原有 serviceShardAccess 权限校验，并在调用实际撤销服务前校验 locator stable Host 等于自身。

新增 `V2RoomPolicyRevocationRouter`，一个 Host 按物理别名绑定实际 authorization directory。启动校验每个服务 endpoint 与 Host/别名完全一致；未知路由拒绝，不扫描其他数据库。房间服务新增 locator 构造入口，生产组合可统一使用编码 locator 注册及撤销。旧 String/自定义 resolver 构造保留供既有局部调用，新的生产组合必须使用 locator 和 pinned resolver/router。

真实 TCP/独立 PostgreSQL 撤销测试改为编码 locator 和 pinned resolver，新增其他 Host 的签名请求被拒绝、未配置存储路由被拒绝且许可保持未撤销；正确请求在实际 SHARE 消息事务释放前不 ACK，正常调用和取消后重试仍必须得到实际持久围栏证明。另验证 canonical locator、Unicode/分隔符别名、非法编码及边界长度。分发层最终专项验证结果待下面追加。

仍需完成：完整节点重启后旧许可撤销及多 Host 共享分片路由验证，Gateway/Account/Operator 统一生产装配、维护任务 lifecycle、全部策略写入口/特殊账号变更/封禁解封、群聊和转发覆盖，以及 10,000 在线/1,000 新消息每秒容量验收。此阶段没有启用生产新授权模式。

本阶段 `/tmp/imv2-policy-endpoint-verified.log` 的 Server 6 项/3 个 suite 与 Cluster 23 项/1 个 suite 通过，共 29 项/4 个 suite。分发层接入后的 `/tmp/imv2-policy-endpoint-router-tests.log` 再次通过真实 TCP 撤销专项（1 项、正常及取消两个 case），包含 Host/别名启动错配拒绝。最终源码编译通过，本次改动文件 diff 检查通过；全仓 diff 检查另报告既有 `V2DeviceConnectionRegistryReentrancyTests.swift:1123` EOF 空行，未修改该无关文件。独立测试 PostgreSQL 在验证后关闭。

### 重启撤销验证与 Account 策略写入口接线

新增真实 TCP 重启测试：原 Host runtime、Inbound、authorization directory 和 ClusterSystem 全部关闭，检查 runtime 停止完成并等待 ClusterSystem 实际 shutdown。独立持有的 PostgreSQL 消息事务继续占用旧许可 SHARE 围栏；同 stable Host 的新 incarnation 启动全新空目录，同时另一个 stable Host 提供同一 room-b 分片。注册新 descriptor 后，固定解析只返回新 incarnation，空闲房间容量为零不改变路由。实际 fallback 调用计数证明只有新实例收到撤销，原实例与共享分片其他 Host 均为零；SQL 未结束时不能 ACK/提交策略，结束后得到原完整 holder 的证明并提交，旧许可安装被拒绝。

首轮新增测试失败因辅助方法未保留 `V2RoomHostEndpoint` 引用，端点提前释放后握手成为 dead letter；辅助节点现持有实际 endpoint 到 shutdown，最终测试通过。没有将端点消失或观察超时当成旧 SQL 已完成。

Account 组合根将 social/preference routes 的注册移至 Actor client 构造之后。配置 policyPlacement 时，先校验控制库部署 revision/digest，再取得由该配置绑定的远程 mutation executor，注入社交操作及账号设置 store。陌生人设置进入 Account Owner，拉黑/解除好友等社交操作进入 Pair Owner；其他不影响消息授权的偏好维持其原领域存储行为。未配置新模式时不能忽略控制库已建立的新部署映射。

新增 `PostgresV2PolicyDeploymentPlacementStore.requireLegacy()` 启动检查。Account 无新配置、Gateway 无新配置以及尚未接入远程 Owner 的 Operator 组合，在控制库存在 active deployment 时拒绝启动，避免静默创建旧授权写入进程。真实 PostgreSQL 测试验证空映射允许旧模式、建立映射后拒绝旧模式。此检查只约束新启动；生产切换仍必须排空并关闭已运行的旧进程，不能把 startup check 当成持续写入围栏。

`/tmp/imv2-policy-restart-fixed.log` 重启和撤销专项 2 项/1 个 suite（包括正常、取消参数 case）通过。Account target 最终 `/tmp/imv2-policy-account-binding-verified-build.log` build 通过；`/tmp/imv2-policy-account-binding-integration.log` 原生三节点策略入口及部署契约 3 项/2 个 suite 通过。最终 `/tmp/imv2-policy-cutover-verified.log` 5 项/3 个 suite 通过，覆盖更新后的部署约束、三节点远程社交/设置/停用与幂等/冲突、重启/共享分片撤销；最终测试构建包含 Account、Operator、Gateway 组合根编译。本阶段变更文件 diff 检查通过，独立 PostgreSQL 在验证后关闭。

仍需完成：Gateway hosted Owner/房间授权/可信 RPC 发现的统一构造和生命周期、Operator 远程策略入口与所有旁路写入口、维护恢复/Outbox worker 生产启动关闭与 delivery 装配、特殊账号和完整封禁解封模型、群聊/转发覆盖，以及 10,000 在线/1,000 新消息每秒容量验收。Account 接线是受显式配置控制的生产代码变更，尚未完成跨服务全链路部署或压测验收，默认配置没有启用新模式。

### Gateway 策略依赖与一次性 RPC 客户端绑定

新增 `V2PolicyClusterClientBinding`，启动前持有空状态，授权冷加载/撤销在未绑定时立即返回 busy，不挂起等待且不保留控制事务。Actor application 创建实际 Host client 并启动可信发现后，将客户端一次性绑定到 hosted services 指定的 binding；重复绑定拒绝，关闭后不能重开。Remote Policy Owners/Revoker 新增 client provider 构造入口，原有直接 client 构造保持使用相同调用逻辑；实际 claim 的时间预算仍从获取客户端/路由前开始计算。

新增 `GatewayPolicyAssembly`：配置新模式时使用同一 control deployment contract/placement，Owner ID 固定为当前 Host incarnation，scope predicate 与客户端分区映射相同。房间撤销 resolver 的 stable Host/alias 白名单来自部署 pinned peers。物理房间库按 physicalStoreKey 分组，选择本 Host 可访问的 canonical alias，多个逻辑别名共用同一授权服务和资源能力；locators、复合撤销 router 与实际目录统一绑定。房间工厂用绑定后的 resources 构造，ownership/mutation/revocation 三服务一起传入 Actor application。

Owner 的 mutation dispatcher 使用既有真实领域存储与投影 delivery。周期恢复与 policy Outbox publisher 使用生产维护投影 delivery，并在 RPC client 绑定后启动。失败轮次记录低基数 worker 名和失败计数，不输出用户身份、命令或签名材料。关闭先停止周期任务并等待实际恢复/发布，关闭 Owner 并等待实际工作，再关闭客户端 binding，随后排空房间资源、Actor 与数据库。Gateway 对策略 drain 采用与其他实际 SQL 工作相同的 60 秒退出边界，超时不释放仍被使用的资源。

首次合并回归误将 native ownership 与维护领域测试并行；两者共用并重建 im_v2，独立 PostgreSQL 日志确认 CREATE SCHEMA 已存在及 DROP 后缺失冲突。这一测试调度错误不作为实现结论，最终必须分开运行。初始 Gateway target build 已通过；最终分开测试结果待下面追加。

仍需完成：真实完整 Gateway 新模式启动/关闭与业务路径验证、Operator 新模式远程策略入口、全部旁路策略写入口和特殊账号/封禁解封模型、群聊与转发授权覆盖、部署配置切换和旧进程排空，以及 10,000 在线/1,000 新消息每秒最终容量验收。此次接线没有默认启用新模式，组件回归和 build 不证明上述剩余事项完成。

最终 `/tmp/imv2-policy-gateway-binding-verified.log` 三节点原生策略测试 1 项/1 个 suite 通过，并覆盖未绑定 busy、正常一次绑定、重复绑定 identityConflict、关闭后 claim/bind closed；最终编译包含 Gateway 新装配、Actor application binding 和所有受影响基础设施。`/tmp/imv2-policy-gateway-lifecycle-verified.log` 维护/领域恢复、周期任务关闭、实际撤销/重启/共享分片和房间目录 7 项/4 个 suite 通过。合计 8 项/5 个 suite，均在分开运行后通过；本次源码与文档 diff 检查通过，独立测试 PostgreSQL 已关闭。

### Operator 账号停用进入远程 Policy Owner

Operator 组合根可读取自己的 caller-only Actor 配置。配置含 policyPlacement 时先验证控制库共享部署契约，在房间数据库依赖准备后启动可信 RPC Caller，将由同一映射绑定的 mutation executor 注入 `V2PostgresAccountDisableService`；HTTP bearer 认证和固定 operator principal 继续由既有路由/服务执行。无配置或无新模式时保留 legacy 模式，但控制库已建立 active deployment 则拒绝 legacy 启动。工作流重放仍只操作队列，不通过新 RPC 改变其原领域语义。env example 说明 Operator 需要独立调用方签名/mTLS 文档和显式 mutation 权限。

正常关闭先停止 HTTP，再等待 Caller 的实际调用排空，之后才释放数据库和 EventLoop。失败清理使用同样顺序；启动/关闭 drain 未完成时退出并保留共享资源，不把截止时间当作 SQL 已完成。新模式未默认启用。

真实三节点 TCP/双数据库测试增加 HTTP 停用链路：在设置变更后重新注册并安装 Account/Pair 三依赖许可，通过实际 Vapor route、Bearer 认证、远程 mutation service 和 Account Owner 完成停用；旧许可不能再次安装。HTTP 首次结果 disabled、重放 idempotent 且时间戳一致，换 reason 的相同操作返回 409；无 Bearer 不进入业务。后续直接服务重放仍使用同一永久回执，域停用记录和 policy committed change 数未重复增长，Owner 内存刷新仍包含 inactive 的新版本。

新增 unavailable 路径验证：本地数据库可用且已存在回执，替换为无法解析 Owner 的远程 adapter 后，HTTP 必须返回 503 而非本地幂等成功；响应空 body、Cache-Control no-store、Pragma no-cache。通用远程错误现与领域 unavailable 一样使用该响应，避免 RPC outcome unknown/发现失败遗漏缓存限制。

`/tmp/imv2-policy-operator-build.log` Operator target build 通过。最终 `/tmp/imv2-policy-operator-http-verified.log` 6 项/3 个 suite 通过，覆盖真实 HTTP/TCP 停用、认证与结果格式、幂等/冲突/不可用、许可撤销/Owner 刷新，以及持久 deployment 契约；最终编译包含 Operator/HTTP/共享调用路径，本阶段 diff 检查通过。独立 PostgreSQL 验证后关闭。

仍需完成：真实完整 Gateway/Account/Operator 新配置启动关闭和消息业务路径验证，剩余策略写入口/特殊账号及完整封禁解封模型，群聊和转发授权覆盖，部署切换及旧进程排空，10,000 在线/1,000 新消息每秒最终容量验收。Operator 已有停用模型不等同于可恢复的封禁/解封模型；专项绿灯不证明全链路验收。

### 群发送使用单账号策略快照

新增 `V2RegisteredAccountPolicySnapshot` 和对应注册 Store。群消息只注册发送者 Account 依赖，不构造虚假的接收者或 Pair 策略。注册验证完整 Owner 账号事实、版本和剩余寿命，沿用控制库冻结/排空协议和房间持久围栏。Gate 使用区分 account/direct 的版本类型，拒绝跨类型替换、同版本事实改变和混合形状。账号快照撤销后刷新必须使用新 registration ID；最初测试复用旧 ID 被身份守卫拒绝，修正测试保持该约束。

房间目录在完整 activation 围栏内读取 room_kind，私聊仍按持久双方身份构造两个方向，群聊按发送者构造账号运行时。Service 的本地/远程 Owner provider 均支持账号单依赖加载；准备、实际执行、撤销和退役使用共用的带类型快照。标量群消息 preflight 将 sender active 从注册快照绑定到 SQL，成员、角色、禁言和房间额度继续由房间事务检查；该分支不引用全局账号/关系策略表。

生产 activation 工厂测试新增群聊参数：正常发送后，Pair 拉黑不撤销群授权且仍可发送；两边数据库同时隐藏 public_user_profiles、special_accounts、account_disables、user_blocks、user_relationships、user_stranger_message_preferences 六表后，缓存群消息仍提交，退群和禁言仍返回 permissionDenied。群授权只有一个未撤销控制库 holder。恢复表名后，通过真实 Account Owner 停用发送者，群消息被拒绝；原 accepted 永久回执仍优先重放，Host 关闭清理所有活跃房间许可。私聊参数继续验证拉黑拒绝。

验证：`/tmp/imv2-policy-group-runtime-build.log` Infrastructure build 通过；`/tmp/imv2-policy-group-factory-verified.log` 10 项/3 个 suite 通过（生产工厂两个参数场景、跨房间准备、账号真实事务排空、Gate）；`/tmp/imv2-policy-group-runtime-regression.log` 8 项/3 个 suite 通过（私聊四种发送路径八个参数场景、延迟冷加载撤销、直接快照与目录生命周期）。本次相关 diff 检查通过。

群账号运行时当前每个 activation 最多保留 128 个发送者，尚无安全淘汰机制；这是继续完成大群容量设计的明确限制，不能把上述小规模群聊验证视为大群验收。转发仍未接入这一新准备入口，完整生产启动/切换、所有策略写入口和完整封禁解封模型、10,000 在线/1,000 新消息每秒最终容量仍未完成。新模式没有默认启用。

### 群账号缓存按空闲运行时安全淘汰

本轮解除上节累计 128 个发送者后永久拒绝新发送者的问题，保留每房间默认 128 个运行时的内存上限。Registry 按最近使用顺序选择候选；Runtime 在无悬挂点的 actor 方法中检查冷准备、执行许可提升、冷加载、实际执行和撤销根，只有全部为空才封住入口。随后 retained detached retirement root 关闭 Gate 并撤销已安装的房间持久许可，实际 SQL 清理完成后才能删除 entry/释放槽位。一个 activation 最多有一个淘汰根；其他缓存命中可继续，候选或新增未命中在该根等待期间返回 busy。全部候选有实际工作时返回 busy，不靠过期或取消伪造排空。

冷准备/许可提升跨 await 的阶段增加计数，封空闲入口不会与冷加载创建或 Gate reserve 的间隙竞态。排队准备句柄不永久占用缓存；被淘汰 Runtime 上的旧句柄 promotion 返回 closed，必须重新准备。被淘汰 activation 的晚到撤销使用持久围栏 fallback，不能撤销替换 Runtime 的新 activation/registration。数据库清理失败保留关闭的 entry 和容量；同一发送者后续请求先重试清理，成功后才创建替换 Runtime，旧实例不会因数据库恢复而复活。Host shutdown 同时加入实际淘汰根。

新增真实数据库缓存测试：单槽位安装许可，另一个 SQL 事务持有 SHARE 围栏，淘汰 UPDATE 实际被阻塞；取消调用方后容量仍为一，新未命中拒绝且旧准备无法执行。释放 SQL 后取消调用方返回 CancellationError，实际清理已释放槽位；新 Runtime 使用新 activation/registration，旧撤销不能改变它。另连续创建 130 个不同的未冷加载发送者验证有限缓存不会形成累计发送者上限，该场景不等同于 130 个并发发送者或吞吐压测。冷加载与真实执行事务参数场景均验证不可淘汰；隐藏持久许可表触发清理失败、恢复后同一发送者可重试替换。

`/tmp/imv2-policy-group-eviction-build.log` Infrastructure build 通过；最终 `/tmp/imv2-policy-group-eviction-verified.log` 9 项/3 个 suite 通过，含缓存专项、生产私聊/群聊工厂两个参数场景、私聊四种发送路径八个参数场景、延迟冷加载撤销和目录生命周期。相关 diff 检查通过。独立 PostgreSQL 结束验证后关闭。

仍需完成转发授权、完整 Gateway/Account/Operator 新配置业务启动及切换、剩余策略写入口与完整封禁解封模型，并完成 10,000 在线/1,000 新消息每秒容量验收。有限缓存全部忙碌的背压与实际大群流量表现还需压测验证；本轮正确性测试不证明容量目标已达标。

### 转发目标写入接入策略许可及共享准入额度

生产 Owner resources 的策略绑定现在同步绑定 RoomWriteStore。跨节点目标导入先在确切 activation 下读取收件箱状态：终态或媒体待处理直接返回；可接受命令通过可信转发专用准备入口取得目标 Account/Pair 快照和执行许可，实际接受事务继续校验不可变收件箱、媒体映射、完整命令指纹和房间持久许可。普通消息准备入口仍拒绝 forwardedFrom，只有可信转发工作流显式启用转发准备。完成收件箱的成功重放不重新申请旧授权意图或许可。

同节点双房间路径也绑定同一策略 Service，Gateway 为每个物理数据库的所有别名绑定 Pair executor，并把新 map 交给房间转发协调器。目标执行许可不授予源房间策略权限；selected owner 检查只允许确切目标加已绑定的 forward source，源/目标 route 和 activation 仍分别通过 SQL 围栏验证，来源可见性、成员区间和修订检查保留。原来的 target-only 集合检查会拒绝合法的房间对，本轮修正这一范围约束，普通发送的单房间边界没有扩展。

实际生产工厂测试暴露准入混用问题：普通持久发送的独立信用池会预扣完整小分片窗口（测试窗口为 10），转发标量路径另查数据库，因无法使用已有信用而永久返回 pending admission。新模式在每个物理策略 Service 内共享一个批量信用池，持久发送和转发均使用它。转发在实际事务前读取目标预算与完成状态、取得精确 operationKey 的预扣证明；标量接受使用该证明校验 lease/generation 并避免再次尾部预扣。已有完成跳过新预扣；取消、回滚或 COMMIT 不明仍消耗尝试，不退款。没有修改测试窗口来掩盖这个资源边界问题。

生产工厂私聊/群聊参数增加真实来源 export/import：普通消息先预扣小窗口后转发仍可接受；Pair 拉黑拒绝私聊新导入；群聊在两边六张全局策略表隐藏期间仍可导入，Account 停用后新导入 FORBIDDEN；已完成转发保持原结果重放，目标消息和旧授权回执/意图计数无重复。双房间测试同时运行 legacy/new 模式，覆盖同房间转发、相向房间对、过期 activation 和来源撤回后的回执恢复。新模式测试数据改为在启动前准备，恢复场景通过受新许可保护的实际接受和省略台账结果回调进行故障注入；最初直接清空已完成台账触发其不可变数据库约束，保留约束并修正测试。

`/tmp/imv2-policy-forward-build.log` Server target build 通过。最终 `/tmp/imv2-policy-forward-final-verified.log` 7 项/2 个 suite 通过（生产工厂两个参数、双房间 legacy/new 两参数、私聊四发送路径八参数、撤销/群缓存）；`/tmp/imv2-policy-forward-inbox-regression.log` 3 项/1 个 suite 通过（收件箱接受/恢复、16 个目标边界参数场景、两个私聊最终化恢复参数）。相关 diff 检查通过，独立 PostgreSQL 验证后关闭。

剩余限制明确保留：新模式 caller-only Gateway 未安装可撤销的本地双房间策略边界，pair map 返回 unavailable，禁止隐式使用预先构造的 legacy executor；须继续实现该部署形态的远程双房间执行。已接受但尚未最终化的导入目前仍进入策略准备，Owner 不可用时的强恢复语义和许可尽早在接受 COMMIT 后排空仍需完善；新模式媒体/复杂转发故障覆盖、完整服务启动及切换、其他策略写入口、完整封禁解封模型与 10,000 在线/1,000 新消息每秒容量均未完成。新模式没有默认启用。

### 转发接受提交后释放许可，并从不可变回执恢复

新模式跨库导入预检在目标 activation 围栏及收件箱锁内识别 accepted 状态，直接读取 message_send_completions。恢复必须核对完整命令指纹、收件箱消息 ID、房间序列及可编码时间；缺失或不匹配的接受回执报告持久化损坏，不能重新发送。当前文本限制不改变已接受消息的身份。该恢复不获取新的 Policy Owner 快照、控制库 holder 或准入信用；仍需持久媒体映射用于重建命令，不能据此声称媒体映射丢失也可恢复。

跨库导入拆分实际接受事务与最终化，executeForward 只包围接受及其实际 COMMIT；之后从未绑定执行许可的 Store 完成缓存收尾和收件箱最终化。同库双房间路径同样提取实际消息/台账提交，Policy Service 返回提交结果并排空许可后才执行进程缓存收尾。来源和目标 activation、来源可见性、台账原子性及准入错误回滚守卫保持在原接受事务内。legacy 控制授权确认流程保留。

新增真实双数据库测试四个参数场景（私聊/群聊 × 正常恢复/缺失回执）：通过触发器及真实 advisory lock 阻塞接受后的最终化，确认收件箱处于 pending finalization；此时通过 Account Owner 停用发送者仍可完成，旧房间许可已全部撤销。关闭 Owner、释放阻塞并注入最终化事务失败后，同时隐藏两库六张全局策略表，正常场景仍恢复同一消息回执且重复重放不增加消息、个人事件待办或控制 holder。故意删除不可变完成记录的场景仅在一次性数据库移除保护触发器后执行，预检必须报告 corruptPersistenceState 并保留待最终化状态；没有弱化生产不可变约束。

`/tmp/imv2-policy-forward-recovery-build.log` Infrastructure build 通过；`/tmp/imv2-policy-forward-recovery-tests.log` 新测试四个参数场景通过。最终改动回归 `/tmp/imv2-policy-forward-recovery-regression.log` 4 项/1 个 suite（10 个参数场景）通过，包含跨库收件箱 standard/large、私聊最终化及所有者变化、新模式恢复/损坏和同库双房间 legacy/new；`/tmp/imv2-policy-forward-recovery-factory.log` 生产房间工厂私聊/群聊两个参数场景通过。同库许可范围缩小经源码边界检查及双模式行为回归验证；本轮没有专门阻塞其进程缓存收尾的测试。相关 diff 检查通过，独立测试 PostgreSQL 验证后关闭。

仍需实现 caller-only Gateway 的远程双房间执行，补齐新模式媒体及复杂转发故障、完整服务新配置启动关闭及切换、全部策略写入口和可逆封禁解封，并完成 10,000 在线/1,000 新消息每秒容量验收。账号策略依赖当前粒度也仍偏粗，设置变更的最小失效范围尚未拆分。新模式仍未默认启用，专项回归不证明全目标已完成。

### caller-only Gateway 将双房间转发交给目标宿主

新增已认证的 forwardPair RPC：请求只包含可信转发身份及已解析的目标 activation，不接收调用方提供的预留凭据或事务完成分类。认证要求 service principal 和 roomCoordination 权限，校验目标房间与宿主，沿用签名会话、重放守卫、服务分片权限、入站容量和单调截止时间。普通 invoke(.sameOwnerPair) 仍被拒绝。宿主先确认目标就绪，再由自身协调器按规范顺序获取并标记源/目标预留；执行前必须确认实际目标预留等于输入的完整 activation，两个房间属于同一逻辑分片。宿主执行器负责实际 SQL、策略许可、台账及提交结果分类，协调器负责两个预留的结算；调用方仅验证原来源/目标对应的签名结果。

Gateway 新模式现在统一走该远程入口，包括 caller-only Gateway；没有本地 legacy SQL fallback。宿主配置继续为各物理数据库/别名绑定策略执行器，将其安装到 V2RoomForwardPairService。Actor application 启动宿主和 RPC client 后，将自己的 RoomDirectory 及 ReservationCoordinator 一次绑定到服务，未绑定时返回 unavailable，重复绑定拒绝。目标房间可能与源房间位于不同宿主，但共享同一逻辑分片及数据库时，宿主协调器仍通过自身 Directory 取得双方的确切预留；本轮实际 TCP 测试只覆盖两房间在同一宿主的形态。

正常停止在节点、目录实际排空后关闭服务；服务关闭会清除协调器引用，打断 Coordinator → Directory → local Client capability → inbound service 的持有环。已进入执行的方法保留自身的协调器直到结束，关闭不会伪造 SQL 结算；关闭后不能重新绑定。Gateway 的策略资源清理也执行幂等关闭。启动绑定在宿主启动的现有失败排空分支内完成。

新增真实双节点 Cluster/TCP 与 PostgreSQL 测试（两个 ClusterSystem 位于同一测试进程）：调用方没有 SQL 执行器，通过宿主提交并重放转发；隐藏六张全局策略表后，另一条热缓存转发仍成功。经真实远程 mutation RPC 拉黑双方后，新转发被拒绝；撤回来源后原成功结果继续重放。不同 activation 代次被拒绝，未绑定及关闭后的 RPC 不执行 SQL；目标消息计数保持两条成功写入。最初测试只接持久 fence，导致运行时 Gate 未关闭而返回 outcomeUnknown；改为通过真实 Policy Service 撤销，保持生产协议而不是放宽断言。测试中的宿主协调器使用实际 Host reserve/mark/finish 适配，尚未以完整应用启动验证生产 Directory 接线。

`/tmp/imv2-policy-remote-pair-build.log` Gateway target build 通过。最终 `/tmp/imv2-policy-remote-pair-final-verified.log` 5 项/2 个 suite（11 个参数/单场景）通过，包含远程权限、真实 TCP 业务、生产私聊/群聊工厂、接受后恢复及同库 legacy/new。`/tmp/imv2-policy-remote-pair-boundaries.log` 35 项/4 个 suite 通过，覆盖原有 TCP 策略所有权/HTTP 停用、认证、预留协调与应用配置；该回归先于最后的引用清理改动，最终编译及专项测试包含清理改动。相关 diff 检查通过，独立测试 PostgreSQL 结束后关闭。

仍需验证不同宿主的同分片房间对、远程执行期间 ACK 丢失/取消/超时和真实应用启动关闭；补齐新模式媒体及复杂转发故障、部署切换、全部策略写入口、账号依赖最小失效范围和可逆封禁解封，完成 10,000 在线/1,000 新消息每秒容量验收。新模式仍未默认启用，整体目标保持未完成。


### 同分片跨宿主转发与取消后的持久恢复

本轮远程房间对测试改用实际 RoomDirectory、分片路由、租约及 reservationOperations，而非直接 Host 适配。两个参数覆盖同宿主与源/目标不同宿主；三个 ClusterSystem 位于同一测试进程，通过真实 TCP 和 PostgreSQL 执行。源宿主在夹具中仅服务预留，目标宿主负责 Pair 执行；源宿主不提供冷激活容量，避免恢复迁移到夹具未实现的 Pair 服务。此覆盖不等同于完整 Gateway 应用启动或多进程部署。

新增 Directory.callForwardPair 有界重试，Actor Application 转发入口使用它。每次尝试保留完整操作身份，重新确认当前目标 activation；显式 stale/retired/leaseLost 只失效匹配的缓存代次，短暂不可用不盲目删位置。一旦任一尝试结果不明，后续取消、到期或拒绝不能将总结果降为确定未接受。目录 quiesce 同样计入此类调用。

故障场景在实际 SQL 完成后扣留 RPC 响应，验证调用方结果不明时服务端请求仍存在，原操作重放返回同一接受结果；另用 PostgreSQL 行锁观察实际 SQL 阻塞，取消调用方后双方预留和服务端执行仍保留，释放锁并等待实际根结束后，以原操作恢复。目标成功消息总计五条，恢复不增加重复消息。夹具退役补齐策略注册清理，旧 activation 不得复活。

测试同时暴露了真实业务分类缺口：第四条陌生人转发触发 strangerMessageLimitReached，却被房间对入口归成 outcomeUnknown，导致不必要的双房间退役。入口现在将此明确业务拒绝映射为 RATE_LIMITED。测试保留实际额度上限并断言拒绝，之后经真实远程策略 RPC 请求/接受好友关系，重新加载授权，再进行取消场景，未放宽额度掩盖失败。

最终 /tmp/imv2-policy-pair-final-verified2.log 四项测试、两个 suite、十个参数场景通过，包括拉黑/解除好友/陌生人设置/停用的事务外排空与原子策略写入、原生 TCP 两种宿主布局，以及重试身份和结果不明语义。临时诊断输出已移除。 目录完整回归 /tmp/imv2-policy-directory-retry-regression.log 共 32 项测试通过；相关 diff 检查通过，独立测试 PostgreSQL 已关闭。

整体目标仍未完成：须继续细分账号状态与陌生人设置依赖，补齐全部策略写入口和可逆封禁/解封，验证完整应用启动关闭、新模式媒体与更复杂故障、部署切换，最后完成 10,000 在线、1,000 新消息每秒验收。新模式尚未默认启用。


### 陌生人设置与账号状态拆分授权依赖

新增 canonical stranger:<user UUID> scope，其权威内存事实仅包含用户与 allowsStrangers，使用独立 Owner lease/revision、变更 seal、持久注册、撤销与恢复。Account facts 不再包含或读取陌生人设置，也不再获取该设置的 advisory lock；账号活跃状态及特殊账号权限仍归 Account scope。陌生人设置命令现在路由到 Stranger scope，拉黑/好友关系归 Pair，账号停用仍归 Account。

私聊授权快照显式登记发送方 Account、接收方 Account、Pair、接收方 Stranger 四项依赖。远程 claim 上限及本地 journal/Owner Directory 的有界入口调整到四项，签名 wire 包含严格校验的 Stranger identity；固定 SHA256 分区路由接受此新 scope。完整私聊快照的两个注册入口均要求全部四项，禁止遗漏设置依赖后生成许可。Gate 的 direct 版本增加独立 stranger 维度，单独验证单调性及同版本事实一致性，推进账号版本不能夹带改变陌生人权限。

群聊保持只登记发送方 Account。生产工厂测试增加该发送方陌生人设置实际持久变更，确认 Account revision 仍为 1、Stranger revision 推进为 2、群聊 Account holder 未撤销；随后隐藏控制与房间数据库的六张全局策略表，群聊消息及转发仍能接受。同一测试后续停用发送方，新的群聊转发仍被拒绝，房间成员/禁言检查继续有效。私聊当前对好友也登记 Stranger，进一步按实际授权分支缩小设置依赖尚待完成。

最终 /tmp/imv2-policy-stranger-native-tests.log 原生 TCP 分布式策略测试一项通过，覆盖四依赖路由、缓存事实、远程设置、HTTP 停用、失效与重放；Account 停用与 Stranger 设置分别推进各自 revision。/tmp/imv2-policy-stranger-final-regression.log 共 22 项、六个 suite 通过（消息运行时八参数、生产工厂两参数、远程房间对两参数、四类领域变更、快照、Gate、Owner Directory 和部署分区）。该回归使用移除 Account 设置字段后的最终编译产物。相关 diff 检查通过。

此协议与依赖结构变更仍属于尚未默认启用的新模式；不证明旧节点与新节点可混合部署，切换必须排空旧注册及写入口，不能把旧 Account 版本下的设置快照当作新许可。整体仍须完成好友授权的最小设置依赖、全部策略写入口、可逆封禁解封、完整应用生命周期、新模式媒体/复杂故障、部署切换与 10,000 在线、1,000 新消息每秒容量验收。


### 好友授权省略陌生人设置依赖

生产 Policy Service 的本地/远程两种 Owner 接线现在先取得双方 Account 与 Pair 的内存事实，仅当 Pair 表明不是好友时再取得接收方 Stranger。内存事实注册入口要求好友分支恰好三项依赖，陌生人分支恰好四项；好友许可的 allowsStrangers 规范为 false，不携带或借用任何设置权限。三项依赖在持久注册事务里仍逐项验证实际 Owner epoch/revision，读取关系后并发解除好友不能让旧事实取得新许可。保留的 owner-only SQL 快照入口仍登记四项完整依赖，不作为生产内存路径 fallback。

Gate 的 Stranger version 可为空，但只允许好友且 allowsStrangers=false 的形状。依赖分支切换需要 Pair revision 前进，双方 Account 与 Pair 版本仍单调；保持陌生人分支时设置版本也必须单调。Gate 额外保留设置版本的最高已见值，即使暂时转为好友，之后解除好友仍拒绝低于先前已见版本的设置，不能用新关系版本掩盖设置回退。单位测试覆盖未推进 Pair 时删依赖、非好友缺设置、成为好友、解除好友及恢复旧设置的拒绝。

新增真实 PostgreSQL 因果测试：好友快照仅登记双方 Account 与 Pair，真实事务持有其 room fence SHARE 锁；陌生人设置的持久变更可在该事务未结束时完成，原许可仍有效。随后解除好友通过 Pair scope 撤销，观测实际 pg_blocking_pids 确认等待同一消息事务围栏，关系事实在等待期间未改写；释放真实事务后变更完成，旧好友快照登记失败，新非好友快照必须补齐已更新的 Stranger 依赖。既有原生 TCP 房间对测试也经过建立好友后重新取许可、取消 SQL、同操作恢复和拉黑的路径。

/tmp/imv2-policy-friend-isolation-tests.log 初始 13 项/两个 suite 通过；/tmp/imv2-policy-friend-message-regression.log 七项/三个 suite 通过，包含八种消息运行时参数、四种领域变更及两类快照。增加设置版本高水位保护后的最终 /tmp/imv2-policy-friend-final-verified.log 共 12 项/两个 suite 通过，覆盖完整 Gate、生产工厂两个参数、真实 TCP 房间对两个参数及好友执行隔离。相关 diff 检查通过，测试 PostgreSQL 验证结束后关闭。

整体目标继续保持未完成：全部策略写入口、完整可逆封禁解封、应用启动/关闭、新模式媒体和复杂故障、部署切换以及 10,000 在线、1,000 新消息每秒容量验收仍须完成。新模式尚未默认启用。

### 当前范围调整：先完成代码设计和实现

按用户最新要求，暂不推进真实环境闭环、部署切换及容量验收；上述历史段落中的部署与压测事项保留为后续工作，不作为当前阶段完成条件。当前阶段聚焦策略归属、内存授权、策略写入一致性、可逆封禁解封及相应本地验证。此前已经启动的 Actor Application 本地生命周期验证先收尾，其覆盖不等同于完整生产环境闭环。

策略写入口审计确认：现有 Account 的拉黑、好友关系和陌生人设置入口及 Operator 的永久停用入口已经接入 Policy Owner；尚未发现生产特殊账号状态写入口。永久停用不能直接作为可逆封禁：部分凭据路径依据 account_disables 判定失效，仅修改 profile 状态不能保证阻止登录；解封也不能恢复此前撤销的设备或凭据。可逆封禁需要独立领域语义，并统一账号授权事实与凭据检查。

本轮本地 Actor Application 验证通过（/tmp/imv2-policy-application-startup-tests.log）：一项测试、正常及实际 SQL 阻塞两种参数场景。两个 ClusterSystem 在同一测试进程中使用真实 TCP、TLS、PostgreSQL 和生产房间工厂，覆盖群聊发送、私聊转发重放、远程拉黑撤销及无关群聊继续发送；实际行锁阻塞发送时，短截止时间停止返回未排空，释放事务后发送接受并完成停止，Pair 服务关闭后不可重新绑定。夹具仅有一个投票宿主和一个调用节点，不覆盖完整服务 mains、生产多进程部署或容量。新增 opt-in 配置生成参数已实际生成本地测试配置，Python 编译检查通过；新模式仍未默认启用。

### 密码认证与账号暂停状态一致

为可逆封禁补齐密码边界的前置缺口：密码凭据读取必须具有 active 公开资料且不存在永久停用记录；登录完成在 KDF 之后按账号状态锁、密码尝试锁、凭据行锁的顺序复核，避免暂停期间提交成功认证审计。密码修改、恢复码修改和密码恢复的最终事务复用同一 active 检查；恢复码正确不能绕过暂停状态。KDF 仍在事务及账号状态锁之外执行。此变更没有为每条消息新增账号数据库读取。

真实 PostgreSQL 测试持有账号状态锁，启动登录完成并用 pg_blocking_pids 证明其实际等待，随后写入 suspended 并提交；登录返回 false 且无成功审计。暂停时密码读取和正确恢复码重置均拒绝，凭据 revision 不变；恢复测试资料为 active 后可重新认证，而永久停用记录仍阻止认证，即使资料为 active。最终 /tmp/imv2-password-suspension-tests.log 四项测试通过，另外覆盖密码生命周期、HTTP 凭据并发替换、时间边界及失败审计回滚。相关 diff 检查通过，独立测试 PostgreSQL 随后关闭。

这只是密码路径的前置修复，不是完整封禁/解封实现；可信设备签发与刷新、独立封禁命令和持久回执、Policy Owner 版本及撤销、运维入口仍需统一。继续遵循当前范围，真实环境闭环后置。

### 范围纠正：撤回额外认证重构，回到消息性能主线

用户指出工作偏离后，撤回最近两轮额外引入的密码登录/恢复检查、设备签发/刷新检查及专属账号暂停测试，恢复这些路径此前的实现。上节密码测试记录只是撤回前的历史验证，不证明当前工作树包含那些修改。此前与消息热路径直接相关的 Policy Owner、独立 Account/Pair/Stranger 版本、授权快照、策略撤销及房间执行机制继续保留。

当前目标是消息热路径使用内存授权、降低逐条发送的数据库工作、保障房间间调度与资源隔离，并验证现有策略写入口使相关内存授权失效。完整可逆封禁产品功能和认证系统改造不再作为本次性能重构的完成条件；历史待办中这类扩展不代表用户要求新增该功能。真实环境闭环、部署切换和容量验收仍按用户要求后置。

### 热路径授权围栏合并数据库时间查询

房间授权围栏原先每次校验执行一次有序 SHARE 锁查询，再单独查询 clock_timestamp。现在合为一条 SQL：locked MATERIALIZED CTE 按 registration_id 取得全部租约行锁，observation MATERIALIZED CTE 的 count 依赖先消费全部锁结果，再采样一次数据库时间并用于整个 cohort。仍去重同一持有者、核对完整身份及撤销状态，租约 SHARE 锁持有到实际事务结算；不把时间检查移到锁查询的投影，不使用应用时钟替代数据库时间。安装和撤销路径保持原有行为。

新增真实 PostgreSQL 等待锁测试，两种参数分别让前面已经取得锁的租约和最后仍等待锁的租约过期；使用 pg_blocking_pids 确认实际阻塞、数据库时钟确认过期，再释放锁，两种情况均拒绝。最终 /tmp/imv2-policy-fence-clock-tests.log 九项测试、两个 suite 通过，包含完整持久授权 journal、两种过期等待、生产私聊/群聊工厂两个参数及消息运行时八个参数。相关 diff 检查通过，独立测试 PostgreSQL 随后关闭。

该改动明确减少每次授权围栏校验的一次数据库往返（两条 SQL 合为一条），不构成吞吐或客户端延迟达标证明。继续围绕消息热路径核对剩余数据库工作与房间隔离，不扩展认证或封禁产品功能。

### 当前代码核对与不同物理库的 Owner 准入隔离

按原方案重新核对房间顺序、独立准备、物理资源、内存授权、提交后 mailbox 及原身份恢复。修改前当前源码集中验证 /tmp/imv2-current-message-audit-tests.log：服务端 52 项、六个 suite 与 Actor RoomTurnLane 22 项通过，使用独立 disposable PostgreSQL。覆盖同库真实双 backend 并行、跨房间准备独立完成、取消与 drain、物理 loan 的续租/Sync 公平性、有界提交事实、好友设置最小依赖、生产私聊/群聊发送及真实 TCP 房间对恢复。该记录不等同于全量测试或容量验收。

核对生产装配发现：GatewayRoomOwnerAssembly 原先给全部房间物理数据库注入同一个 frontdoor 工作准入器，慢库即使没有占用另一库连接池，也可能耗尽其写入准入额度。新增固定 V2PhysicalDatabaseWorkAdmissions，以拓扑中实际连接池的配置身份为键，控制库复用 frontdoor 原准入器，其余库各有独立准入器；同库不同 schema/逻辑分片共用一份。普通写 batcher、Owner 资源的发送/读取与房间对转发执行器都使用其实际 Owner 的准入器。每库沿用相同的已有容量策略，连接池大小及实际 physical loan 上限没有增加；此变更允许独立数据库使用自身已有闲置容量，并非集群全局限额。

恢复读取的预留队列按每库实际 schema 数计算；控制库不再为其他库的恢复读取预留排队份额。运行压力来源通过 V2DatabaseWorkAdmissionMetricsGroup 汇总各库计数，按 controller identity 去重，累计计数及等待桶使用饱和加法；不在指标标签中暴露数据库配置身份。指标采样不合并各库的调度权。

新增因果测试先填满 A 的两份实际准入额度并确认其后继排队，再确认 B 可获准，B 释放不推进 A 的队列；随后释放 A 后其后继正常推进。验证同库重复键不产生第二个 controller、未知键无能力、重复 metrics 引用不重复计数、最终全部额度归还。/tmp/imv2-physical-admission-tests.log 20 项、四个 suite 通过，涵盖新隔离测试、完整工作准入回归、指标输出及实际 PostgreSQL 同库房间并行；/tmp/imv2-physical-admission-final-build.log 网关 target 最终编译通过，相关 diff 检查通过。

发送准备仍有共享控制侧的独立有界入口；其是否在纯热缓存的 Owner 读取期间造成跨物理库等待，需继续核对。真实环境闭环、部署切换和容量验收保持后置，不扩展认证/封禁产品功能。

### 收敛后核对：热准备隔离与授权的实际数据库边界

内存策略模式下，Owner 准备的 sync 准入改为按实际物理连接池配置身份共享；不同物理库分别推进，同库 schema/别名不获得额外预算。控制侧冷快照登记单独使用一个有界准入器，只有实际冷加载回调申请；热快照发送不再因其他房间的控制登记排队而占用该入口。旧授权模式保留原准备入口。压力指标分别汇总物理库准备与冷策略登记，不把不同库的独立调度合为一份额度。

网关 target 构建通过，/tmp/imv2-preparation-isolation-tests.log 的 12 项、四个 suite 通过，包括生产私聊/群聊工厂、授权运行时、独立准备、房间对恢复和指标。工厂验证在全部冷登记额度被占用时，已缓存的转发及群聊发送仍完成；群聊验证同时隐藏六张策略事实表。这些证据只证明已启用模式的相关热路径，不证明默认发送入口或容量目标。

源码审计确认三个不能忽略的边界：

1. GatewayPolicyAssembly 仍依赖显式 policyPlacement，缺少配置时不会装配内存授权服务。因此“默认入口已经使用内存授权”尚未完成。
2. 已启用模式的热消息不读账号/关系/设置事实表，但仍在 Owner 事务中查询 room_policy_authorization_leases 并持有 SHARE 到结算。“每次消息授权完全不访问数据库”尚未完成；不能把事实表缓存测试作为这项证明。
3. 策略修改仍使用持久版本、快照撤销和实际执行排空协议。其目的包括跨节点及进程失效后的权限合同；当前不能直接删掉租约查询并宣称权限语义保持。若按本地范围简化，需要把本地状态所有权、修改确认与已在途发送的顺序单独实现并验证，不能扩展为新认证或封禁产品。

当前继续实施的是消息主线，生产部署切换和容量验收仍后置。以上缺口保留为未完成项，不以现有局部绿色测试重新定义完成条件。

本机策略事实读取改为直接使用策略修改所用的同一 PostgresV2PolicyOwnerDirectory：按其 ownsScope 判断本地归属，全本地请求无需 Cluster client 或自调用 RPC；混合请求仅将外部 scope 交给原认证路由。本地分支保持原 owner 身份、版本、事实与过期约束，不创建第二份事实缓存，也未删除持久授权围栏。

真实 PostgreSQL/TCP 验证覆盖全本地请求（clientProvider 和 resolve 被调用即抛错）以及混合请求（本地 scope 被远程 resolve 即抛错）；六张事实表隐藏后两分支均返回与原远程路径相同的 owner 状态。物理准入隔离测试新增 sync 参数，验证 A 的准备额度耗尽且后继排队时 B 仍获准，归还 B 不推进 A，全部额度最终归还。/tmp/imv2-local-policy-routing-tests.log 两项、两个 suite 通过（物理隔离包含 write/sync 两参数），编译通过；独立测试数据库已关闭。本轮相关已跟踪文件 diff 检查通过，工作树另有既存 V2DeviceConnectionRegistryReentrancyTests.swift 的文件末尾空行，不修改无关文件。

### 本地压测入口实际选择新授权路径

run_v2_actor_realtime_benchmark.py 此前生成 Actor 配置时没有传入 policy-partitions，候选版本会继续使用旧授权。现在候选版本默认选择 memory 模式，生成 16 个分区的同一份策略归属配置供六个 Gateway 和 Account 使用；显式 --candidate-authorization-mode legacy 可复现旧路径。baseline.json 删除策略配置及 policy/realtime 新权限，继续使用冻结基线协议；签名身份及基础连接配置不重新生成。通用配置生成器和生产服务默认配置不在本轮改动中切换。

运行证据记录 baseline/candidate 的授权模式。监听就绪后、负载开始前，memory 候选通过原有有界只读查询核对 policy_owner_deployment 的 active 行与本次生成配置的 revision=1，写入 authorization-mode.json；缺少登记或版本不同则停止，避免只凭配置文件声称运行了新模式。此证据验证启动登记，不能替代发送热路径 SQL 或策略修改的验证。

/tmp/imv2-memory-policy-benchmark-config-tests.log 八项测试通过；新增测试实际调用配置生成器并产生七节点 TLS/签名配置，核对默认 memory、显式 legacy、基线兼容、分区覆盖以及节点间配置一致。/tmp/imv2-memory-policy-mode-db-proof.log 使用新建 disposable 数据库及 schema.sql 中真实 deployment 表定义，验证空登记拒绝、active revision=1 通过、revision=2 拒绝，随后删除本轮数据库并关闭测试 PostgreSQL。相关 Python 文件与文档 diff 检查通过。未启动完整压测服务或执行容量验收，默认生产入口与逐消息租约查询仍是此前记录的未完成项。

### 批量 Owner 围栏与授权租约合为一次 SQL 往返

原批量 Owner 路径先执行 operation/room/activation 围栏 SQL，再执行独立授权租约 SQL。现在先在内存验证精确 command 与执行许可，随后由事务绑定的 V2ConfiguredRoomFenceContext 在同一条 SQL 中依次完成 operation advisory 锁、room NO KEY UPDATE、activation UPDATE、policy lease SHARE。各 MATERIALIZED 阶段通过 count 依赖前阶段全部锁取得，最终采样一次 clock_timestamp；租约仍持有到实际 COMMIT/ROLLBACK，不删持久围栏、不改变策略事实来源。

批量 SQL 返回精确租约身份、撤销状态及时间供原身份检查使用。只在第一条房间结果返回一次租约集合，避免随房间数重复序列化整个集合。初版浮点 Unix 秒编码在测试中出现相邻微秒舍入而误报 identityConflict，已改为 PostgreSQL 2000 纪元的整数微秒，复用与 postgres-nio Date 编码一致的精确身份比较；过期也直接按整数微秒比较。

新增真实 PostgreSQL 行锁测试：依 registration_id 锁住最后一个 holder，证明合并 SQL 实际等待；用数据库时钟确认前面已取得锁的 holder 或最后仍等待的 holder 在等待中到期，再释放锁，两参数均拒绝。测试使用 0.5 秒过期窗口，保留真实锁等待及数据库时间证据，避免 2 秒边界与既有 SQL 超时竞争。/tmp/imv2-combined-policy-fence-integer-tests.log 11 项、两个 suite 通过，包含新合并围栏两参数、激活等锁过期两参数、生产私聊/群聊工厂、消息授权运行时及完整授权 journal。相关 diff 检查通过，独立 PostgreSQL 已关闭。

此改动只减少批量 Owner 路径的一次独立 SQL 往返；标量/转发路径仍保留原检查，授权租约表仍被访问，不能称为完全纯内存授权或吞吐达标。生产默认入口切换、完整本地负载验证及原方案其他未证实项继续保留，真实环境闭环仍后置。

### 最新 Release 的本地 TCP 运行仍失败

重建最新 Gateway Release（/tmp/imv2-memory-policy-release-build.log，227.58 秒）与 Account Release（/tmp/imv2-memory-policy-account-release-build.log，13.19 秒），核对冻结 Loader 算法哈希、协议 47 及完整夹具哈希后执行本地候选版本测试。原冻结对照目录已缺少源码/二进制，runner 现允许 --kind candidate 不提供旧对照产物，使用当前 .env.example 的默认值并记录其哈希；baseline/both 仍要求明确提供完整对照。候选单测报告的 baseline 二进制哈希和 revision 留空，不借用其他产物冒充对照。脚本回归 /tmp/imv2-candidate-only-benchmark-tests.log 九项通过。

运行目录 /tmp/imv2-memory-policy-10k1000-20261006-r1，入口日志同名 .log。六个实际 Gateway 与 Account 的 memory 模式成功启动，authorization-mode.json 核对 active deployment revision=1；独立 PostgreSQL 24532，沿用每 Gateway 写 5、读 3、Sync 3、连接池 11 的既有配置，未增加连接预算或放宽客户端质量门槛。10,000 个 TCP 连接全部建立，12 个 Loader 预热完成，共同 barrier 已释放。

夹具包含两个维度：/tmp/imv2-10k1000-current-fixture-20261005/manifest.json 的 topology=direct-ring、rooms=10000 表示预置全部房间；foregroundTopology=paired-adjacent、activeForegroundRooms=5000、foregroundSubscribersPerRoom=2 表示本轮前景发送与订阅的两两配对。上一轮只检查总拓扑就认定“不是配对”的判断不完整，已纠正。逐项读取 12 个报告的 activeForeground 游标并与各分片冻结凭据的第一目标进行 UUID 大小写规范化比较，实际前景为 5,000 房间、每房间两条连接，10,000/10,000 都匹配第一目标。Loader 命令虽保留两个目标，但 availability_hint 模式下订阅第一目标并发送到 activeRoomLogRoomID；不能用全部 Actor 缓存房间数代替前景发送房间数。

本轮 qualityPassed=false：12/12 报告，发送 19,801，ACK 9,600；SERVER_BUSY 8,195，关闭时未知结果 9,765。计划 60 秒的共同发送窗口仅完成 20.007 秒；Loader 0 的 terminalError 是 workload failure guard triggered: 31/1682，其他 Loader 也以失败退出。单 Loader 0 accepted 延迟 p50=5,052 ms、p95=10,000 ms。10,000 个 foreground viewer 中 1,359 个落后持久 head。窗口提前停止，不能使用约 480 ACK/s 当作完整 60 秒稳定吞吐证明。

最终采样中，节点 0 准备队列 327、准备工作 5、冷策略工作 5。六节点 Owner 阶段合并计数的事务正文均值约 12.38 ms，连接获取 0.49 ms、设置 1.28 ms、COMMIT 0.83 ms；这些均值覆盖已完成阶段、相互嵌套，不能相加当作客户端延迟，也不能直接与旧轮次计算改进百分比。准备阶段有明显积压，但缺少冷登记内部阶段耗时，尚不能证明具体冷 SQL 或 RPC 是唯一原因。仍需拆解冷状态加载/快照登记及准备资源占用。

实际进程已全部结算，forcedKillCount=0；exitFailureCount=13，因此不记为服务正常退出通过。runner 已关闭独立 PostgreSQL，postmaster.pid 不存在；数据库与报告保留在运行目录供复查。当前目标仍未完成，不能把已有单元/集成测试绿色视为本地目标负载通过。

### 冷快照登记合并依赖 SQL 与第二轮 TCP 结果

registerSnapshot 原来按依赖逐个 UPDATE 锁查询、独立采样数据库时间，再逐个插入 holder。现在一次按 scope_key COLLATE C 加锁查询，通过 MATERIALIZED/count 完成全部锁后采样时间；一次 INSERT SELECT 写入全部依赖，继续使用已锁住的 revision/owner_epoch，无冲突覆盖。四依赖的新登记减少七次 SQL 往返；原同一事务内的身份、pending seal、版本、期限和重放检查保留。

新增真实行锁测试分别让先锁住的 scope owner 和最后仍等待锁的 owner 过期，pg_blocking_pids 证明登记实际等待，数据库时钟证明过期，释放后返回 ownerChanged 且 holder 数为零。/tmp/imv2-set-policy-registration-final-tests.log 十四项、四个 suite 通过，包括两种新等待场景、完整 journal、私聊/账号快照、生产工厂和消息授权运行时。重建 Gateway Release 197.25 秒、Account Release 9.68 秒后复测相同夹具、场景、预算与客户端门槛，未更改失败标准。

运行目录 /tmp/imv2-memory-policy-10k1000-20261006-r2，入口日志同名 .log。实际 10,000 在线、12/12 报告；发送 19,782、ACK 9,632，SERVER_BUSY 7,983，关闭时未知结果 9,728，共同窗口仅 20.002 秒，qualityPassed=false。Loader 0 因 workload failure guard triggered: 28/1679 提前退出；accepted p50=4,522 ms、p95=10,000 ms。1,407 个 foreground viewer 落后提交 head。SQL 合并没有使整体结果达标，不能据此计算稳定吞吐提升。全部服务已结算，forcedKillCount=0、exitFailureCount=12；独立 PostgreSQL 已关闭。

复查本轮保留数据库的真实执行计划发现：jsonb_array_elements_text 的默认估计是 100 行，合并的 scope 加锁查询选择 Hash Join + 策略表 Seq Scan（估计 12,984 行、总代价 387.86）。明确最多四个输入后，计划改为四次主键 Index Scan 的 Nested Loop（总代价 33.94）。这些是计划估计，不是耗时或吞吐。已在集合加锁和 INSERT SELECT 的 JSON 输入加入经参数验证的实际依赖数 LIMIT，避免用默认估计放大输入；最多四依赖及唯一性检查保证没有截掉有效依赖。该修正尚未进入第二轮二进制，不能拿第二轮结果支持它的性能效果。

输入上限修正后，/tmp/imv2-bounded-policy-registration-tests.log 十四项、四个 suite 全部通过，包含新登记的全部锁后过期测试、journal/快照重放与撤销、生产工厂和消息运行时。相关 diff 检查通过；执行计划复查时临时恢复的第二轮 PostgreSQL 及回归用 PostgreSQL 均已关闭。本轮减少 SQL 与计划修正有源码、集成测试和真实计划依据，但尚未重建/执行第三轮负载验证，整体目标继续保持未完成。


### 范围校正：授权等待与物理数据库准入分离

用户指出工作偏离，并明确暂不考虑真实环境闭环。后续围绕内存授权、策略变更失效和跨房间资源干扰推进，不再把 SQL 合并或重复容量压测当成架构落地的替代证明。

当前发现 memory 模式的 PreparationCollector 将 sendPreparationAdmission 持有至完整 prepareOwnerBatches 返回，覆盖策略 Owner RPC、快照登记和房间租约安装；其任务上限同时沿用 Owner 写并发。这会让少数冷房间在不使用 Owner 连接时仍占据全部准备名额。

memory 模式现改为：预算/回执预读单独借用并归还原物理数据库准备准入；后续授权等待不持有该准入。Collector 的逻辑准备任务上限独立设置为 128，并取原 maximumPendingRequests 的较小值；原命令/字节限制、单房间 FIFO 与占用、实际任务结算后释放和 shutdown 排空均保留。数据库连接及写并发额度没有增加。冷策略仍受自己的原有准入与注册目录创建上限限制，不能据此宣称任意冷负载下都无排队，也不能宣称发送事务完全不访问数据库。旧授权模式继续使用原配置。

新增真实 PostgreSQL 边界测试：先完成 Owner 预算/回执 SQL，再阻塞一个房间的注册目录创建，观察唯一 sync 名额已归还，另一房间可独立完成自己的准备失败结果。原独立完成测试同时改成物理写并发为 1、逻辑准备任务为 2，证明两种资源不再混用。完整成功授权由现有生产私聊/群聊工厂测试覆盖。首轮 /tmp/imv2-preparation-boundary-tests.log 五项、两个 suite 通过；其失败结果隔离测试不替代完整发送或容量验收。

随后 /tmp/imv2-preparation-boundary-regression-tests.log 二十九项、三个 suite 全部通过，覆盖 Owner 幂等/回滚隔离、真实同 shard 多房间并发、物理名额归还、取消/排空、准备隔离及生产私聊/群聊授权工厂。独立测试 PostgreSQL 已关闭。当前尚未完成整体方案验收，新的逻辑任务上限未做目标容量验证；下一步仍需验证策略变更失效与完整热路径，而非把这一项资源边界修复视为全部完成。


### 策略修改返回后的完整热房间验证

新增 PostgresV2RoomWriteStoreIntegrationTests+PolicyWarmMutation.swift，参数分别为 block、remove、stranger、disable。使用真实控制库和独立房间库、生产 V2RoomServerActivationFactory、真实 activation 和发送事务；先让共享发送者的两个不同私聊房间成功提交消息，再经现有 social/preference/operator 服务修改其中一个接收者或关系的策略。好友移除场景先设接收者拒收陌生人，同时确保该新依赖已在其 Owner 内存中，避免把允许的首次冷加载误当作热路径要求。

修改成功返回后，同时隐藏两个库中的 public_user_profiles、special_accounts、account_disables、user_blocks、user_relationships、user_stranger_message_preferences。受影响房间随后以 directPolicyDenied 持久拒绝新 operation，消息总数仍为 1；未受影响房间提交第二条消息，总数为 2。由此证明这四种已测试修改后的房间授权重建能使用负责对应 scope 的更新内存事实，且未依赖上述六张事实表重新查询。版本、回执、持久授权和房间围栏表保持可用；这不宣称整个消息事务零 SQL，也不证明缓存过期/淘汰时无需冷加载。

当前源码归属核对：GatewayPolicyAssembly 构造单份 PostgresV2PolicyOwnerDirectory；本地 scope 读取、远端 ownership RPC 和 mutation RPC 共用这份目录。AccountServer 在 policyPlacement 模式下给关系和陌生人设置 store 注入 policyMutationExecutor；OperatorServer 给封禁服务注入同一协议的远端 executor。PolicyOwner 在变更开始时清除旧 state，撤销相关房间并等待实际执行结算，提交领域事实/版本/回执/outbox，再加载新版本事实并发布到内存；刷新失败会保持无缓存，后续不能使用旧 state。这里验证的是已有实现和连接关系，没有新增账号登录或生产切换工作。

/tmp/imv2-policy-mutation-memory-regression-tests.log 五项、一个 suite 通过，包含新测试四个场景、领域修改四个场景、内存状态刷新、好友依赖隔离以及迟到冷加载与撤销竞态。独立测试 PostgreSQL 已关闭。新的资源边界修复与策略变更正确性已有局部证据，整体 10,000 在线 / 1000 msg/s 验收仍未完成，目标保持进行中。


### 准备资源分离后的第三轮本地 TCP 验证

以当前源码重建 Gateway Release（/tmp/imv2-preparation-boundary-release-build.log，198.89 秒）与 Account Release（/tmp/imv2-preparation-boundary-account-release-build.log，11.22 秒）。运行目录 /tmp/imv2-memory-policy-10k1000-20261006-r3，入口日志同名 .log；仍用原夹具、原场景、六 Gateway / 十二 Loader、5 写 / 3 读 / 3 同步预算和原失败门槛。authorization-mode.json 确認 memoryDeploymentChecked=true、activeDeployments=1、revision=1；12/12 ready 后进入统一窗口，authenticated/peakActive 均为 10,000。

实际发送 19,927、ACK 11,765；SERVER_BUSY 4,307、DEFERRED_admissionUnavailable 794、关闭时未知结果 7,987，另有 SERVER_REJECTED_UNAVAILABLE 2。共同窗口 20.005 秒，qualityPassed=false；Loader 0 因 workload failure guard triggered: 16/1694 提前结束，该分区终端重试耗尽 16、关闭未知结果 655；其 accepted 延迟 p50=2,886 ms、p95=8,384 ms、p99=10,000 ms，最大 15,319.87 ms。这是一个 Loader 的分位值，不能当作合并全局分位值。全体检查的 10,000 foreground viewers 中 1,226 落后提交 head，无 missing/ahead。

首次观察到准备任务数到达 128 的采样中，六节点 sendPreparation（预算/回执 SQL）inFlight 仅 0 或 1、queued=0；policyPreparation 六节点均为 5 个进行中，等待数分别 123/100/123/122/122/99。该采样说明 Owner 预读名额不再被冷授权等待占住，积压仍存在于冷策略加载/登记阶段。不能据此把整个失败归因于某条 SQL，或把提高逻辑任务数当成最终解决方案；需要分别记录状态获取 RPC/内存读取和快照登记 SQL 的耗时。

cleanup settled=true、forcedKillCount=0、exitFailureCount=13；runner 已实际终结（exit 1），独立 PostgreSQL postmaster.pid 不存在，使用的数据库、Gateway、Actor、metrics、NATS、Account 和 HTTPS 端口均已关闭。ACK 总数比前两轮增加，但窗口仍提前结束，不支持稳定吞吐或容量达标结论。整体目标继续未完成。


### 冷授权阶段计时接入

沿用 V2SendOperationBatchMetrics 增加三个固定 stage：preparation_owner_read（memory 模式预算和回执预读，开始于取得 Owner 预读准入之后）、policy_owner_state（一次冷快照所需全部 scope 状态的获取，包含本地读取/冷加载及远端 RPC）、policy_snapshot_registration（状态取得后持久登记事务，包含其事务结算）。后两项开始于取得 cold preparation 准入之后，排队仍由已有 policyPreparation 指标观测；登记计时不包含随后房间租约安装，也不是一条 SQL 的耗时。

GatewayPolicyAssembly 向本地/远端策略服务传入原物理 Owner 的 sendOperationMetrics，沿用其聚合与 Prometheus 导出；四种构造入口提供默认 nil 参数，未选择 memory 模式的旧链路不改语义。计时由实际等待流程持有并在返回/抛错后结束，不引入用户、房间、operation 或任意动态 label。热 room snapshot 命中不调用冷 loader，不制造后两项样本。各 stage 的均值仍不能相加当作客户端延迟。

真实工厂验证冷样本：两个私聊房间首次发送各记录一次 owner 状态获取和登记；四种策略修改中的每一种随后仅受影响房间新增一次，另一个热房间不新增，因此各冷 stage count=3、inFlight=0；四次普通发送 preflight count=4。已有群聊/私聊发送与转发工厂场景分别为两次冷加载，热发送/热转发不制造额外冷样本。/tmp/imv2-policy-cold-stage-tests.log 六项、两个 suite 通过。旧指标测试将 SQL continuation 种类数量写死为 8，现改为核对 V2RoomSQLContinuationSource.allCases 的完整 key 集合，继续验证聚合和各 pending/结束转移。独立测试 PostgreSQL 已关闭。Release 与下一轮实际负载计时仍待完成，不能用本地工厂时序测试推断 10,000 负载的耗时分布。


### 第四轮：定位冷状态获取耗时

Gateway Release 构建 /tmp/imv2-policy-cold-stage-release-build.log 213.08 秒，Account Release /tmp/imv2-policy-cold-stage-account-release-build.log 9.60 秒。运行目录 /tmp/imv2-memory-policy-10k1000-20261006-r4，原夹具、场景、预算与失败门槛保持；memory active v1 证明、12/12 ready、10,000 authenticated/peakActive 和六节点新 stage 实际导出均已核对。

本轮发送 19,933、ACK 11,044；SERVER_BUSY 4,829、DEFERRED_admissionUnavailable 785、关闭未知结果 8,677。统一窗口 20.008 秒，qualityPassed=false。Loader 0 触发 workload failure guard triggered: 22/1695，重试耗尽 22、关闭未知结果 748；该分区 accepted p50=2,901 ms、p95=8,381 ms、p99=10,000 ms、最大 15,827.85 ms；这些不是全局合并分位值。10,000 foreground viewers 中 1,193 落后提交 head。

最新六节点完整指标采样的数值分析保存 candidate/diagnostic-cold-stages.json，只包含固定 stage、节点编号和数值。completed 样本按节点累计总耗时/总次数加权：preparation_owner_read 8,166 次、均值 7.61 ms；policy_owner_state 3,184 次、均值 145.45 ms；policy_snapshot_registration 3,179 次、均值 28.21 ms。采样时三段尚在途分别 3/25/5；数据覆盖已完成返回（含抛错），不是所有请求的最终延迟分布，不能直接相加当作客户端延迟，也不能把 owner_state 均值全归为 SQL 或 RPC。不同 stage 次数不相等：热命中不进入冷 loader，失败可能在登记前结束。

源码进一步核对：PolicyOwner.loadState 冷初始化或 lease 过期时，先 journal.acquireOwner（事务取得/续租 scope），再 journal.readOwnerState（第二个事务再次 scope 加锁、校验 owner/revision/pending 并读事实）。内存有效命中没有这两次事务。实测现在把 owner 状态获取定位为冷 loader 中较重的阶段，后续可审查将所有权取得与完整事实初始化合成同一原子事务，继续保留 pending seal、epoch、版本、事实锁和实际任务结算；不能仅扩大冷并发或删除持久授权合同。

本轮 runner 已终结 exit 1；service-cleanup settled=true、forcedKillCount=0、exitFailureCount=12，独立 PostgreSQL postmaster.pid 不存在，使用的七个服务端口均已关闭。整体性能验收仍未通过，目标继续进行中。


### 冷 Owner 状态原子初始化

根据第四轮 owner_state 端到端耗时证据，新增 journal.acquireOwnerState：在一个事务中沿用原 acquireOwner 的 INSERT / scope UPDATE lock / 数据库时间 / epoch 检查与 owner 续租，再检查 pending_change_key、读取该 scope 完整事实。Scope 锁覆盖事实读取和 COMMIT；成功后才向 PolicyOwner 返回状态。原 acquireOwner 公共入口抽取并复用同一事务内 helper，非状态 claim 和变更执行的行为保留。PolicyOwner.loadState（冷初始化、过期刷新及变更成功后的内存刷新）改用原子入口；有效内存命中仍直接返回。相比此前 acquireOwner + readOwnerState，两次事务改为一次，省去一次重复 scope 查询，不删事实锁和持久版本/epoch。

事实读取后再采样数据库时钟和保守单调 deadline，防止事实行锁等待期间 owner 过期后仍返回过期状态。读取失败、pending seal 或到期均回滚整次初始化，包含未提交的所有权/epoch/续租变化。

新增真实 PostgreSQL 验证：隐藏事实表使读取失败，旧的已过期 owner/epoch 保持，恢复表后新 owner 仅取得一次 epoch；活跃外部 owner 拒绝；pending change 在事实表不可读时仍先返回 busy。另一测试实际锁住 profile 行并通过 pg_blocking_pids 证明冷读取被阻塞，用数据库时钟等待超过 0.5 秒 lease，释放后初始化拒绝，之前的 30 秒 lease 因失败续租回滚而仍可读取。/tmp/imv2-atomic-policy-state-tests.log 十七项、三个 suite 通过，覆盖新测试、journal/Owner 恢复、状态共用和取消排空、生产私聊/群聊工厂及四种策略修改后的热房间行为。独立测试 PostgreSQL 已关闭。Release 构建和相同负载的实际性能效果尚待本轮完成。


### 第五轮：原子初始化的实际结果

Gateway Release /tmp/imv2-atomic-policy-state-release-build.log 194.61 秒，Account Release /tmp/imv2-atomic-policy-state-account-release-build.log 9.79 秒。运行目录 /tmp/imv2-memory-policy-10k1000-20261006-r5。原夹具、场景、资源预算、失败门槛保持；memory active v1、12/12 ready/report、10,000 authenticated/peakActive 均已核对。

实际发送 19,949、ACK 12,162；SERVER_BUSY 4,108、DEFERRED_admissionUnavailable 711、关闭未知结果 7,627。共同窗口 20.007 秒，qualityPassed=false。Loader 0 因 workload failure guard triggered: 14/1697 提前结束，重试耗尽 14、关闭未知结果 658；该分区 accepted p50=3,011 ms、p95=8,359 ms、p99=10,000 ms、最大 14,181.18 ms，不能当作全局合并分位值。10,000 foreground viewers 中 1,291 落后提交 head，无 missing/ahead。

最新六节点完整指标的分析保存 candidate/diagnostic-cold-stages.json。completed 预读 8,863 次、加权均值 8.79 ms；状态获取 3,387 次、123.28 ms；快照登记 3,381 次、41.48 ms。三段在途分别 4/24/6。第四轮对应状态获取为 145.45 ms、登记 28.21 ms：本轮状态获取下降，登记增加，不能把一个 stage 的变化等同于端到端收益，也不能用这一个提前结束的样本认定稳定吞吐已提升或资源容量达标。

源码仍存在一个状态获取的串行点：PolicyOwnerDirectory.registrationStates 对最多四个独立 scope 按顺序逐一调用各自 Owner。它与同一 scope 内的写入顺序是不同职责；后续应审查是否能有界并行读取独立 scope、保持完整结果的规范顺序与组内取消/实际 SQL 结算责任，而不增加物理数据库额度。当前还不能把所有 123.28 ms 归因于这一个点，跨节点 RPC 与共享数据库等待同样包含在该 stage。

runner 已终结 exit 1；cleanup settled=true、forcedKillCount=0、exitFailureCount=12，独立 PostgreSQL postmaster.pid 不存在，使用的七个服务端口全部关闭。原子初始化的正确性与局部耗时已有证据，整体方案与 60 秒性能验收仍未完成，目标保持进行中。


### 独立 scope 状态有界并行读取

PolicyOwnerDirectory.registrationStates 原先按规范顺序逐一等待不同 Owner。现在校验全部输入和归属后，在一次原有目录 root 中使用 structured task group 并行读取独立 scope，每组最多四个，实际宽度取 scope 数量与 maximumOwners 的较小值。相同 scope 仍通过原 Owner actor 共用冷加载、序列化变更与恢复；不增加数据库连接、物理额度、目录 roots 或缓存上限。组结果按原规范 scope 顺序返回，不把完成顺序泄漏为接口顺序。出错/取消时加入所有实际子工作后才释放目录 root；一个条目的缓存继续串行轮转并空闲淘汰，不能因并行而拒绝此前可完成的多 scope 读取。

新增真实 PostgreSQL 测试（cancel=false/true）：锁住规范顺序中第一个账号的 profile 行，pg_blocking_pids 证明该读取确实等待；在释放行锁前，第二个账号的 scope owner 已提交，证明后一个初始化没有等待前一个。整个批次仍只有一个目录 root。调用方取消后，shutdown 标为 closed 但 root 继续保留，直到解锁、全部结果按规范顺序返回，关闭后 roots=0。另一个测试使用 maximumOwners=1 / maximumRoots=1 读取四种完整 scope，返回四项且缓存始终只有一个条目。

/tmp/imv2-parallel-policy-state-regression-tests.log 九项、两个 suite 通过，包含新并发/小缓存测试、原目录容量与空闲淘汰、原子初始化回滚/过期、状态 coalescing 取消排空、四种策略修改后的热房间和生产私聊/群聊工厂。测试 PostgreSQL 已关闭，相关 diff 检查通过。Release 构建已启动，日志 /tmp/imv2-parallel-policy-state-release-build.log；下一轮同夹具同预算的容量效果仍未验证，整体目标未完成。


### 第六轮本地验证与范围纠偏

Gateway Release 构建 197.45 秒、Account Release 9.59 秒。运行目录 /tmp/imv2-memory-policy-10k1000-20261006-r6，沿用原夹具、场景、物理预算与失败门槛。10,000 authenticated/peakActive；发送 19,945、ACK 12,312，SERVER_BUSY 4,166、DEFERRED_admissionUnavailable 680、关闭未知结果 7,434。共同窗口 20.006 秒，qualityPassed=false。Loader 0 触发 failure guard 21/1693，报告 accepted p50=2,757 ms、p95=9,589 ms、p99=10,000 ms，最大 14,416.89 ms；该分区分位值不是全局分位值。

最新完整六节点累计采样：预读 8,758 次、加权均值 9.33 ms；状态获取 3,436 次、114.82 ms；快照登记 3,423 次、46.98 ms；对应在途 3/17/13。数值保存 candidate/diagnostic-cold-stages.json。局部状态获取均值下降没有转化为容量验收通过，不能据此宣称实现完成。runner 实际终结 exit 1；cleanup settled=true、forcedKillCount=0、exitFailureCount=12，独立 PostgreSQL postmaster.pid 不存在。

用户再次指出方向偏移。后续审查应回到授权内存状态的归属、策略修改更新边界，以及冷加载与慢房间是否占用其他房间的执行资源；真实环境闭环仍不展开。当前有效缓存命中使用内存，但冷初始化、到期刷新及策略变更后的状态刷新仍访问数据库。SQL 合并和独立 scope 并行只是已有实现的局部优化，不能代替这些架构边界的审查，也不能代替原 60 秒容量验证。


### 内存策略事实与 Owner 租约生命周期分离

纠偏后的本次修改针对内存事实生命周期：此前 PolicyOwner.registrationState 在 lease 到期后重新读取完整账号/关系/陌生人设置事实，即使策略版本未改变。现在向 journal.acquireOwnerState 提交其已有不可变缓存，在原 scope 行锁下比对续租前 owner ID、epoch、revision 和 scope，检查 pending change；完全匹配时保留事实并签发更新后的 lease/deadline。租约到期后的原 epoch 递增语义保留。策略版本变化、Owner 曾更替、同 Owner incarnation 改变或缓存缺失时仍完整冷加载；pending change 拒绝，不把续租当作解除变更封锁。缓存 generation 与真实 SQL root 结算语义保持。

真实 PostgreSQL 新测试：账号、关系对、陌生人设置分别加载后隐藏必需事实表，等待本地和数据库租约到期，运行实际 Owner.registrationState 成功续租并保持事实、版本，epoch 增一。另四个场景验证 pending seal 优先拒绝，以及 revision / epoch / takeover 变化不能使用旧缓存；隐藏事实表使必要冷读失败，恢复后成功，revision 场景读取到 suspended 的新账号事实。

第一轮新增测试的 revision 场景使用了 schema 不允许的 inactive 状态，属于测试数据错误，改为 suspended 后重跑。/tmp/imv2-memory-fact-renewal-tests-r2.log 九项、两个 suite 通过，含新两项参数化测试、原子加载回滚/到期、内存更新、四种真实策略修改的房间隔离以及 Owner 取消/恢复/永久结果重放。/tmp/imv2-memory-fact-renewal-settlement-tests.log 一项通过，验证 coalesced 状态加载取消与 shutdown 真实结算。相关 diff 检查通过，独立测试 PostgreSQL 已停止。

此次没有重跑容量测试：消除未变策略在 lease 到期后的事实重复查询，不能证明冷启动的 20 秒提前失败已解决。策略变更后仍通过完整状态加载更新内存，更新边界与冷任务对其他房间的资源影响仍需继续处理；完整方案与 10,000 在线 / 1000 msg/s 验收保持未完成。


### 策略事务提交后直接发布新内存状态

生产 PolicyOwnerDirectory 给每个 scope Owner 注入 typed snapshot 回调，使用 journal 的 schema 和受信 mutation context，在领域修改事务内读取该 scope 的完整最终事实。journal.commitPolicyExecution 将事实与 next_revision、当前 owner/epoch、保守 monotonic deadline 一起随 transaction future 返回；只有实际 COMMIT 成功才能得到该 state。事实捕获失败与 COMMIT 失败均回滚领域事实、版本、回执和 outbox；不会发布未提交的事实。若租约已过期不返回可用 state，随后授权必须重新取得有效能力。

PolicyOwner.changeExecution 不再在成功后调用 loadState / acquireOwnerState 开第二个事务查询事实与续租；直接把提交结果 state 交给原 generation / jobs / recoveries / closed 检查后发布。策略恢复执行也逐项保留最新已提交 state，整组成功且 generation 有效后发布；部分恢复失败不发布最后一项状态。永久回执重放只返回 receipt，state=nil，不把历史版本当作当前事实。没有授权状态的通用 journal/Owner 调用保留原默认接口，按需冷读取仍可工作。

这次不是从 block=true 等单个请求参数推算整份缓存；关系 scope 包含双向拉黑与好友关系，账号 scope 包含特殊账号能力，必须捕获完整最终事实。事实查询保留在少量策略写入事务内，普通发送的热授权不查询这些事实表。启动、Owner 更替、缓存淘汰和版本不匹配仍需要冷读取；不能宣称整个发送链路或策略修改零 SQL。

真实 PostgreSQL 新测试 policyMutationCommittedMemoryPublication 两个参数场景：成功场景在 snapshot 回调读到 suspended 后、COMMIT 前将事实表重命名，使提交后任何再次读取都会失败；实际 Owner 随后直接返回新内存状态和 revision=2。失败场景由 DEFERRABLE INITIALLY DEFERRED constraint trigger 在实际 COMMIT 时抛错，确认账号仍 active、版本未推进、pending seal 保持、无 outbox，授权返回 busy；移除 trigger 后同 operation 恢复成功，再隐藏事实表验证新状态可用。

增强原生产恢复测试：领域写入因 outbox 失败回滚，替换 Owner 恢复后隐藏 user_blocks，registrationStates 仍从内存返回 blocked=true / revision=2。/tmp/imv2-committed-policy-memory-tests.log 十项、两个 suite 通过，覆盖新提交测试、真实四类策略修改、房间隔离、租约续用、状态取消结算及 Owner 取消/恢复/永久结果重放。/tmp/imv2-committed-policy-memory-recovery-tests.log 十项、两个 suite 通过，包含增强恢复、好友依赖隔离及完整 journal 围栏/撤销/时钟测试。相关 diff 检查通过，测试 PostgreSQL 已停止。

此处解决策略变更后的内存发布边界，未重跑容量负载，未证明冷授权积压已解决。不同房间的冷任务与执行资源隔离，以及原 10,000 在线 / 1000 msg/s 完整验收继续未完成，整体目标保持进行中。


### 冷授权远端等待与控制库 SQL 准入分离

源码审查发现 V2RoomPolicyAuthorizationService 的两类构造、私聊与群聊 loader 都在整个状态获取（含远端 RPC）和登记阶段持有 controlPreparationAdmission。现在先取得状态，只有随后 register 事务才取得控制 SQL 准入。PostgresV2PolicyAuthorizationJournal 增加可选 stateReadAdmission，实际 acquireOwnerState 初始化/续租事务才获取这份许可；有效内存命中不进入 journal。GatewayPolicyAssembly 将原 policyPreparationAdmission 同一实例同时传给 journal 和登记 service，沿用原额度。由此远端请求在负责状态的节点执行真实 SQL 时受限，而发起节点等待远端结果不持有这份控制库许可。先完成状态 SQL 再申请登记，不嵌套持有。

新增 remotePolicyWaitDoesNotHoldDatabaseAdmission 实际房间准备/写入测试：共享只有一个 sync 许可的控制资源，先提交房间 A 以缓存授权，再让房间 B 的外部策略 clientProvider 挂起。等待期间实际 admission inFlight=0 / queued=0，同资源另一段 SQL 可运行，房间 A 第二条消息在 B 解除等待前已提交。该测试覆盖远端状态获取边界的挂起，不宣称测试了任意网络故障或完整容量。

增强 policyOwnerStateLoadSettlement：真实 scope 行锁阻塞状态 SQL，两位调用者共用一个实际 state load；许可 inFlight=1，调用方取消与 shutdown 时保持，实际 SQL 结束后 roots 与许可均归零。三个冷加载回滚/到期/结算场景单独重跑通过。原生产私聊/群聊工厂、多房间准备、四类策略修改房间隔离、lease 缓存复用和提交后状态发布也通过。

第一轮新测试的 #expect 宏内 try 推导引起编译错误，改为先执行 SQL 再断言，随后编译通过。组合 regression 中 RemotePolicyOwnershipTests 与 RoomWrite suite 都用会重建 im_v2 的 withForwardOwnerDatabases，跨 suite 并行导致两项 schema 互相干扰；分开执行后均通过。/tmp/imv2-policy-sql-boundary-tests-r2.log 七项一 suite；/tmp/imv2-policy-sql-boundary-settlement-tests-r2.log 三项一 suite；/tmp/imv2-policy-sql-boundary-remote-tests.log 一项真实 TCP suite；原目录容量测试两项在组合运行中通过。相关 diff 检查通过，测试 PostgreSQL 已停止。

Gateway Release 构建已启动，日志 /tmp/imv2-policy-sql-boundary-release-build.log。下一轮同原夹具、额度和失败门槛的容量验收仍待运行，不能以隔离测试通过代替 10,000 在线 / 1000 msg/s 的完整结果。整体目标保持进行中。


### 第七轮：控制 SQL 准入分离后的容量回归失败

Gateway Release 194.20 秒、Account Release 9.62 秒，运行目录 /tmp/imv2-memory-policy-10k1000-20261006-r7，原场景、夹具、额度和失败门槛。memoryDeploymentChecked=true、activeDeployments=1、revision=1；12/12 ready、统一 barrier 已建立，但失败后只有八份完整报告。因此最终 result 的 authenticated/peakActive=6,668 是已收集报告的合计，不能宣称本轮只有 6,668 个初始连接，也不能将报告缺失包装为完整 10,000 在线容量结果。

结果发送 6,564、ACK 963，SERVER_BUSY 1,413、SERVER_REJECTED_UNAVAILABLE 3,103、关闭未知 5,588、UNRESOLVED 1,482，另 OUTCOME_UNKNOWN 2；共同窗口 0、qualityPassed=false。Loader 0 failure guard=1/834，报告 accepted p50=485 ms、p95=4,152 ms、p99=6,085 ms、最大 6,103.76 ms；不是全局分位值。提前终止使本轮与此前约 20 秒窗口的累计 ACK 不可直接比较，更不能当作性能提升。

最新完整六节点阶段采样：预读 6,790 次、加权均值 30.87 ms；状态获取 6,041 次、171.03 ms；登记 513 次、47.93 ms；在途分别 30/123/0。六节点 policyPreparation 实际 SQL 准入均 inFlight=5、queued=68/70/70/74/69/66，准入 queue_full 与 timeout 计数均为零。大量 owner_state 完成但登记次数很少，说明不能只看该阶段均值；返回包含错误，需要进一步区分失败种类。准入队列长度与配置/Owner roots 共同表明接收侧冷状态工作有明显积压；现有证据尚不足把全部 UNAVAILABLE 归因于某一个限制或 SQL。

此次资源迁移修复了远端等待持有 SQL 许可的问题，但原外层名额还隐含限制冷请求进入速率；移除其逻辑限制后，接收侧冷状态与登记共用 SQL 预算形成新积压。后续应将有界冷请求调度与实际 SQL 许可明确分开，并用错误分类/排队证据验证，不能恢复远端等待持有 SQL 许可，也不能盲目扩大连接或 Owner roots。普通热房间的独立推进测试仍通过，但它不能替代冷启动容量验证。

runner 实际终结 exit 1，failureStage=workload / failureCode=run_failed；cleanup settled=true、forcedKillCount=0、exitFailureCount=12。独立 PostgreSQL postmaster.pid 不存在，使用的七个服务端口均已确认关闭。整体方案与容量验收仍未完成，目标保持进行中。


### 冷状态请求调度与实际 SQL 许可分别计账

新增 V2PolicyStateRequestScheduler，按节点共用、仅约束冷状态请求的有界在途与 FIFO 等待。内部复用原控制器已验证的排队/取消/deadline 实现，但不暴露数据库许可；perform 的生命周期覆盖实际状态获取 future，排队取消只移除等待，已开始工作直到实际返回才释放逻辑名额。所有私聊/群聊、本地/远端 loader 的状态获取阶段使用此调度，登记之前释放逻辑名额；只有 cache miss 的 loader 才进入，热房间授权不进入该队列。

GatewayRoomOwnerAssembly 用原 foregroundWriteDatabaseWorkLimit、foregroundWriteDatabaseWorkMaximumQueued 和原准入等待期限构造一份节点级 scheduler，GatewayPolicyAssembly 将它传给所有物理房间服务。未增加原数据库额度、Owner roots 或缓存容量。实际 acquireOwnerState 与 register 仍使用之前同一控制 SQL 准入实例；远端状态等待不持有 SQL 名额。本次恢复旧外层名额隐含的冷请求有界性，同时保留已修复的真实 SQL 边界。

指标增加固定 im_v2_policy_state_requests 前缀，单独导出逻辑冷请求 inFlight/queued/准入/拒绝/取消/排队耗时，im_v2_policy_preparation 标明为实际冷状态和登记 SQL 工作。Gateway runtime source 独立读取二者快照，不将逻辑请求数并入物理 SQL 并发。policy_owner_state 计时在取得逻辑名额后开始；该阶段均值不包含新的冷请求排队，排队由新指标观测，不能把这一口径变化误认为整体延迟下降。

新增调度测试验证 maxInFlight=1 / maxQueued=1 时第三项临时过载拒绝，排队取消不启动工作，已执行项取消后仍保留名额，实际完成后归零，过期 deadline 不启动工作。增强真实两房间测试：冷状态逻辑队列的一个在途和一个等待均占满，实际控制 SQL 名额为零，另一段 SQL 可运行，已缓存房间在远端解除前提交第二条消息。生产私聊/群聊工厂、多房间准备及状态加载真实 SQL 结算回归通过。

/tmp/imv2-cold-policy-scheduler-tests-r2.log 十项、三个 suite 通过；/tmp/imv2-cold-policy-scheduler-metrics-tests.log 一项通过，通过实际 /metrics 响应分别验证 physical policy preparation=1、logical state requests=2、logical queued=9。第一轮指标接线的大表达式触发 Swift 编译器无法诊断的类型推导错误，拆出显式 @Sendable async closure 后修复。相关 diff 检查已通过，测试 PostgreSQL 已停止。

Gateway Release 构建启动，日志 /tmp/imv2-cold-policy-scheduler-release-build.log；下一轮原 10,000 在线 / 1000 msg/s 场景仍待执行。不能仅以调度与隔离测试推断第七轮失败已解决，Owner 状态错误分类与完整容量证据仍需核对。整体目标保持进行中。


### 第八轮与冷策略物理连接池接线修复

Gateway Release 197.31 秒、Account Release 10.97 秒。第八轮目录 /tmp/imv2-memory-policy-10k1000-20261006-r8，同原夹具、场景、物理连接配置和失败门槛。memory active v1 检查、12/12 ready、共同 barrier 均通过，十二份报告齐全，authenticated/peakActive=10,000。发送 19,916、ACK 11,488；SERVER_BUSY 4,425、DEFERRED_admissionUnavailable 858、关闭未知 8,237。共同窗口 20.009 秒，qualityPassed=false。Loader 0 failure guard=12/1696、重试耗尽 12、关闭未知 659；该分区 accepted p50=3,043 ms、p95=8,885 ms、p99=10,000 ms、最大 14,667.12 ms，不是全局分位值。

最新完整六节点 stage 采样：预读 8,463 次、加权均值 8.47 ms；状态获取 3,252 次、169.01 ms；登记 3,239 次、26.61 ms；对应在途 2/30/4。logical cold state requests 各节点 inFlight=5，queued=122/117/117/122/123/121；实际控制 SQL inFlight=4/5/5/0/1/4，queued=0/10/19/0/0/0。第七轮的无逻辑节制回归没有重现，但 cold 请求积压和 60 秒容量失败仍存在，不能认定吞吐达标。诊断保存 candidate/diagnostic-cold-stages.json。

进一步核对真实物理池：GatewayPolicyAssembly 的 journal/dispatcher 和服务登记 database 都指向 topology.authorizationControlDatabase。GatewayDatabaseTopology 将该属性绑定于 direct_authorization_resolution 专用池，每 EventLoop 只有一条连接。本轮实际 /metrics 确认 event_loop_handles=1、该池 ceiling=1；既有 direct_send_control 池同样 handles=1、ceiling=11，shared ceiling=11、user_state_route ceiling=1。SQL 逻辑准入上限 5 并没有使恢复专用池变成五条连接，冷状态与登记实际受该单连接池约束。此为当前源码和运行指标确认的资源边界，不声称全部客户端延迟都由该池产生。

现将 memory policy journal/dispatcher 与服务登记数据库接到既有 directSendControlPool.database。作用域事实、版本、围栏与 receipt 都仍在同一个控制库 schema；SQL 准入实例、logical scheduler 与原上限不变。未新增池、连接或改变原池配置；legacy authorization resolution/recovery 使用原专用池。这是为新策略职责选择已有匹配的物理资源，不扩大物理容量。

/tmp/imv2-policy-control-pool-regression-tests.log 四项一个 suite 通过，覆盖真实两房间冷请求与 SQL 名额隔离、生产群聊/私聊工厂、领域回滚恢复及四类策略变更后的内存授权与房间隔离。相关 diff 检查通过，测试 PostgreSQL 已停止。Gateway Release 重建启动，日志 /tmp/imv2-policy-control-pool-release-build.log；实际收益需要第九轮同负载证明。

第八轮 runner 已实际終结 exit 1，cleanup settled=true、forcedKillCount=0、exitFailureCount=12；结果收集后 runner 曾继续进行数据库清理，已等到该确切 handle 终结并确认 postmaster.pid 不存在。服务端口与数据库端口最终关闭。整体方案与完整容量验收保持未完成。

### 纠偏：授权内存归属、修改发布与相关房间隔离

当前主线仍是内存授权的职责边界，不把连接池调整、调度测试或局部耗时下降当作方案完成。账号状态属于 account scope；双向拉黑和好友关系属于 canonical pair scope；陌生人设置属于接收方 stranger scope。同一 Gateway 的本地读取、远端状态端点及策略修改共用 PostgresV2PolicyOwnerDirectory。Account 的关系/偏好修改和 Operator 的封禁入口在 policyPlacement 模式下使用该策略修改协议。

正常房间发送复用已登记的授权快照及内存执行门；策略事实不逐条查询。修改先封锁相关 scope 的新授权并撤销相关 holder，等待实际执行结算后提交事实、版本和回执，并发布事务内捕获的最终内存事实。修改成功后的新发送须看到新策略；已经获准执行的发送先结算，随后修改才能返回成功。冷加载、授权登记、租约围栏及消息持久化仍有数据库工作，不能把事实缓存表述为整个消息链路零 SQL。

加强 warmRoomPolicyMutationIsolation 的四个真实 PostgreSQL 场景：在拉黑、解除好友、修改陌生人设置和封禁的 revocation 回调中设置可控制的等待点。该等待点位于相关 scope 封锁之后、修改提交之前；等待期间通过生产 activation factory 向另一间不受影响的私聊房间发送并确认 accepted。释放等待后修改成功，再隐藏两端全部六张策略事实表，确认受影响房间使用新内存策略拒绝发送，另一房间仍接受。检查消息实际落库数量，原有冷加载/登记次数不因额外热发送增加。失败清理先释放等待并加入实际修改任务，再关闭资源。

初次执行 /tmp/imv2-policy-mutation-inflight-isolation-tests.log 四个参数场景通过，3.914 秒。这证明相应热房间在策略修改等待中可独立推进，不证明冷房间集中加载下的公平性或整体容量。后续复核以最终源码的重跑日志为准。

最终源码重跑 /tmp/imv2-policy-mutation-inflight-isolation-tests-r2.log 四个参数场景全部通过，3.953 秒，进程 exit 0。等待点改用必要断言，未到达该点则终止场景，避免把没有真正挂起修改的发送误判为隔离证据。相关 diff 检查通过。

补记已有第九轮证据：/tmp/imv2-memory-policy-10k1000-20261006-r9 的十二个 ready 已完成，但最终只有八份报告，result 的 authenticated=6,666 为部分报告合计。发送 13,326、ACK 9,709、共同窗口 0、qualityPassed=false；不能作为完整容量结果。最新完整六节点状态阶段加权均值 111.94 ms、登记 21.25 ms、Owner 预读 29.51 ms；这些阶段不能相加或替代客户端延迟。原 10,000 在线 / 1000 msg/s 验收仍未通过。

状态请求的 lifecycle busy 已在本地冷加载边界和远端 ownership 服务明确映射为 notAccepted(overloaded)，实际 outcomeUnknown 保持不变。已有真实 TCP 容量占满测试及本地分类/取消测试通过，日志 /tmp/imv2-policy-busy-classification-tests-r2.log 与 /tmp/imv2-policy-busy-classification-regression-tests.log。该错误语义修复未重新构建 Release 或重跑容量，不能宣称解释了第九轮全部失败。

### 内存状态读取不占用目录 SQL 工作额度

核对发现 registrationStates 先进入目录 run，再调用 scope Owner 的内存读取。当别的 scope 实际 SQL 根占满 maximumRoots 时，仍有效的内存事实会先被 busy 拒绝。现增加 Owner.cachedRegistrationState：只读取当前有效且没有变更/恢复的 state，不启动或加入 SQL。目录验证 scope 归属后，先探测已有 Owner；全部命中直接返回，任何缺失/过期仍走原有界 run 和结构化加载流程。不创建 Owner、不扩大缓存或根额度。

每次缓存探测跨 actor 等待期间保留该条目的 uses，避免实际读取尚未返回即被淘汰。探测结束更新原 idle 顺序；shutdown 在 actor hop 中清空目录时容许条目已移除，并再次检查 closed，不返回关闭后的状态。授权登记仍检查 durable owner/epoch/revision/seal，缓存探测不是新的消息执行许可。Mutation/recovery 开始时的失效与提交后的发布规则保留。

真实 PostgreSQL 新测试 cachedStatesBypassBusyRoots：maximumRoots=1，预先加载 account 状态，然后真实 scope 行锁挂起另一个 account 的 claim。确认 pg_blocking_pids 非空且 roots=1，此时预加载状态成功返回相同 owner/facts/deadline，root 保持 1；未缓存第三个 scope 仍报 busy。释放后实际 SQL 结算、roots=0；关闭后的缓存读取报 closed。/tmp/imv2-policy-cache-root-isolation-tests.log 三项目录测试通过，1.274 秒，包含原缓存淘汰与取消结算回归。

增强真实 TCP ownership 测试：占满节点八个目录 SQL 根时，已缓存 scope 的 signed claim 成功返回；同节点未缓存 scope 返回 notAccepted(overloaded)。原完整事实、scope 归属、到期/错误事实拒绝和策略修改重放验证保留。/tmp/imv2-policy-cache-root-remote-tests-r2.log 一项通过，1.047 秒。初次测试编译因 #expect 的非 throwing autoclosure 中引用 throwing policyWire 失败，提取 expectedWarmScope 后修复。

该改动解除的是 Owner 目录额度对有效内存读取的阻塞。发起端 room 冷状态 scheduler 与 preparation collector 的排队边界尚待核对；不能据此宣称任意冷加载积压不会影响房间，也未重跑 Release 容量验收。

/tmp/imv2-policy-cache-root-regression-tests.log 六项、一个 suite 通过，13.647 秒，覆盖提交成功/实际 COMMIT 失败的内存发布、三类事实续租、pending/revision/epoch/takeover 围栏、单条目缓存的完整 scope 批次、取消/关闭等待真实 SQL 结算，以及四类策略修改期间不相关房间推进。所有测试进程实际 exit 0；相关 diff 检查通过，测试 PostgreSQL 已停止。

### 完整本地内存状态不进入冷请求等待队列

发起端此前在房间尚未安装快照时，无论策略事实是否已经由本机 Owner 持有，都先进入节点冷请求 scheduler。现在目录提供只探测现有有效事实的 cachedRegistrationStates；远端 facade 仅在全部 scope 按现有 placement 属于本机时调用此方法，否则返回 miss，不获取 cluster client、不解析远端路由，也不增加一份远端事实缓存。

私聊先探测双方账号和关系 scope，只有非好友才要求接收方陌生人设置也完整命中；好友不引入该额外依赖。群聊探测发送方账号 scope。四个本地/远端 service loader 均接入此缓存探测：完整命中直接取得状态，然后仍进入原受物理 SQL 准入约束的 durable registration；缺失、过期、正在修改或涉及远端 scope 时按原有界 scheduler 完整读取。开始探测前及返回命中后检查调用方取消和 deadline。没有通过 probe 创建/续租 Owner，也没有改队列、数据库额度或持久化许可语义。

policy_owner_state 的计时移动到这整个状态获取边界，包含缓存探测、冷请求排队与状态加载。完成次数仍为每次房间冷准备一次，而非每个 probe 或 scope 一次。此口径与第八/九轮排除 scheduler 排队的阶段均值不同，后续不能据此直接比较耗时变化；独立 logical/physical 资源指标保持。

增强真实数据库 remotePolicyWaitDoesNotHoldDatabaseAdmission：先建立策略事实缓存；挂起另一房间的远端 provider，并占满一个在途和一个等待的逻辑额度。已安装快照的房间仍可发送；额外新建一个没有任何房间快照的 service，共用原 scheduler、数据库及本机策略目录，此时成功首次登记并提交消息。确认冷请求 inFlight=1/queued=1 均未变化，远端等待仍未释放，消息实际落库数为三。该用例证明完整本地事实的首次登记不依赖冷请求空位；不宣称涉及远端 scope 的首次登记也能绕过容量约束。

调度单元测试增加满额时缓存命中不进入 loader、缓存缺失仍临时过载，以及已过期调用不执行 probe；原排队取消、执行后取消保留实际工作和错误分类测试保留。/tmp/imv2-local-policy-cache-scheduler-tests.log 三项、两个 suite 通过，1.030 秒。完整相关回归结果另记；Release 容量尚未重跑，整体目标未完成。

最终相关回归 /tmp/imv2-local-policy-cache-scheduler-regression-tests.log 九项、三个 suite 全部通过，8.024 秒，覆盖调度、本地满额缓存读取、目录淘汰与取消结算、生产私聊/群聊工厂、好友不依赖陌生人设置、四类修改期间的房间隔离。单独真实 TCP 回归 /tmp/imv2-local-policy-cache-scheduler-remote-tests.log 一项通过，0.958 秒；原路由归属、事实验证、到期、满额缓存读取及冷请求错误分类保持。测试进程全部实际 exit 0，相关 diff 检查通过，测试 PostgreSQL 已停止。

### 第十轮：局部缓存隔离通过，完整消息负载仍失败

Gateway Release /tmp/imv2-policy-memory-fastpath-release-build.log 成功，197.43 秒；Account Release /tmp/imv2-policy-memory-fastpath-account-release-build.log 成功，9.63 秒。运行 /tmp/imv2-memory-policy-10k1000-20261006-r10，仍使用原配对拓扑、10,000 在线夹具、60 秒计划输入 1000 新消息/秒、原队列与质量门槛。Runner 的 allow-scaled-diagnostic 表示此人数不是其通用 50,000 人正式容量模式，不关闭质量检查，也不扩大本次用户要求为 50,000 人。

memoryDeploymentChecked=true、activeDeployments=1、revision=1，十二份 ready 完整；消息阶段触发失败后仅收集六份报告。最终 result 的 authenticated/peakActive=5,000 是报告合计，不能据此宣称初始只上线 5,000 人。部分报告发送 9,995、ACK 7,378；SERVER_BUSY 860、UNAVAILABLE 60、关闭未知 2,602；共同窗口 0、qualityPassed=false、drained=false。report-0 accepted count=1,218、p50=2,667 ms、p95=8,737 ms、p99=10,000 ms、最大 12,308.63 ms；其 failure guard=2/1699。该分位值不是全局分位值，累计 ACK 与上一轮不同报告数量不能直接比较。

最新完整六节点采样保存 candidate/diagnostic-cold-stages.json。Owner 预读 11,039 次，均值 29.98 ms；策略状态 4,849 次，均值 1989.66 ms；登记 4,832 次，均值 21.94 ms；Owner 正文 9,382 次，均值 32.50 ms。策略状态阶段本轮包含 logical scheduler 排队，不能与第九轮不含该等待的 111.94 ms 直接比较。独立 queue_wait 的累计计数/耗时证明已获准冷请求存在约 1.9 秒的平均逻辑等待；不同指标统计总体并不完全相同，不能用简单相减得出真实 RPC 或 SQL 耗时。

最后采样 logical inFlight=5/5/5/3/2/5，queued=6/41/25/0/0/7；实际 policy preparation SQL inFlight=2/5/5/0/4/1，queued=0/9/13/0/0/0。冷请求 queue_full 和 timeout 均为零，这不意味着没有延迟或客户端失败。此前两处完整本地缓存隔离已被真实测试证明，但远端/缺失事实的有界冷请求仍明显排队，整体负载目标未实现。

Runner session 实际 exit 1，failureStage=workload、failureCode=run_failed；service cleanup settled=true、forcedKillCount=0、exitFailureCount=15。输出目录不存在 postmaster.pid，七个专用端口无 listener，全部运行资源已实际收尾。后续应核对冷逻辑调度与物理数据库额度的独立容量和生命周期，不凭这些数据直接扩大数据库连接、目录 roots 或队列长度。

### 接收端状态数据库工作与发起端冷请求分开测量

源码确认 GatewayRoomOwnerAssembly 的 logical state scheduler 直接使用 foregroundWriteDatabaseWorkLimit；一项 logical request 却会等待多个远端 Owner、接收端 SQL 准入与状态事务。第十轮的 1.92 秒 logical 排队不能单独证明实际 SQL 已饱和或尚有余量，因此本轮先补接收端证据，不改并发、连接、目录根或队列配置。

固定阶段增加 policy_owner_state_database_admission（接收端真实 SQL 准入等待）、policy_owner_state_transaction（取得许可后的完整状态事务，含借用/BEGIN/COMMIT）、policy_owner_state_facts（事务内事实锁定和读取）。Journal.acquireOwnerState 只在实际初始化/续租时计量；有效内存命中不进入，续租完全匹配复用事实时不记录 facts。准入阶段在 operation 获准时完成，拒绝/取消等失败也完成；事务和 facts 计时一直保留到实际 awaited future 结算。facts 是 transaction 的嵌套阶段，不能相加。

Gateway 将节点唯一 journal 的 stateMetrics 绑定到按物理键排序的第一份已有 sendOperationMetrics，后续原 aggregate 仅合并一次；没有为逻辑 alias 重复绑定 recorder，也没有新增带 user/room 标签的指标。多物理房间库时这些接收端计数代表共享控制库工作，不代表被选中房间物理库独占的事务。

增强真实 SQL 结算测试：先人工持有唯一准入，两个 Owner 调用共用一个实际加载，确认 wait inFlight=1 而 transaction count/inFlight=0；释放准入后用 pg_blocking_pids 确认真实 scope 锁阻塞，wait 已完成一次且 transaction inFlight=1；取消调用者和开始关闭仍保持该计数，释放真实锁后所有计数结算为一次。目录满额缓存读取同时确认 transaction/facts 次数不增加。

/tmp/imv2-policy-state-sql-metrics-tests-r2.log 七项、三个 suite 全部通过，1.445 秒，包含目录与指标聚合测试。第一轮唯一失败是断言等待期间事务指标为 nil；原 snapshot 初始化所有 stage 为零，已修正为 count/inFlight=0。增强三类事实续租验证 transaction=2/facts=1；事实表缺失引起实际回滚、成功加载、换主拒绝和 pending 拒绝共四次事务均结算，facts 只记录失败读和成功读两次。/tmp/imv2-policy-state-sql-metrics-failure-tests.log 两项一 suite 通过，4.199 秒。相关 diff 检查通过，测试 PostgreSQL 已停止。

Gateway Release 重建已启动，日志 /tmp/imv2-policy-state-sql-metrics-release-build.log。完整负载诊断还需用这些实际接收端指标验证，不能把新增计量本身当作性能修复或整体目标完成。

### 第十一轮：确认冷状态接收端也有数据库等待

Gateway Release 成功，206.73 秒；Account Release /tmp/imv2-policy-state-sql-metrics-account-release-build.log 成功，9.55 秒。/tmp/imv2-memory-policy-10k1000-20261006-r11 使用原夹具、场景、额度与门槛，仅增加接收端计量。memory active v1 检查和十二份 ready 完整，最终只有六份报告。result authenticated=5,002 为部分报告合计；发送 9,993、ACK 7,194、SERVER_BUSY 921、UNAVAILABLE 60、关闭未知 2,782；共同窗口 0、qualityPassed=false。report-0 accepted count=1,201、p50=2,749 ms、p95=8,842 ms、p99=10,000 ms、最大 11,923.41 ms、failure guard=3/1697，仍不是全局分位值。

最新完整六节点采样 candidate/diagnostic-cold-stages.json：Owner 预读 10,851 次、均值 30.91 ms；发起端状态获取 4,864 次、均值 1917.02 ms；接收端状态 SQL 准入等待 12,721 次、30.39 ms；完整状态事务 12,700 次、27.42 ms；事务内事实锁定/读取 12,703 次、7.77 ms；登记 4,857 次、22.15 ms；Owner 正文 9,150 次、33.09 ms。状态 SQL 与客户端状态请求计数不同，facts 与 transaction 嵌套，不能把这些均值直接相加或相减来推导客户端延迟或未计量工作的耗时。

独立 logical queue_wait 4,720 次、累计 8,793,395 ms、均值 1863.01 ms。最后采样接收端 policyPreparation SQL 六节点均 inFlight=5，queued=0/3/3/1/4/0；发起端 logical inFlight=5/1/5/2/2/5，queued=28/0/10/0/0/27。实际 SQL 准入等待和六节点名额占满证明接收端存在争用；不支持只根据发起端排队便扩大远端请求并发。完整状态事务仍包含借用、事务设置、scope claim、事实读取和 COMMIT，需要依据具体实现继续优化必要的冷初始化工作，不能移除事实版本和所有权围栏。

Runner 实际 exit 1，failureStage=workload、failureCode=run_failed。service cleanup settled=true、forcedKillCount=1、exitFailureCount=15；本轮不能宣称零强制清理或资源验收通过。独立 postmaster.pid 已不存在，七个专用端口均无 listener；实际进程和服务已结束。整体方案与原 10,000 在线 / 1000 新消息每秒验收保持未完成。

### 获取策略所有权合并往返，保留续租前元组与锁后时钟

获取策略 scope 所有权原有四次 SQL 往返：确保行存在、FOR UPDATE 读取、读取数据库时钟、更新租约。现保留确保行存在的独立 INSERT（不依赖同一 data-modifying CTE 的语句快照看见新插入行），后三步合并为一条语句。locked MATERIALIZED 取得单个 scope 行锁；observed 依赖该行，锁等待结束后才采样 clock_timestamp；decision 捕获续租前 revision、owner ID、epoch、有效期和 pending seal，以及数据库计算的 is_current/is_expired；renewed 只有在持有者仍有效或旧租约已过期/不存在时更新。一次获取所有权现为两次往返，不跨 scope 批处理，不改变数据库额度。

返回给状态初始化的是续租前元组，不能用更新后的 epoch/Owner 判定缓存复用。是否当前持有者或已过期直接使用同一次数据库裁决的布尔值，避免 Swift Date 精度再次比较后导出不同 epoch。当前持有者保留 epoch；到期或换主推进 epoch；maximum epoch 可有效续租，不能在到期/接管时溢出。拒绝有效外部 Owner、版本、pending seal 和事实读取后租约到期检查保留；事实读取失败仍回滚本次 Owner 更新。此 helper 同样用于策略修改中的取得/续租，不只用于首次状态加载。

新增 ownerClaimClockAfterLock 两个参数场景：pg_blocking_pids 与固定 SQL 模式确认合并语句本身正在等待 scope 锁，然后让阻塞事务更新 revision 并保持锁，数据库时钟确认旧租约过期后才释放。同 Owner 和新 Owner 均取得 epoch+1、最新 revision 和有效新租约。新增 ownerClaimEpochLimit 验证有效 maximum epoch 续租、外部持有者拒绝，以及到期后同/不同 ID 的 invalidRequest，数据库持有者及 epoch 不被误更新。

首次 Journal suite /tmp/imv2-policy-owner-claim-tests.log 十项通过，12.114 秒；增强版本竞赛的第一版屏障未观察到合并语句的等待点，两个场景超时，未作为通过证据。将版本更新移到观察真实等待之后，最终 /tmp/imv2-policy-owner-claim-tests-r2.log 十项一 suite 全部通过，11.544 秒，包含原注册/撤销/回滚/换主/时钟测试。

/tmp/imv2-policy-owner-claim-regression-tests-r2.log 八项一 suite 全部通过，16.810 秒，覆盖冷读失败原子回滚、事实锁等待至租约过期、三类事实续租复用、pending/revision/epoch/takeover 围栏、真实状态 SQL 取消/关闭结算、四类领域修改及失败恢复、四类策略修改期间房间隔离。相关 diff 检查通过。性能效果仍须以之后相同资源配置的 Release 负载验证，不能以减少 SQL 调用次数宣称容量目标通过。

最终真实 TCP 与目录回归 /tmp/imv2-policy-owner-claim-remote-tests.log 四项、两个 suite 全部通过，1.228 秒。所有测试进程实际 exit 0，测试 PostgreSQL 已停止。容量验收尚未完成，目标保持进行中。

Gateway Release 重建已启动，日志 /tmp/imv2-policy-owner-claim-release-build.log；构建完成和同配置负载结果尚待验证。

后续验证：Gateway Release 构建成功（188.79 秒），Account Release 构建成功（9.46 秒）。第十二轮 /tmp/imv2-memory-policy-10k1000-20261006-r12 完成十二份 ready，但仅收集三份消息报告，发送 4,994、ACK 3,611，共同窗口为 0、qualityPassed=false。这些部分报告不能证明完整在线人数或 60 秒容量。最新完整六节点采样的状态事务均值 24.38 ms、事实读取 8.40 ms、发起端状态获取 1544.78 ms；独立逻辑队列等待均值 1607.51 ms。不同失败窗口之间不能据此宣称稳定性能收益。Runner 实际 exit 1，cleanup settled=true、forcedKillCount=1；专用端口及数据库均已关闭。原容量目标仍未通过。

用户再次指出工作偏离后，当前讨论回到授权状态的领域归属、变更入口和内存更新顺序。上述压测及 SQL 优化只作为既有证据，不替代该设计讨论，也不继续扩展真实环境闭环。

### 本地正常入口接入内存授权

核对实际入口：Account main 在 policyPlacement 模式下将关系和陌生人设置 store 绑定到 actor.policyMutationExecutor；Operator main 在相同模式下将 disableService 绑定到策略修改 executor；GatewayPolicyAssembly 共用一份 OwnerDirectory 处理读取及修改。正常启动脚本此前却未传 policy partitions，只生成 Gateway/Account，且 Operator Compose 未挂载 actor 配置，因此此前基准启用内存模式不能证明本地普通启动已接入。

本轮修正本地新配置默认生成三份进程身份和 16 个策略分区，全部由 Gateway 持有；Operator 配置作为独立 caller 挂载。启动前新增只读一致性校验，拒绝缺失或不同 placement、遗漏分区和没有修改权限的 writer。已有旧目录不重写身份、不静默回退旧授权；旧配置和旧数据库的切换不作为自动迁移处理。此变更仅覆盖本地入口，不展开生产环境闭环，也不改变数据库并发额度、租约或消息事务。

python3 IMV2/scripts/test_v2_local_policy_configuration.py 五项测试通过（0.207 秒），使用真实生成的三份签名/证书配置，验证完整 wiring、旧/不一致配置拒绝、修改权限缺失拒绝、分区遗漏拒绝以及重复生成失败且全部已有文件字节保持不变。未启动 Docker 服务，不能据配置测试宣称实际三进程运行验收或完整消息容量通过。

最终配置测试重跑五项通过（0.189 秒）；bash -n 启动脚本、docker compose --env-file IMV2/.env.local --file IMV2/docker-compose.local-account.yml config --quiet 及相关 diff 检查通过。Compose 仅校验配置，没有启动或重建已有本地服务。

### 已提交修改的重放保留有效内存事实

Owner.changeExecution 此前在任何新调用时清除内存事实；若 journal 返回永久回执重放，execution.state 为空，完成后仍为空，下一次状态请求会重新读取数据库。现捕获调用开始前的内存状态，仅在永久回执重放、没有新的执行状态且原状态仍有效时将其作为候选。原 jobFinished 的 generation、无其他修改/恢复任务、未关闭检查仍决定是否发布；新修改、失败、到期状态不会因此恢复旧事实。重放返回值仍不携带新的授权状态，也不重新获取 Owner 租约。

真实 PostgreSQL 测试在修改提交后隐藏账号事实表，再重放该修改并调用 registrationState；Owner 元组、事实和 deadline 与重放前完全一致，不需要冷事实读取。原实际 COMMIT 成功/失败两个场景均通过，/tmp/imv2-policy-replay-memory-tests.log，一项两个参数场景、1.850 秒。最终 Debug 构建成功（71.02 秒）。

相关回归 /tmp/imv2-policy-replay-memory-regression-tests.log 四项、两个 suite 通过，4.173 秒，包括取消/关闭保留实际修改责任、恢复仅处理本 scope、换主后永久结果重放，以及拉黑/解除好友/陌生人设置/封禁四类修改期间无关热房间推进。测试进程全部实际 exit 0；专用测试 PostgreSQL 已停止。此次 Swift 修改尚未重建 Release 或重跑完整容量验收，原目标保持未完成。

### 权限恢复不为已有资料重复读取账号表

扩展 warmRoomPolicyMutationIsolation：原允许到拒绝路径后，在同一个 activation 上执行解除拉黑、重新请求并接受好友、允许陌生人消息；修改提交后再次隐藏两端六张事实表，验证受影响房间恢复接受、无关房间继续接受。封禁场景保持原拒绝验证，不新增不存在的解封接口。

初始新增三个恢复场景均返回 outcomeUnknown。阶段定位证实修改已经完成，失败在恢复后的发送；专用 PostgreSQL 日志只提取固定表名和 CTE 名称，确认消息投影 SQL 仍引用 public_user_profiles。既有资料可见且此次仅恢复 can_send，但 appendBatch/appendSingle 仍要求 profile 存在，并把全部 needed capability 行纳入资料数量校验。这不是内存权限事实发布失败，也不证明资料表正常可用时恢复发送失败；隐藏事实表的强验证揭示了多余数据库依赖。

PostgresV2RoomWriteDirectProjections 现仅在有首次展示资料的输入时拼入资料查询。仅能力变更时 profile CTE 使用有明确列类型的空集合，不引用账号表；混合输入的资料读取和数量校验仅覆盖尚不可见的资料。单条路径同样只在需要资料投影时要求 profileExists。消息、能力/资料 outbox 和 pair 标记仍在同一事务原子提交；首次资料缺失不能凭此短路为成功，也未引入额外缓存、放宽授权检查或改变数据库额度。

第一版分离资料读取后未同步调整原有数量/存在校验，新增测试仍失败；修正校验后 /tmp/imv2-policy-restoration-tests-r4.log 四个参数场景通过，4.501 秒。最终加强 outbox 验证：首次发送确实向接收方生成一份资料事件；恢复能力后这份资料事件不重复，可发送 true 事件增加一次；消息实际数量与每次接受对应，冷状态/登记只增加受影响方向的一次加载。

最终 /tmp/imv2-policy-restoration-regression-tests.log 四项一个 suite 全部通过，10.148 秒：四类修改及三个反向恢复、私聊策略/陌生人配额/资料投影的标量回归、原子私聊批次的控制权限，以及 direct/standard/hybrid 的房间日志发送。Debug 构建成功，测试进程实际 exit 0；专用 PostgreSQL 已停止。相关源码 diff 检查无空白问题。没有重跑 Release 容量，不能把这次必要 SQL 依赖修正等同于 10,000 在线 / 1000 msg/s 验收通过。

### 房间授权创建与围栏 SQL 接入已有准备准入

核对生产路径发现 PostgresV2RoomPolicyAuthorizationDirectory 的 factory 查询与 PostgresV2RoomPolicyLeaseFence 的独立 install/revoke 事务未进入 sendPreparationAdmission。底层物理 loan gate 仍限制连接总数，因此不能描述为无界连接；遗漏的是这些实际准备工作对现有准备预算和等待队列的参与。

GatewayPolicyAssembly 现把同一物理 Owner resources 的 sendPreparationAdmission 传给 V2RoomPolicyAuthorizationService；各 convenience/local/remote 构造都传递该参数。目录仅在实际 factory 短事务上获取 sync 名额，已有 registry 内存命中不获取；所建 fence 的独立 install/revoke 同样获取该名额并保持到事务 future 结算。requireActive/combined fence 仍在已获准消息事务内执行，不嵌套申请准备名额。没有创建第二个 controller、增加 pool 或上限，也没有让准备额度覆盖远端策略等待；前一步 SQL 结束后才进入下一步。

增强 fallbackWaitsForSQL：人工占满唯一 sync 名额，install 等待时 lease 表仍无写入；释放后安装成功，名额归零。随后真实消息事务持有 SHARE，revoke 在真实 PostgreSQL 锁上等待；取消调用方后目录 revocation root 和 sync inFlight 仍为一，实际消息事务释放后撤销成功，两者归零。失败清理记录人工持有标志，避免安装失败后重复释放额度。

生产 service 测试 remotePolicyWaitDoesNotHoldDatabaseAdmission 使用同一 controller 控制房间创建、围栏和控制准备。首次发送前人工占满名额，确认排队为一、策略 Owner 尚未创建、远端 provider 未进入；释放后实际发送接受。后续远端冷状态及其逻辑队列均占满时，控制 SQL 名额仍为空，热房间及完整本地缓存的新 service 都能登记并提交。

初次 /tmp/imv2-policy-room-admission-tests.log 四项两个 suite 通过，1.491 秒。加强并发工厂测试的第一轮构建因局部 helper 缺少 Sendable 边界失败；将 command/sendWarm 明确为 Sendable 并捕获不可变 warmRoom 后修复，没有放宽 Swift 并发检查。最终 /tmp/imv2-policy-room-admission-regression-tests-r2.log 六项两个 suite 全部通过，6.861 秒，Debug 构建成功（27.89 秒），涵盖创建/退休/取消、真实 SQL 撤销结算、远端等待隔离、实际 COMMIT 成功/失败及四类策略变更与恢复。进程实际 exit 0，专用 PostgreSQL 已停止，相关 diff 检查通过。

此步骤接入此前遗漏的房间授权 SQL 使用者，并不证明工作准入与底层连接租借已完全统一为一个资源代理。Release 尚未重建，完整容量门槛及其他原方案验收仍未完成。


## 2026-10-06：授权归属调整为当前内存状态，取消新路径的房间撤销等待

用户指出实现偏离“状态放在哪里、策略变更如何更新内存”，并要求先不考虑真实环境闭环。授权边界调整见 [授权内存状态重设计](policy-memory-state-redesign.zh-CN.md)。原消息调度、永久回执、房间所有权及容量验收范围没有缩减。

GatewayPolicyAssembly 的 policyPlacement 路径同时启用当前状态发送和无房间 drain 的策略 journal。发送每次准备读取授权 Owner 的当前账号/关系/设置事实，构造不含 holder 的不可变授权结果；房间不复用策略快照，不登记 room registration，不安装或锁定账号策略 room lease。命令身份、原截止、Room Owner/activation、成员及其他房间规则仍验证。策略修改持久化事实/版本/回执、提交后发布 Owner 内存，然后返回；不枚举或等待房间。已授权消息允许完成，完成后的执行句柄立即失效。

为了避免旧合同被静默跳过，新 journal 在目标 scope 仍有未撤销旧 holder 时拒绝变更，不创建 pending 标记；并禁止新模式注册 holder。旧租约代码保留作为明确的旧合同路径。本次没有进行既有部署的数据迁移。

实际验证：专用 PostgreSQL 25462，/tmp/imv2-current-policy-service-tests-r2.log 中 13 项测试、3 个 suite 通过（15.039 秒），包括四种策略变更不等待实际消息 COMMIT、新授权只读已更新内存、Owner Batch/preborrow、永久结果重放、解除拉黑恢复、实际提交失败不发布、旧 holder 拒绝及旧路径回归。/tmp/imv2-current-policy-group-isolation.log 中 3 项测试通过（4.199 秒），包括群聊仅发送者状态、封禁后内存拒绝，以及新旧路径远端等待时的 SQL 资源与其他房间隔离。首轮新测试因 fixture 的容量租约使用历史截止导致开房失败，按既有测试约定更新专用 fixture 的租约后通过；没有调整生产连接或并发预算。

/tmp/imv2-current-policy-forward-recovery.log 中 1 项参数化测试、8 个变体通过（6.781 秒），同时覆盖新旧边界的私聊/群聊转发、实际 COMMIT 后最终化阻塞与失败、停用发送者、原永久接受结果恢复及缺失证明拒绝。

注意：新路径 policyOwnerState 阶段现在覆盖每次授权准备，包括内存命中；旧 room snapshot 路径仅在加载快照时记录该阶段。新旧阶段均值的采样范围不同，不能直接推算性能收益。本次未重建 Release、未重跑容量负载。既有 10,000 在线 / 1,000 msg/s 的失败结论仍有效，整体目标继续实施。


## 2026-10-06：内存事实准备保留房间规则与永久业务结果

上一版新路径在准备阶段调用 requireAllowed，提前拒绝了非好友且拒收陌生人设置，漏掉接收方已回复的既有例外；拉黑/停用等早期抛错也绕过了原永久拒绝回执。已经移除这个业务判断。准备阶段读取并绑定 Owner 内存事实，消息事务结合锁定的回复、成员、配额等房间事实完成判定并持久化结果；没有把账号、关系、设置的读取放回 SQL。准备阶段绑定的事实是该命令的策略输入，不能等同于最终消息接受结果。

/tmp/imv2-current-policy-room-rules.log：4 项测试、13 个变体通过，11.822 秒。覆盖已回复/未回复、拒收陌生人设置、scalar/Owner Batch/preborrow、事实表隐藏后的热发送、拉黑拒绝身份在解除拉黑后仍重放原拒绝、停用发送者的永久 permissionDenied，以及四种策略变更仍不等待原消息 COMMIT。

/tmp/imv2-current-policy-room-rules-regression.log：转发恢复 8 变体、旧路径发送 8 变体、陌生人设置与配额测试通过。TCP 转发扩展到新模式后，原测试锁定不存在的策略租约，导致没有阻塞真实 SQL；测试改用所有模式都必须检查的持久房间行，不增加超时、不移除取消期间的实际 SQL 与房间预留检查。受影响测试重新执行 /tmp/imv2-current-policy-room-rules-remote-r2.log：同 host / 分离 host 与新旧模式 4 变体通过，8.451 秒。

当前授权验证的最新行为与限制见 policy-memory-state-redesign.zh-CN.md。前一节“新授权拒绝”的证据现已加强为消息事务的实际业务结果与永久回执，不再依赖准备阶段抛出权限错误。Release 未重建，容量验收尚未完成。


## 2026-10-06：恢复策略的生产房间验证与过期事实保留

原 warmRoomPolicyMutationIsolation 现覆盖新旧两种授权边界，共 8 个变体。当前状态模式在实际策略 outbox 写入处阻塞 COMMIT，确认不相关房间经过生产 RoomActivationHost 仍可提交；变更成功后隐藏控制库与房间库的所有策略事实表，受影响房间返回持久拒绝，不相关房间继续提交；重新成为好友、重新开启陌生人消息以及解除拉黑后，再次隐藏事实表，原 activation 的新消息恢复发送且首次账号资料事件不重复。该测试不用修改缓存模拟状态更新。初次 /tmp/imv2-current-policy-restoration.log 通过，7.008 秒。

同时修正内存发布对租约剩余时间的耦合：真实提交后的精确事实即使对应租约已过期也保留在 Owner 内存，永久结果重放不会丢弃这些事实。过期状态仍不能直接作为授权；读取续租必须持有 scope 锁并匹配续租前 owner ID、epoch、revision，pending、接管和版本变化不能直接复用。没有延长授权有效期或跳过所有权验证。

/tmp/imv2-current-policy-expired-commit.log：9 项测试、2 个 suite 通过，10.611 秒。新测试在实际提交事务中等待一秒租约到期并隐藏事实表，验证实际 COMMIT、过期缓存不可直接授权、永久回执重放、续租 epoch 前进和无事实重读；同时覆盖真实 COMMIT 失败、不同事实类型续租、接管/版本/封闭 scope 和 Owner 操作恢复。修改后再跑 /tmp/imv2-current-policy-restoration-regression.log：生产房间 8 变体与当前服务 2 变体通过，2 项测试共 9.580 秒。

测试专用 PostgreSQL 25462 已结束使用；后续正在重建 Release Gateway 与 Account 二进制，构建结果另记录。当前没有新的容量验收证据，整体目标仍未完成。

## 2026-10-06：收敛新策略修改为单事务

新授权此前仍沿用 acquireOwner、beginChange、commit 的独立事务。现 Owner 在新模式直接调用 changeCurrentPolicy，一次事务处理状态写入权、领域事实、版本、永久操作结果和通知义务；提交后更新内存，再回复。没有独立准备阶段或持久 pending 标记，不查询撤销目标，也不更新房间 holders。原合同的两阶段撤销路径继续回归；新装配不再构造撤销 RPC 依赖。

验证日志 /tmp/imv2-current-policy-atomic-tests.log：4 项测试，11 个变体，11.591 秒通过；实际 COMMIT 失败时无中间操作记录、无 pending 标记、事实和版本不变，并可读取原状态再重试。/tmp/imv2-current-policy-atomic-regression.log：18 项测试、3 个 suite，22.519 秒通过；新旧模式的同状态排序和不同状态独立提交、旧注册合同、生产房间恢复、陌生人回复规则与永久转发结果回归均通过。新 Gateway 装配的编译及最新 Release 重建随后验证。容量验收仍未完成。

最新 Release 两个产品构建成功；R13 本地压测完整取得 12 份报告、10,000 在线，但只有 20.002 秒有效窗口，19,989 提交 / 15,293 ACK，质量验收失败。失败率保护触发后关闭客户端，资源清理完成且无强制结束。授权 registration 为零，窗口内事实 SQL 仍多；重算当前两目标私聊 fixture 的状态工作集为 30,000，前四节点负责状态数超过默认 4,096 内存 Owner 上限。后续需直接观测驱逐/冷读与远端状态读取排队，修复授权状态保留设计；此次结果不能宣布完整消息重设计完成。具体数值与证据见 policy-memory-state-redesign.zh-CN.md 最新段落。

## 2026-10-06：授权事实独立于空闲运行对象保留

保持原 4,096 Owner 对象与任务/连接预算，Gateway 启用额外有界紧凑事实区（最多 4,096 状态、估算值最多 4 MiB）。回收空闲对象不再必然丢弃事实；状态写入仍由同一 Directory 的唯一 Owner 处理，保留区在重建前取走状态，实际提交后才可再次保留，过期状态仍按原 tuple 验证后续租。增加固定枚举的 lookup/eviction/restoration 指标。详见 policy-memory-state-redesign.zh-CN.md 最新节。

三次实际测试分别 6 项 / 10 项 / 5 项通过，覆盖单对象多状态、满字节预算、真实提交成功与失败、双方逆序状态归属、隐藏事实表后过期续租、取消/关闭及生产房间隔离。最新源码的 Release 与容量验证仍待运行，整体目标未完成。

R14 最新 Release 压测仍失败：10,000 在线、20.004 秒窗口、19,983 提交 / 14,947 ACK，正常服务资源已结算、无强制结束。新增事件显示当前窗口并无 Owner 或事实驱逐，紧凑状态保留路径没有被触发；此前静态工作集计算不能解释该次失败。实际窗口同时包含大量内存命中和首次加载，远端已缓存状态仍先排入调用方冷加载队列。后续应先解开这层热/冷请求等待耦合，并保留真正冷加载的有界 SQL 责任，而非无依据增加缓存、RPC 或连接上限。详见授权设计文档 R14 节及 candidate/policy-window-diagnostic.json。完整目标继续未完成。

## 2026-10-06：拆开远端已缓存读取与真正冷加载排队

已有签名 policy claim 增加 cachedOnly，接收方仅查权威内存，空 miss 不创建数据库任务。Gateway 显式启用远端内存探测，在原冷队列之前查询；真正 miss 保留原冷任务/SQL 预算。非空结果继续验证完整 scopes、预期 Owner、事实类型及截止，过期探测可由冷路径重新续租。不存在发送方长期策略副本，也不增加独立后台队列。添加探测子阶段和固定 hit/miss 计数。具体接口与内存/SQL 生命周期见授权设计最新段落。

真实 TCP 饱和队列/SQL 根测试与 DTO 测试 2 项通过；房间回归 7 项通过；跨 host 转发回归 4 个变体通过。日志分别 /tmp/imv2-remote-memory-probe-tests-r3.log、/tmp/imv2-remote-memory-probe-room-regression.log、/tmp/imv2-remote-memory-probe-forward-regression.log。最新 Release 与容量验收待进行，整体目标仍未完成。

R15 两产品最新 Release 构建成功，容量仍失败且仅收齐 8/12 份报告，无完整共同窗口。启动 ready 屏障确认 10,000 在线，但不能据此外推稳定在线或吞吐。远端 probe hit=8,150、miss=5,085 生效，局部探测均值约 18 ms；真实冷等待均值仍约 1.72 秒，消息正文约 38 ms。五个节点准备任务达到 128 上限，同时大量任务仍在等待冷准入。代码确认准备器用全部尚未完成 batches 数量决定执行槽，冷排队任务占满时其他房间不能启动，即使它可以从内存授权。下一阶段应落实原方案的需求登记与分阶段执行资源边界，保留实际任务/截止/字节责任，不靠扩大任务或连接上限掩盖等待。详见授权设计 R15 节及局部诊断；完整重设计和容量目标继续未完成。


### 2026-10-06：Owner 预读与策略准备分阶段

将当前策略路径的 `PostgresV2MessageSendOperationStore.prepareOwnerBatches` 拆成 `readOwnerPreparationInputs` 和 `prepareOwnerPolicyInput`，原生产入口已经通过这两个阶段执行。第一阶段完成预算/永久回执预读并归还实际读取资源，签发不可变的 `V2OwnerMessageSendPreparationInput`；第二阶段使用原输入读取策略并构造最终 prepared handle，不重新执行 Owner 预读。

输入的 Store 标识、完整命令、activation、原截止、待授权命令和预算快照由 Store 私有构造，外部不能 retarget 或伪造。下一阶段仍受原截止及更严格的当前 TaskLocal 截止限制，不同 Store 使用输入会在策略读取之前拒绝。预读结果只是优化，最终执行仍验证永久结果与房间围栏，输入本身不授予写权限。批次上限、结构化子任务上限和取消后实际任务结算保持原边界。

`currentPolicyServiceSendAndReplay` 使用分阶段接口，在普通执行和 preborrow 两个变体中验证真实接受、拉黑后的永久拒绝、接受/拒绝结果重放、解除拉黑以及隐藏全部策略事实表后的内存授权。每次构造 prepared handle 都断言第二阶段没有增加 Owner 预读次数，另一个 Store 被拒绝，已经过期的更严格 TaskLocal 截止在状态读取开始之前被拒绝。

`/tmp/imv2-owner-preparation-phases-tests-r2.log`：16 项测试通过（23.898 秒），还覆盖准备读取许可不跨授权等待、不同房间独立完成、同房间 FIFO、取消/关闭、实际单房间事务、固定后端以及四种策略修改期间的真实发送。

这一步提供保存预读结果的阶段边界。当前 collector 仍等待整个策略准备返回，尚未把冷等待改为无任务的有界需求；因此不能据此宣称 R15 的 128 槽阻塞已经消除。后续需要让缓存缺失的阶段返回保留原输入的需求，资源获准后才创建实际冷加载任务，collector 在真正结算前继续保留房间顺序与命令/字节责任；等待不得被计作完成，也不得通过增加任务或冷加载许可上限来绕过问题。本轮没有重建 Release 或重复容量测试。


补充 `/tmp/imv2-owner-preparation-phases-domain-tests.log`：群聊发送者账号授权及私聊陌生人设置/回复规则两项测试通过（5.623 秒），私聊覆盖 scalar、Owner Batch、preborrow × 已回复/未回复六个变体；隐藏事实表后仍保持正确业务判定。此次阶段拆分相关检查合计 18 项通过。


### 2026-10-06：冷状态请求改为注册式有界需求

`V2PolicyStateRequestScheduler` 从复用数据库准入的等待接口改为独立的需求 actor。`register` 同步保存不可变工作闭包、原截止和完成回调后返回；排队需求不创建加载任务。只有获准需求才创建一个实际加载根任务，始终受原 `maximumInFlight` 上限约束；原等待队列容量及等待预算不变。等待队列采用 `V2IndexedFIFO`，取消通过 UUID 索引删除，一个最近截止定时器替代逐请求定时器。

已获准工作继续保留到 SQL/RPC 操作实际返回，包括 COMMIT；请求取消不归还仍在执行的槽位。原 `perform` 和 `v2WithScheduledPolicyStateRequest` 现在通过注册队列运行，并保留临时拒绝/真实 unknown 的分类。新的完成回调先结算实际操作和槽位，再唤醒调用方；缓存命中仍绕过冷队列。固定等待直方图、排队/在途及拒绝计数继续使用原指标接口。

排队时捕获原 SQL 截止、物理租借 purpose、观测 source、SQL trace/metrics 与 handoff 上下文；派发时显式恢复，不能继承前一条任务的上下文。关闭拒绝排队需求并等待实际已启动任务，不因关闭调用方取消而提前释放。`GatewayPolicyAssembly.shutdown` 现先结算该请求调度器，再关闭状态 Owner 和客户端绑定。

最终 `/tmp/imv2-policy-state-demand-sql-settlement-tests.log`：6 项、2 个 suite 通过（0.828 秒）。五项队列回归覆盖有界注册、缓存旁路、排队取消/溢出、活动任务取消、原截止/较短等待预算、排队请求的独立任务上下文、关闭时保留实际工作。新增真实 SQL 测试锁住账号事实行，并通过 `pg_blocking_pids` 证明活动加载确实等待数据库；关闭仍保留加载根、Directory 根和事务计数，释放真实锁并结算后才全部归零。取消的等待需求没有运行，也没有生成其策略 scope 行。

`/tmp/imv2-policy-state-demand-tcp-tests.log`：认证 TCP/HTTP 两项测试通过（1.949 秒，当前/旧边界均覆盖）。`/tmp/imv2-policy-state-demand-room-tests.log`：四项测试通过（14.209 秒），覆盖分阶段实际消息准备/执行、四种策略修改期间发送、策略更新不等待实际房间 COMMIT、状态加载保持原截止。相关最终检查合计 12 项通过。

尚未消除上游阻塞：当前 collector 经 `perform` 等待整个授权准备，所以其准备根仍可能被冷排队占用。本阶段只完成可供 collector 使用的无等待任务注册接口，以及现有冷加载路径的替换。下一阶段必须把缓存探测与实际冷加载分开；缓存缺失后保留 Store 预读输入、原命令/字节/房间顺序责任，注册需求并结束已完成的探测任务；获准后才启动冷加载并完成原准备。准备探测和实际冷加载须共同遵守原实际任务预算，不能用抬高并发上限替代阶段切换。Release 与容量本轮没有重跑，整体目标仍未达到。

### 2026-10-06：R16 原本地负载复测，尚未通过

本轮在授权内存局部修改与回归通过后重新构建 Release Gateway、Account、Loader，三项构建均成功，构建日志分别为 `/tmp/imv2-policy-memory-r16-gateway-build.log`、`/tmp/imv2-policy-memory-r16-account-build.log`、`/tmp/imv2-policy-memory-r16-loader-build.log`。运行原 fixture `/tmp/imv2-10k1000-current-fixture-20261005` 与原场景 `actor-realtime-message-redesign-1000.json`，仍为 10,000 TCP 在线、1000 新消息/s、60 秒计划发送阶段，原并发预算、超时、客户端队列和完成等待均未改变。独立输出 `/tmp/imv2-memory-policy-10k1000-20261006-r16/candidate`。未新增授权传播、接管或部署实现。

12 个 ready 标记合计 requested/active 均为 10,000，最终 12 份 loader 报告也全部写出。发送阶段约 20 秒触发失败保护：共同窗口 20.001 秒，发送 19,982、ACK 13,781、workloadFailed 6,201，全部 loader 非零退出。报告的短失败阶段 ACK 速率约 686.50/s，不是 60 秒通过吞吐；各 loader 接受延迟 p95 为 8,933–9,905 ms，p99 均为 10,000 ms。`steadyStateCompleted`、`steadyStateCommonWindowPassed`、`coverageProofPassed`、`drained`、`qualityPassed` 均为 false。

错误分类：53 次 `TCP_DEFERRED_RETRY_EXHAUSTED` 触发各 loader 的工作负载保护，退出时另有 6,148 次 `TCP_OUTCOME_UNKNOWN_CONNECTION_CLOSED`；后者是关闭过程中未结算操作的结果未知，不能直接视为未提交、永久丢失或服务器主动断开。记录 `SERVER_REJECTED_SERVER_BUSY` 2,791 次，包含重试，不等同于 2,791 个独立永久失败。`scenarioMessageQueueAbandoned` 为 10。服务清理 settled=true、forcedKillCount=0，12 个非零退出均来自 loader；PG24532 正常停止并验证无响应。

`policy-partial-window-diagnostic.json` 使用严格位于失败共同窗口内的 4 个指标样本，跨度 15.442 秒，限定为瓶颈诊断。准备实际任务各节点峰值 13/35/16/19/18/34，未再占满原 128 总任务预算；冷等待保持数据，waitingPolicyTurns 峰值 119/169/165/131/109/144。各节点实际 cold 根任务仍为 5，队列峰值 114/164/160/126/104/139，冷队列已完成等待样本均值 2,277.75 ms，仍有严重积压。内存 snapshot probe 命中 6,963、未命中 7,844；Owner eviction 为零，不能归因于缓存淘汰。

诊断阶段均值：内存探测 17.76 ms，Owner 预读 35.43 ms，state SQL 准入 14.63 ms、事务 30.65 ms、事实读取 10.23 ms；Owner 连接获取 12.09 ms、设置 7.76 ms、正文 38.17 ms、提交 4.40 ms。这些是不同计数及嵌套边界，不能相加得出客户端延迟。分阶段准备将 cold queue 等待移出了 `policy_owner_state` 计时，故本轮该阶段 44.22 ms 不能直接与 R15 的 560.90 ms 比较并宣称整体提速。

本轮证明生产准备器已将冷等待与实际任务分开，但没有解决原容量目标。后续仍需根据冷加载工作量、实际 SQL 占用与准备后的等待逐项定位；不能用局部缓存正确性或启动 10,000 连接替代全链路验收。

### R16 后的局部冷加载优化

账号状态的 profile / special 两组行锁已合并为一次数据库调用，保持锁顺序与锁等待后的新快照读取。行锁、租约到期、回滚和生产发送相关回归通过，细节见授权内存状态文档。R16 是这项合并之前的二进制结果；合并后的 Release 尚未构建或复测，原容量要求仍未通过。

### 2026-10-06：R17 复用 Owner 预读回执后复测，尚未通过

current-state 的 `readOwnerPreparationInputs` 复用 `readBudgetSnapshot` 已返回的永久回执与域指纹，移除第二次连接租借和重复 SQL，仍解码、校验并让最终事务在操作锁内再次确认结果。实际发送测试新增已完成身份更换消息内容的冲突案例，四个准备/执行变体均保持 fingerprintConflict，且不增加 fresh policy preparation。`/tmp/imv2-owner-preflight-reuse-tests.log`：4 项真实数据库测试通过（10.693 秒）。

之后重建 Release Gateway、Account、Loader 均成功，分别记录 `/tmp/imv2-policy-memory-r17-gateway-build.log`、`/tmp/imv2-policy-memory-r17-account-build.log`、`/tmp/imv2-policy-memory-r17-loader-build.log`。R17 包含此前账号两组行锁合并及本轮回执复用。使用原 fixture、原 60 秒计划阶段、原数据库及逻辑并发、原客户端队列和超时。输出 `/tmp/imv2-memory-policy-10k1000-20261006-r17/candidate`，不是预热或缩减负载的对照。

12 个 ready 标记合计 10,000 active/requested；最终只有 10 份报告，覆盖 8,333 authenticated、发送 16,653、ACK 11,790、workloadFailed 4,863。已有报告的阶段约 20 秒，42 次 deferred retry exhausted，以及清理中 4,821 次连接关闭造成结果未知。完整 common window 为 0，steady/coverage/drain/quality 未通过；各已报告 loader 的 p95 为 9,212–10,000 ms、p99 为 10,000 ms。部分报告的速率 585.60/s 不可与 R16 完整 12 份失败报告的速率直接比较，不能当作完整 10,000 人吞吐。

诊断只使用这 10 份已知报告的重叠阶段内 4 个指标样本，跨度 15.503 秒；`knownReportsOverlapSeconds` 约 20.010 秒不是完整共同窗口。Owner 预读阶段均值 18.34 ms（R16 同名阶段 35.43 ms），账号事实改动后的聚合 facts 阶段均值 8.75 ms（R16 10.23 ms）；这些是局部诊断，并非受控总体性能对比。state SQL 事务均值仍 29.14 ms，cold queue 已完成等待均值 2,396.77 ms，Owner 正文 38.56 ms。不同计数与嵌套阶段不能直接相加为客户端延迟。

各节点准备实际任务峰值 9/12/15/5/6/10，cold 根任务仍为 5；cold queue 峰值 146/120/144/148/134/133，缓存探测命中 7,262、未命中 7,840，Owner eviction 为零。因此减少预读确有局部耗时证据，但冷状态积压与事务工作仍未解决。

清理 settled=true、forcedKillCount=0；exitFailureCount=14，包括 12 个 loader 和两个 Gateway。两个 Gateway 的 terminationRequested 均为 true，其中 Gateway 4 的安全日志明确为 `stage=gateway_connection_shutdown`、`error_code=drain_timeout`、`error_type=deadline`。Gateway 5 的非零退出原因尚未通过安全日志定位，不能推定为同一异常或源码崩溃。PG24532 已正常停止并验证无响应。这轮既没有完整容量报告，也没有正常退出的全体服务证明，目标仍未完成。

## 普通单聊 Owner SQL 合并（2026-10-06）

范围：当前版本化权限快照的普通单聊 Owner cohort。保留旧授权 attempt、复杂内容、群聊、历史拒绝与关闭恢复的兼容路径；不修改协议或数据库 schema。账号/关系权限沿用准备阶段不可变内存事实，事务保留房间状态、成员、禁言、顺序、所有权和幂等的一致性职责。依赖回复状态的规则仍结合房间事实判定。

### 实现

- `V2DurableOwnerPreparedRead` 在既有 operation/activation 围栏完成后，用一条 READ COMMITTED 语句返回最终回执与房间预检。房间预检复用同一语句的已完成/关闭操作集合，避免再次查询完成表；不同请求序号通过显式映射关联，完整键重复时保留原路径。
- 单聊成员完整性检查并入上述预检。仅此受控路径跳过消息持久化前的额外成员查询；其他调用保留原检查。
- `V2DurableOwnerCombinedWrite` 从同一份业务追加结果生成完整身份和指纹绑定的协议回执。消息、领域完成事实、协议回执在同一条数据修改 CTE 中写入，并检查各集合完整行数；回执 INSERT 由实际 message/completion RETURNING 驱动。
- 唯一键冲突保持严格 INSERT 与整笔回滚，不使用 `ON CONFLICT DO NOTHING` 掩盖部分写入；可恢复的 operation receipt 唯一键加入既有精确冲突识别。未知 COMMIT 仍原样返回，不能拆批后重新执行。
- 准备阶段已读取并验证的永久回执可以直接返回，包括指纹冲突结果。混合 Owner 批次先取出纯回放 handle，再执行未完成 handle，保持响应原顺序；纯回放不获取写连接、不重新获取权限、不消费新额度。
- 无 legacy attempt 的快照查询不生成 attempt/owner SQL 分支。历史领域完成、拒绝和关闭集合仍保留，防止旧消息重新追加。
- 保留同房间 FIFO、现有数据库节点聚合批次与等待边界；没有新增全局串行队列。本次不修复此前记录的 `V2HostRoomReceiptBatcher` 查询跨房间等待问题，不能宣称整个系统所有房间完全独立。

### 计时边界

普通合并路径的 `owner_preflight` 包含最终幂等读取和成员完整性检查；`owner_message_persistence` 包含消息、完成事实及协议回执。对应单独的 `owner_receipt_read` / `owner_receipt_persistence` 不再执行。旧路径仍记录原阶段，因此不能将新旧子阶段均值直接同比或将父子阶段相加。

### 验证

最终日志 `/tmp/imv2-owner-merge-tests-r4.log`：10 项测试（含参数化场景）、1 个 suite，通过，36.992 秒。

新增/增强验证包括：真实 PostgreSQL statement trigger 证明 messages/completions/operation receipts 在同一条 INSERT 语句图中；旧准备结果遇到已经提交的同一消息正确回放；两个并发准备请求只写一条消息；已完成回放不增加 Owner body 计数；同 ID 不同内容保留冲突；回执写入故障使消息、完成事实、回执和房间序号整笔回滚，移除故障后重试成功。也执行了旧 Owner 权限失效、COMMIT 结果未知、锁序、成员完整性及修改期间独立房间的相关回归。

扩大检查发现四项既有测试失败，均在恢复改造前六个 Owner 源文件后复现：

- `durableSendBatchIsolatesContentFailure`：持久预扣额度实际 10，旧断言期望 3。
- `durableSendBatchContentFailureRecovery`：额度拒绝下的恢复结果与旧断言不符。
- `durableSendBatchPropagatesSharedStoreFailure`：错误类型及回滚计数与旧断言不符。
- `permanentMessageSendReceipts`：direct 场景的限流 retry-after 断言不符。

基线日志 `/tmp/imv2-owner-merge-baseline-tests.log`、`/tmp/imv2-owner-merge-baseline-permanent-tests.log`。未修改这些断言或扩大本次工作为额度机制修复；不能宣称全部消息测试通过。初轮新 SQL 返回列引用错误已经修复，最终故障/并发测试通过。

Release Gateway 构建成功（226.51 秒，`/tmp/imv2-owner-merge-release.log`）。测试数据库已停止；同口径 R28 压测已结束。

R28 复测：Owner 正文观测均值 37.830 → 23.452 ms，降低 38.0%；整体仍约 20 秒失败，5/12 报告，同客户端 P95 增加约 10.6%–10.9%。连接获取、事务设置和提交阶段变长，不能宣称整体提速或容量通过。详细见 [R28 性能记录](performance-policy-versioned-snapshot-10000-online-1000msg-20261006.md)。清理时两个 Gateway SIGKILL 退出，来源未确定；所有压测服务已结束，PostgreSQL 已停止。

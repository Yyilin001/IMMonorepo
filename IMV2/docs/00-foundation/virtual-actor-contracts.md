# Room Virtual Actor 公共契约草案

本文是[并行实施方案](virtual-actor-parallel-plan.md)的 C0 输入，尚未成为当前已实现合同。C0 将这些语义转换为可编译类型、测试替身与固定提交；领域业务语义继续服从[既有合同](../../../docs/reviews/README.md)。下列 API 名称为拟新增名称，不表示仓库已经提供。

## 1. 身份、端口与数据流

| 类型/能力 | 固定语义 | 禁止事项 |
| --- | --- | --- |
| `RoomID` | 全生命周期稳定，沿用既有房间 ID 表示和序列化 | 使用房间名、节点地址或 ActorID 作为恢复键 |
| `RoomDataOwner` | 持久 shard 身份及 ownerEpoch；由现有 control 目录解析 | hash ring 改变数据 owner |
| `HostIncarnationID` | 每次进程启动唯一，host 地址复用也必须变化 | 重启沿用旧 incarnation |
| `ActivationToken` | roomID、ownerEpoch、activationEpoch、hostIncarnationID 的完整值；epoch 单调递增 | 只比较 host 或 ownerEpoch；回收时删除计数使其归零 |
| `RoomDirectory` / `RoomRef` | 前者创建仅含逻辑身份的引用；后者提供类型化业务 API和重定位 | 向领域调用方暴露 DistributedCluster ActorID、物理 store 或节点刷新 |
| `RoomActivationLeaseStore` | locate/acquire/renew/release；每个结果明确 token、租约截止和定位信息 | 把本地缓存或 Receptionist 列表当租约事实 |
| `RoomActivationFactory` / `RoomExecutor` | 用有效执行上下文恢复小型状态、执行 turn、刷新/失效缓存、关闭本地任务 | 恢复过程中发布可写实例；把 DB connection 跨 RPC 传递 |
| `RoomExecutionContext` | runtime 产生的有效 room/token/可信调用/turn 上下文，本地消费；不可由业务请求自行构造写入资格 | Gateway 自行指定 activationEpoch；任意请求伪造 trusted principal |
| `RoomHostTransport` | 类型化 resolve/activate/invoke/query/reserve 能力，R3 实现；测试可替换 | 通用字符串反射方法或任意类型载荷 |

`RoomRef` 的使用外观如下，仅展示业务边界，不是可复制编译的实现：

```swift
let room = rooms.room(roomID)
let outcome = try await room.send(request)
let events = try await room.readEvents(query)
```

契约层使用明确的 Codable、Sendable wire DTO 和稳定协议版本。请求包含逻辑房间、稳定业务 operation ID（有幂等要求的方法）、payload identity、经验证的调用主体、trace ID 和有界剩余执行预算。跨节点传剩余预算，不能依赖各进程单调时钟相同。物理目标 token 由运行时添加。

Runtime 的底层 RoomRef 只收发 Contracts DTO；保留既有请求/结果类型的 typed façade、RoomRef extension 与 mapper 放在 IMV2Server，由对应领域包实现，不能反向让 Runtime 依赖 Server。wire 层使用明确的 command/query/result 枚举及错误 envelope。C0 冻结所有领域 case 与 mapper 归属，领域代理不能独立增加互不兼容的签名。现有 `V2AuthenticatedSendMessage` / `V2SendMessageOutcome` 等只有 Sendable 的类型需要显式映射，不应为方便序列化把内部依赖暴露出去。

至少需要以下能力组：消息 send/edit/withdraw/reaction；成员/角色/公告/置顶/moderation/群昵称；已读 record/readers；room-log/member/role-baseline/state/latest-visible/batch-query；creation finalize；invitation/approval；forward source authorization/export/target accept/import；media visibility；trusted moderation、retention 与 room housekeeping。C0 从[业务台账](virtual-actor-task-cards.md#业务迁移台账)逐项映射到已有 service 方法和 DTO。

远端和本地快路径必须执行相同授权流程。节点通信要求认证、加密和允许的服务身份；加入集群不自动获得任意用户或 trusted moderation 能力。P0 验证固定 transport 版本的实现钩子，C0 冻结身份绑定与 principal 验证端口；无法实现时不能将未认证 RPC 作为可交付方案。用户、设备、成员、角色、control policy 的业务授权仍在现有持久边界核验。

## 2. 定位与激活

解析顺序固定为：

1. 由 roomID 查数据 owner，得到实际 PostgreSQL 归属及 ownerEpoch。
2. 在该实际库读取当前有效 activation lease。有效时访问该 host，不能因 ring 变化抢占。
3. 没有有效租约时，由健康 host 集合选择具备该数据 owner 访问能力且有容量的候选 host；候选在数据库竞争 acquire。
4. 同 host 对同一逻辑房间做 single-flight；跨 host 由数据库锁/CAS 决胜。失败者读取胜者并重新定位。
5. 胜者恢复状态并持续续租；发布 ready 前再次核验 token。恢复失败则清理半初始化实例，条件释放或等待到期。

成功定位可以缓存，但缓存有容量、代次和失效规则。旧响应不能覆盖更新 epoch；旧清理不能删除新实例。缓存命中仍不能免除写事务 fence。有效 lease 的 host 暂不可达时，返回有界 unavailable 或等待；不能单凭 RPC 超时宣布其失去写权。

不存在的房间返回 not-found。创建由 Creation Coordinator 用持久 request/manifest 先确定稳定 roomID，再按既有创建协议完成数据与目录；完成后进入普通激活流程。不能让任意 `resolve` 隐式创建空房间。

## 3. 数据库 lease 与事务 fencing

R1 可以复用现有 rooms 行锁作为序列化点，新增持久 activation 行/字段保存递增计数、当前 host/token、lease 截止等。C0/R1 固定唯一 SQL 结构与锁顺序，所有 acquire/renew/release/写事务遵守同一顺序。多房间先按 RoomID 规范全序，再按每房间固定表顺序锁定。

| 操作 | 必须成立 |
| --- | --- |
| Acquire | 有效旧租约不可抢；无有效租约时在事务内递增 epoch，授予新 token；竞争只允许一个胜者 |
| Renew | 完整 token 匹配且拿锁后仍未过期；使用数据库当前实际时间；过期后即使旧 host 返回也只能 acquire 新 epoch |
| Release | 完整 token 匹配的条件更新；保留 epoch 历史；迟到 release 不影响新实例 |
| Business write | 在实际业务事务内取得全部必要 fence 锁后，校验 ownerEpoch + activation token + 此时租约有效性，并持锁至 commit/rollback |
| Same-store multi-room write | 同一事务、规范锁顺序核验涉及的全部房间 token；源授权和目标接受保持已有原子范围 |
| Shared batch | 保留每个 room turn 的 token/ordinal；沿用 send 整批回滚与 read-receipt 逐行结果各自合同 |

时间校验必须在取得全部必要 fence 锁之后取数据库当前实际时间；不能使用等待锁之前捕获的时间，也不能用 PostgreSQL 固定于事务开始的时间代替。acquire/renew/write 均覆盖锁等待跨过 lease expiry 的测试。

**接管承诺：新 epoch 的 acquire 事务提交后，旧 epoch 不能再提交房间写。** 如果旧事务先在有效租约期间取得 fence 行锁并开始持久执行，它可以先结束，新 acquire 等待其完成。租约过期本身不撤销数据库中正在持锁的事务；因此需配置锁等待/事务执行上限，故障恢复时间包含其影响。

只扩展 `V2RoomOwnerTransactionFence.swift` 不够：发送 fast append/合批、转发 SQL、trusted moderation、retention、后台 import 等所有写路径均需台账证明。对 production writer 隐藏无 context 的裸 store API。RoomExecutionContext 是调用约束，数据库 fence 才是最终安全边界。

**消息写入资源由实际数据库连接调度。** 房间 Actor 保持同房间执行顺序，节点调度器分配实际写连接，每个房间独立事务提交。旧的房间、分片 command-credit 池及跨连接 refill 已移除，不再作为消息发送路径的执行边界。

Room credit 预留事务也校验当前 activation，内存额度与该 token 绑定，旧 activation 的余量不可转交新实例。共享 shard pool 仍是节点级容量池，分配给命令的额度具有独立身份/代次，不能代替房间写资格；完成、回滚和重复释放保持原有单次消费语义。失租/崩溃可以保守丢弃未消费的预留，不能重复返还或凭内存余额绕过持久上限。C0/R1/D1 联合冻结锁/事务图，测试 warm refill、接管与回滚，记录丢弃额度对窗口容量的影响。

schema 采用当前全新建库合同，R1 同步更新 canonical schema、readiness、schema contract 和 bootstrap 漂移测试，不另建历史迁移链。开发重建仅限明确可丢弃的环境。

## 4. 生命周期、并发与回收

状态：`absent → acquiring → restoring → ready → draining → stopped`；失租或持久结果不明时进入 `uncertain`，不接受新业务命令。失败路径必须有有界清理与重新激活出口。

Swift actor 的隔离不等于一个异步方法跨 await 不重入，也不保证调用抵达顺序。R2 显式维护 admission 顺序、单个消费者和 RoomTurn 状态；跨 await 后只按当前 token/turn identity 更新状态。

| 阶段 | 行为 |
| --- | --- |
| acquiring/restoring | 可共享有界等待任务；一个调用者取消不取消其他调用者的激活。恢复期间维持租约，容量计数不可丢失 |
| ready | 原子接收入队并分配 ordinal，最多一个未决 turn；执行与完成路径均检查代次 |
| draining | 原子关闭 admission，拒绝/重新定位新请求；保持租约直到已接受命令、reservation 和共享 batcher 的本房间工作结束 |
| stopped | 终止实例任务，条件释放 lease，按 token 解除注册；迟到回调不得复活该对象或删除替代实例 |
| uncertain | 停止 admission；用持久 operation 结果核对或退休旧 activation，在新 epoch 恢复；不能用内存猜测成功/失败 |

回收判定同时考虑最后业务活动、队列、在途 turn、恢复/维护任务、reservation 与有效订阅兴趣。不能只依赖引用变弱或最近一次 resolve 时间。订阅兴趣必须有断线/到期释放机制，避免永久 pin。回收前关闭 admission 与新请求竞争要原子化；回收后订阅由 Gateway 重新建立并按 durable cursor 补拉。

租约续租和生命周期控制不排在普通业务 FIFO 后面。它们有独立且有界的任务、数据库连接预算与关闭责任；不能因一个慢 turn 永久饥饿。恢复失败、超时和取消不得泄漏 task、continuation、队列许可或连接。

## 5. FIFO、微批与批量读取

RoomTurn 是顺序单元。队首连续兼容的 send 可形成同房间微批，限制命令数、总字节和最长等待。membership、edit/moderation 等不兼容操作以及 reservation 是屏障，不能跨越。兼容性继续由既有持久 SQL 条件核验，内存分类只作建议。

共享数据库 batcher 可以把多个房间的 turn 合为一次集合事务，但保留每个房间切片、输入 ordinal、不可变 ID/时间及现有锁顺序。同房间不得同时提交两个切片。只设置一个端到端等批预算，不能 RoomActor 等满一轮后数据库 batcher 再独立等待一轮。

Batcher 明确返回事务级“确定提交 / 确定回滚 / 提交未知”。共享写事务结果未知时通知该事务全部参与 turn，所有相关 activation 停止后续执行，核对持久结果或换 epoch 恢复，不能只封闭发起调用的一间房。逐行独立事务只传播到对应未决事务，不扩大到已确定完成的项目。

查询首期经同一个逻辑运行时取得对应 read turn，确保不读取未决内存状态；历史数据和授权仍从现有权威存储读取。`rooms.queryBatch` 按 host/物理库有界分组：每个房间获取 read turn，host 级 query batcher 在同一物理库做集合查询，再按房间分发结果。每个 read turn 独立，不用同时锁住整个房间集合。batcher 只聚合已经获得 turn 的项目，按有界等待独立 flush，完成即释放 turn，绝不等待同一 queryBatch 的其余房间取得 turn，以免与多房间 reservation 形成等待环。cold room 通过有界激活路径处理，批量恢复读取也按物理库聚合；不能无界启动 Actor 或退化为调用方 N 次串行 RPC。

批量结果保持既有逐房间错误/缺失/无权语义；一个 owner 不可用不能伪装为空列表，也不能无故丢弃其他 owner 的成功结果。分页 cursor、读取后授权重检、成员 revision、媒体快照比较和用户隐私过滤继续保留。性能 gate 检测 RPC/SQL 放大及冷查询激活成本；超预算需优化批量路径，不能绕开业务授权通过。

## 6. 多房间 reservation 与协调器

同物理库前台转发的原子单位沿用基线：一次 source-target 接受；多个 target 可以分别成功/失败。协调器每次只保留去重后的 source/target 两个房间 reservation，同一房间只取一次。保留既有目标并发上限与逐项结果。

1. 协调器在普通 RoomTurn 之外，按 RoomID 规范顺序申请 reservation。获取过程、等待者和时间预算都有界；失败时释放已明确安全的 reservation。
2. 每个 reservation 是队列屏障，带请求 ID、token 和独立 reservation identity。获取成功后该房间无未决普通 turn，后续 turn 等待。
3. 在同一个实际数据库事务核验双方 token、源授权与目标接受。不同物理库继续既有 export/inbox/receipt 协议，不伪装成原子事务。
4. 得到确定提交结果后，先更新或失效两端驻留状态，再释放 reservation。主实例只接受匹配代次/identity 的完成通知。
5. 明确尚未 dispatch SQL 时可以安全 abort。SQL 结果未知、协调器失联或 reservation 超过预算时，不得简单到期释放并继续同 epoch 服务：参与实例进入 uncertain，退休旧 activation，并在数据库 fence 之后以新 epoch 恢复和核对原 operation ID。

最后一步允许用重建代替新增分布式事务日志。若将来要求同 epoch 快速解锁，需要额外持久 reservation nonce/fence；首期不引入。换 epoch 必须经过 R1 的锁与 acquire 规则，不能单靠本地标记宣布旧事务失效。单个实例确认旧操作尚未提交也不足以替代其他参与者的结果核对。

转发资格覆盖整个 pair 的持久操作，而不只覆盖最终接受：基线 `replayedResults` 是批量读后修复 `message_forward_operations` 的 writer，`clientMessageID` 和 `markResult` 也写表。D5 将批量 replay 拆成纯观察和逐 pair 的持久修复，或有界逐 pair 恢复；上述写入均取得对应 reservation 和事务 fence。已完成 pair 的历史结果即使来源后来被编辑、撤回或不可见仍按既有幂等合同返回，不能通过重新鉴权改写已经成立的成功结果。

普通 RoomActor 不能持有 turn 调用另一个 RoomActor 并等待。涉及创建、全局邀请配额或跨库转发的协调流程具有独立持久 operation/intent，由 D4/D5 负责；不把数据库未知提交包装成通用自动重试。

## 7. 错误、取消与重试

| 类别 | RoomRef 行为 | 业务结果 |
| --- | --- | --- |
| 明确未接受：stale target / not ready / retired | 在总预算与次数上限内刷新定位 | 不产生新业务 operation ID |
| 队列/激活过载 | 返回明确 retryable overload，可给有限 retry-after | 不转移到无限等待队列 |
| 业务拒绝：无权、不存在、版本冲突、payload conflict | 原语义返回 | 不盲目重试 |
| 已派发后超时、连接丢失、提交结果未知 | 标记 outcome unknown；有持久幂等合同的方法才以原 ID 重发或查结果 | 不能推断未提交，不承诺 exactly-once transport |
| 租约/fence 失败 | 封闭失效实例；确定未执行才自动重新定位 | 已开始执行的请求须区分 rollback 确定性与未知提交 |
| Caller cancel | 未入队/排队中可取消；执行开始后回收调用者等待，不假定撤销数据库效果 | 保留可查询 operation 身份 |

同 operation ID、不同 payload 必须冲突。幂等结果和保留窗口沿用既有表与压缩合同；RoomActor 不缓存跨越清理窗口的永久结果。C0 的方法清单逐项标记 retry class；不能一个 `retryAll` 包装所有 command/query。

未知 write 结果期间暂停可能依赖该结果的后续 turn；核对持久结果或在 fence 后重建再恢复服务。超时、释放 reservation 和本地 cancellation 不能掩盖仍可能提交的 SQL。

## 8. 容量、配置与指标

C0 冻结下列配置字段、单位、有限默认值、有效范围与派生关系；具体数值根据既有连接预算和 W0 基线确定，在此不虚构实测值。启动校验不接受零/无穷上限或相互矛盾的时限。

| 预算组 | 必须有的上限 |
| --- | --- |
| Admission | 每房间待处理数/字节、每节点总待处理数/字节、单请求 wire bytes |
| Activation | 驻留实体数、并发恢复数、single-flight 等待者数、解析并发与缓存容量 |
| Execution | turn 命令数/字节/等待预算、数据库在途数、SQL/锁等待时间、重试总预算 |
| Coordination | 在途 reservation 数、等待时间、单次参与房间数（首期最多 2）、目标并发 |
| Lease/lifecycle | lease 时长、renew 周期与预留裕量、idle 时长、drain 截止、订阅兴趣到期 |

接管时长包含 lease 到期、数据库锁等待和恢复，不能直接等于 lease TTL。进程时钟不参与租约权威判断；测试使用可控时钟模拟调度并用真实 DB 时钟验证 fence。

指标至少覆盖 activation 数与耗时/失败、queue 深度/字节/等待、turn 和 batch 大小、lease renew/fence failure、resolve/redirect/retry、outcome unknown、passivation/drain、reservation wait、恢复峰值。Prometheus 标签使用有限类别/角色，不使用 roomID、requestID 或 activationEpoch 等高基数值；这些身份放结构化日志/trace，且不记录凭据和消息正文。

## 9. Vapor 5 与资源生命期

沿用 [Vapor 5 迁移](vapor5-migration.md)的资源所有权。启动顺序为数据库资源与 schema readiness → runtime/cluster readiness → 必需后台工作器 → HTTP/Gateway admission。启动部分失败按已取得资源的逆序清理；不得每次激活建立一套连接池或 EventLoopGroup。

正常关闭先停止新 HTTP/Gateway/worker 输入，再封闭 activation admission，在保持租约的情况下排空已接受命令、reservation 和共享 batcher，终止实例任务、条件释放租约、关闭 cluster/其余工作器，最后关闭数据库与 EventLoop。Vapor 请求和响应流必须先结束；数据库不能在活事务下面被销毁。

排空超过预算遵守已有失败退出策略，记录未决 operation 和结果未知状态；不提前宣告所有命令成功或在事务仍执行时交出可被误用的旧资格。只有一个资源 owner 负责关闭共享 EventLoop/数据库；`V2DatabaseResources.shutdown()` 的幂等语义继续保留。

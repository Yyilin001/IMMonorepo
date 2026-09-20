# 消息投影整数边界与后续审计

日期：2026-09-19。对应 B01；基于当前工作区的 schema 39、协议 30，不修改版本或数据库结构。
本批修复消息投影状态的构造、解码、恢复和存储读取边界，B01 整体仍开放。

## 当前范围核对（后续更新）

此表以当前 `GRDBV2LocalSyncStore` 的转换/聚合/排序调用链为本轮范围，不把文本搜索结果当作全仓完整性证明。
历史段落的“本批”及 schema 39 指原批次；当前仓库 schema 为 42，协议为 30。

| 范围 | 当前结论 | 证据或后续动作 |
| --- | --- | --- |
| 消息接受、编辑、撤回、效果收据及墓碑 | 已补本轮发现的直接修订读取 | 消息效果与墓碑专项；完整替换经既有投影解码检查 |
| 个人资料、私聊身份、失效通知 | 已补六处版本读取及失效记录合并/清理 | 资料存储专项 16 个异常场景 |
| 成员来源历史及成员入口 | 增量历史聚合、重复比较、本人资格与群资料比较，以及授权群快照两侧成员历史检查已补 | 成员历史 8、入口 4、快照 12 个异常场景 |
| 消息反应、公告与角色权限增量事件 | 已补已识别的序号/修订比较 | 反应 6 场景、公告/角色权限 18 场景 |
| 搜索、快照导入与重置游标 | 已补已识别的类型读取与范围检查 | 搜索 14、快照导入 48、重置 10 个异常场景；不等于快照全部 SQL 复制已核对 |
| `pinShouldReplace` / `applyPinnedMessage` / `preservePinnedMessagesInSnapshot` | 已补可选来源序号实际类型检查及快照候选收据检查 | 12 个 REAL 场景覆盖增量与快照两侧；既有 NULL 来源补齐回归通过 |
| `preserveRolePoliciesInSnapshot` | 已补 live/shadow 修订、可选序号及两侧全局版本检查 | 六字段 × 三种版本关系 × 两种 REAL，共 36 场景；失败回滚及修复后切换通过 |
| `roomReadWatermarks` / `applyOwnReadWatermark` | 已补聚合前全部候选类型检查，以及旧水位更新前检查 | 已提交、pending、acknowledged 与更新四路径 × 两种 REAL，共 8 场景；未知房间与空请求语义保留 |
| `decodeModerationProjection` | 已改为先验证实际正 integer，再转 UInt64 | 公开 moderationActions 两个 REAL 用例及修复后读取通过 |
| `applyRolePolicy` 全局版本 | 已在收据和版本排序前检查实际正 integer | 较新/重复/迟到 × 两种 REAL，共 6 个新增场景 |
| `roomAppliedRoomSequence` | 已补八来源原始值检查及精确聚合结果读取 | 16 个异常场景及空/NULL/零/最大值通过；后续稀疏异常索引与序号索引消除候选扫描，本机三档测量通过 |
| `completeRolePolicyBaseline` 全局版本与角色观察 | 已在写入/排序前验证全局修订及角色修订/可选序号 | 三字段 × 相同/较新基线 × 两种 REAL，共 12 场景，待办保留和修复后重试通过 |
| `GRDBV2RoomUnreadSnapshot.roomUnreadSnapshot` | 已补六个状态字段、成员资格过滤前版本和独立水位聚合检查 | 十位置 × 两种 REAL，20 场景；空/缺失水位、撤权及账号隔离回归通过 |
| `advanceForwardPlan` | 本次源码核对：同一 Row 先经 decodeForwardMessagesPlan → validatedForwardChunkProgress 验证实际整数和计数范围 | 后续直接读取与 +1 受该检查约束；本次未改、未重跑转发专项 |
| `decodePendingGroupRoomCreation` 上传计数 | 本次源码核对：参数类型是 DatabaseValue，经 commandNonnegativeInteger 检查实际 integer | 不是先转 Int 的未保护读取；本次未改 |
| 公告/角色权限快照收据 | 已在保留版本筛选前验证相关 live 与 shadow 收据 | 两类 × 两侧 × 修订/来源序号 × 两种 REAL，共 16 场景 |
| 反应快照状态/收据整数 | 合并前检查两侧相关状态，保留前检查收据 | 8 个异常场景；另补新旧状态/撤回/来源冲突 11 场景，见[专项证据](verification-records.md#20260919-reaction-snapshot-order) |
| 权限基线快照资格筛选 | 已在成员资格比较前校验候选基线三个整数及两侧成员修订 | 五位置 × 两种 REAL，10 场景；准备失败保留原值、修复后恢复权限基线 |
| 房间事件/游标快照复制及公开游标读取 | 已校验授权保留范围内事件序号、应用游标、裁剪下界；两个 getter 改为 Row 精确整数读取 | 三字段 × 两种 REAL × 保留/移除，12 场景；关闭重开和移除隔离通过 |
| 消息快照复制及相关历史 | 已补两侧消息三个整数字段、相关撤回记录及效果收据的复制/比较前检查 | 新增两侧消息/撤回及 live 收据 18 场景，结果见下方专项记录 |
| 管理/控制/时间线快照复制 | 三类投影在冲突复制前检查两侧实际正 integer 序号 | 两种 REAL × 三类 × live/shadow/移除，共 18 场景；重开、丢弃和修复后激活通过 |
| 快照初始化/准备的本人成员状态 | 两阶段检查 membership_revision 为实际正 integer | 成员/移除 × begin/prepare × 两种 REAL，共 8 场景；回滚、重开和后续授予通过 |
| 设备私聊身份复制、联系人搜索派生 | 本轮源码核对：私聊身份表无整数修订/计数列；联系人搜索 rowid 为 SQLite 自有行号 | 未改此两路径；不是由文本搜索推断所有快照复制已完成审计 |
| 房间恢复页提交的游标与裁剪下界 | 两字段在事件应用和 SQL MAX 前检查实际非负 integer；缺口判断复用验证后的旧游标 | 两字段 × 两种 REAL × 空/有事件页，共 8 场景；修复重试、缺口置位和重复投递通过 |
| 快照会话摘要/列表重建 | 本轮源码核对：摘要排序的消息 room_sequence 已由前序检查保护；列表整数列为受 CHECK IN (0,1) 约束的布尔标记 | 未新增这两条派生查询的修复或独立容量声明 |
| latestVisibleIsCurrent 本地消息 MAX | 同一 SQL 查询先检查该房间非法序号，再求最大值，错误阻止摘要提交与待办完成 | 两种 REAL × 目标/无关房间，4 场景；小异常不会被合法较大序号掩盖 |
| 恢复待办整数与完成比较 | 统一检查 target_head、priority、last_served_order 及两个可空目录版本；完成删除前也检查应用游标 | 六操作 × 九异常值组合共 54 场景，另 4 个完成比较场景；保留请求与修复后继续通过 |
| 目录页缓存摘要资格比较 | 比较前校验缓存 personal_generation、owner_epoch、membership_revision | 三字段 × 两种 REAL，6 场景；整页回滚与修复后摘要复用通过 |
| 恢复扫描换号/绑定边界 | 身份变化时重建 scan 与调度计数；同身份保留 service_sequence | 用户/绑定/同身份 × 普通/最大计数，6 场景；新身份从 0 开始且可继续调度 |
| 其他快照与派生 SQL | 完整普通表/派生查询映射仍开放 | 已识别路径通过不代替剩余入口核对 |
| Core 帧长度及已识别算术边界 | 帧配置拒绝超出 UInt32 和帧头加法可表达范围；核对预算/发送/指纹与版本转换前置条件 | 40 项、10 套件通过；不等同全部 Core/Server 调用链完成 |
| Gateway 帧配置与重试时间边界 | 环境配置经过 V2FrameLimits；时间窗口使用精确转换及 PostgreSQL 截止点检查 | 40 项、3 套件通过，新增配置层 6 个边界值；未运行数据库工作器整链 |
| 其他 ClientKit 文件、Core/Server/App 转换及 SQL 运算 | B01 全范围映射仍未完成 | 既有批次证据保留；按调用链逐项补充，不由本文件的搜索结果推断关闭 |

## 本批修复

`V2MessageProjectionState` 的消息修订、房间接受序号和时间线序号统一限制为 `1...Int64.max`。
构造接受消息、JSON 解码和恢复修订都经过同一初始化校验；不会把超界数值截断或钳制为最大值。

编辑和撤回允许从最大值减一推进到最大值；最大值本身仍可编码、解码和读取，但不能继续递增。
`V2StoredMessageProjectionState.state` 在将存储修订转换成 UInt64 之前检查正值，负数和零返回
`corruptPersistence`，不再可能在有符号转换处终止进程。

## 实际验证

- 修复前新增两项测试：JSON 的三个字段各含五个边界值，恢复含两个超界值；共有八个
  “应抛错却未抛错”的失败，见 `/tmp/imv2-b01-projection-before.log`。
- 修复后 `V2MessageProjectionStateTests`、`V2SnapshotResponseBoundsTests`、
  `V2PreparedGroupResponseBoundsTests` 共 16 项 / 3 套件通过，见 `/tmp/imv2-b01-projection-after.log`。
- 覆盖零、最大值减一、最大值、最大值加一、UInt64.max，以及存储负修订；
  保留原消息编辑、撤回、不可变信封、时间戳与序列化回归。
- 本批为纯状态及响应边界测试，没有运行真实 PostgreSQL、客户端或全仓测试。
  快照响应 DTO 通过不代表快照构建 worker 的累计计数已通过。

## 入口核对与仍开放范围

| 入口 | 本轮结论 | 证据范围 |
| --- | --- | --- |
| 消息投影构造/解码/恢复 | 已补持久化整数上限 | 本批专项 |
| 消息投影编辑/撤回 | 允许最后合法修订，拒绝继续递增 | 本批专项 |
| 存储投影 state getter | 先检查正修订再转换 UInt64 | 本批专项 |
| 用户状态事件 mirror / acknowledge | 已有正值及 Int64 上界检查 | 源码核对，未重跑这些测试 |
| 用户事件序号分配 | SQL 递增带 `< Int64.max` 条件，无返回行时回滚 | 源码核对，未重跑这些测试 |
| 用户事件重试 attempt | 先扩大到 bigint，再饱和到 Int32 最大值 | 源码核对，未重跑这些测试 |
| 群事件唤醒租约修订 | 从库读出检查正值，写入前检查 Int64 上界 | 源码核对，未重跑这些测试 |
| 快照构建累计计数 | canonical schema 限制为 4096 页、100 万条、256 MiB；有界单页追加不会发生整数溢出，超限安全结束并恢复设备重置状态 | 后续真实 PostgreSQL 6 个边界场景与既有恢复专项通过 |
| Core 发送 reducer | 首次接受只允许 `1...Int64.max`，最后合法序号可用；耗尽后旧操作仍先重放，业务输入冲突仍被识别 | 后续 Core 14 项专项通过 |
| 私聊策略/快速追加缓存修订 | 持久化更新要求修订小于 Int64.max；缓存仅派生已通过数据库校验的转换，重复/迟到回调不再推进 | 调用链核对与两个缓存套件的最大值、重复回调专项通过 |
| Push、迁移保留清理与媒体会话重试 | 前两者计数饱和且保留租约隔离；媒体会话允许最后一次认领，耗尽后拒绝写入 | 本轮真实 PostgreSQL 24 个参数场景通过 |
| 持久任务退避 | 最大 Int 尝试次数仍返回有界延迟，不因瞬时失败暂停 | 本轮扩展并通过分类/退避套件 |
| SQL 事务重试延迟 | 当前所有生产调用均使用默认最多 2 次重试，乘法输入有界；不把任意非负配置视为已验证 | 源码调用点核对，未新增或重跑事务测试 |
| 房间恢复状态与通知目标 | Core 状态限制 Int64 上界；SQLite 拒绝负状态；读取另校验真实 integer 存储，拒绝 CHECK 仍允许的 REAL 值 | 最大值/超界目标及真实 SQLite 非整数专项通过 |
| 房间恢复调度序号 | 读取要求非负 integer；最后合法值提交；非整数或耗尽返回 invalidWork，整笔重试事务回滚 | 真实 SQLite 专项通过；耗尽后不会继续推进调度 |
| 持久命令恢复 | 21 个必填/可选修订序号读取点统一检查 integer 类型，拒绝负值/REAL；NULL 可选结果保留 nil | 14 字段 × 5 整数及 × 2 REAL 的 Row 解码测试通过；相关 outbox 共 41 项回归通过 |
| 同步重置游标 | 负 base 拒绝；合法最大值保留，无穷过期时间拒绝 | 既有真实 SQLite 写入/关闭/重开专项本轮通过 |
| 客户端投影/同步整数读取 | 5 个投影、11 个同步类 Row 读取先检查 integer，再执行非负转换；保留各自错误类型 | 8 个新增 REAL 投影解码场景及相关同步/资料/群能力共 130 项通过 |
| 恢复成员资格与最新消息摘要 | 成员修订、摘要版本/计数、当前内容游标和最新投影序号统一精确读取；异常报错，不据此授权或删待办 | 真实 SQLite 成员场景、摘要 Row 解码与恢复回归通过 |
| 客户端命令重试计数 | 16 个存储重试入口统一使用 scheduleCommandRetry；精确非负整数读取后 addingReportingOverflow，再事务写入 | 生产调用点核对；消息重试整数/REAL 专项已在前批实际运行，不等同全部 16 条业务链重跑 |
| 本地键集分页加一 | 收藏、会话、关系分页限制 1...100；关系/会话窗口限制 1...500 且 precedingCount < limit | 源码核对，未重复运行业务分页测试 |
| 传播、内容审核、群唤醒、媒体扫描/清理 | Int64/Int32 上限处计数饱和；恢复与释放遵循租约、修订及错误分类 | 现有真实 PostgreSQL 四项测试、72 个参数场景本轮通过 |
| 角色权限恢复建立/比较/合并 | 房间成员修订与基线权限/成员修订必须为正 integer；基线房间序号允许零，拒绝 REAL | 8 个真实 SQLite 异常场景及正常恢复/权限投影共 19 项通过 |
| 尚未完成的入口映射 | 服务端其他派生入口、客户端非共享 outbox/持久化解码、分页响应转换的完整映射 | B01 继续开放；已核验入口不再笼统列为未处理 |

当前状态以[治理总表](status.md)为准；本批日志和源码摘要见
`/tmp/imv2-b01-projection-sources-20260919.json`，不把这些局部证据扩大为整个 B01 已关闭。


## 后续：快照约束核验与发送序号耗尽

最初只观察到了快照 worker 在限制检查前做加法，推测存在整数溢出；进一步核对 canonical schema 后，
该推测不成立：数据库约束已经同时限制计数下界和协议上界，单页大小也有界。
本轮没有为了制造失败而删除这些约束，也没有增加重复的快照算法分支。

`PostgresV2SnapshotCounterBoundsTests` 使用真实 PostgreSQL 验证三个计数各有“恰好达到上限”和
“已到上限、下一页被拒绝”两种场景。数据库拒绝负值、协议上界加一和 Int64.max；
失败时没有新增页面，构建租约释放，pending token 与重置记录删除，设备游标回到前一代 ready。
测试以合成的累计计数定位算术边界，不代表实际生成了百万条或 256 MiB 数据；既有分页续传、发布、
空账号及构建失败恢复另在同轮验证。三项测试 / 两套件通过，日志 `/tmp/imv2-b01-snapshot-counts.log`。

Core 的 `V2SendMessageReducer` 原先只在注释中要求调用方保证安全递增。本轮增加明确的
`invalidRoomSequence` 错误：新提交的序号为零或超出 Int64 上界时拒绝接受；最后一个合法序号仍可成功，
后继状态表示耗尽，原操作重放和输入冲突判定仍优先执行。接受逻辑与指纹共 14 项 / 两套件通过，
日志 `/tmp/imv2-b01-send-sequence.log`。这是共享 Core API 的修复，不声称生产 PostgreSQL 写库此前都缺少边界保护。

本轮未运行全仓套件；B01 仍开放，剩余范围为其他入口和缓存/worker 派生调用链的完整核对。
源码与日志摘要：`/tmp/imv2-b01-snapshot-sequence-sources-20260919.json`。

## 缓存提交顺序与后台计数证据

`PostgresV2RoomWriteStore` 的单条回复标记与批量回复标记更新均带
`direct_policy_revision < Int64.max` 条件，未成功更新时不派生缓存修订。
两类缓存的对端更新都要求预期旧修订一致且尚未回复；推进到最大值后，旧回调和携带新修订的重复回调
均保持整个条目不变。这里验证生产调用链的前置条件，不声称内部 Entry 可以接受任意伪造的提交回调。

`V2DirectSendPolicyCacheTests` 与 `V2DirectRoomLogFastAppendCacheTests` 新增最大值减一的参数，
保留普通修订、字段保持、旧回调、重复回调断言。`V2DurableWorkFailureClassificationTests`
增加 Int32.max、Int.max - 1、Int.max 的尝试次数，验证瞬时错误始终重试且延迟不超过配置上限。

与现有 `pushWakeRetryCounterBoundary`、`migrationRetentionRetryCounterBoundary`、
`mediaSessionRetryCounterBoundary` 同轮运行，共 16 项 / 4 套件通过，耗时 17.941 秒。
其中真实 PostgreSQL 分别有 6、6、12 个参数场景。日志 `/tmp/imv2-b01-cache-worker-boundaries.log`；
详细范围见[验证记录](verification-records.md#20260919-cache-worker-integer-bounds)。
本批仅扩展测试和校正证据，没有修改已具备保护的生产算法；B01 继续开放。

## 客户端恢复整数证据

新增 `V2RoomRecoveryIntegerBoundsTests`，验证恢复调度序号从 Int64.max - 1 推进到最大值，
下一次重试拒绝且回滚先前对 next_attempt_at 的写入；待办标识与旧重试时间保留。
这是明确的耗尽错误行为，不声称达到上限后调度仍能继续。

同时验证完整房间状态各字段的最大合法值写入/读回、数据库对六个负状态字段的约束，
以及两个超界通知目标拒绝后待办不变。未关闭 SQLite 约束来构造不可能的负状态。
与持久恢复、投影恢复、重置游标和待执行命令恢复套件合跑，共 26 项 / 5 套件通过，0.430 秒。
日志 `/tmp/imv2-b01-client-recovery-integers.log`；新增两项使用真实 SQLite，旧 Row 解码参数用例
与旧关闭/重开用例分别按自身范围计证据。无生产代码变更，未运行全仓、App 或真机测试。

## 恢复表真实存储类型修复

后续核对 outbox 的 `commandAttemptCount` 精确类型检查时发现，前述非负 CHECK 不能保证
SQLite 实际存储类型为 integer。1.5 和 Double(Int64.max) 都可在不关闭约束的情况下写入
恢复表；不能把此前“负整数被拒绝”的结论扩大为任意存储类型都安全。

`GRDBV2RoomRecoveryWork` 现统一通过 `DatabaseValue.storage` 检查非负 int64，再读取
target_head、service_sequence 和房间状态的六个整数。异常返回 invalidWork，避免强制转换失败或
非精确读取；没有截断或覆盖异常原值，也没有修改 schema 或增加自动数据修复策略。

新增 5 个字段 × 2 种 REAL 值的真实 SQLite 场景，验证拒绝、原值及类型保留、重试时间不变，
并在显式修复测试数据后恢复正常读取。与恢复持久化、恢复引擎及两个 outbox 计数测试合跑，
48 项 / 4 套件通过，1.779 秒；日志 `/tmp/imv2-b01-recovery-storage-types.log`。
范围仅为上述入口，不将这次精确类型检查外推为所有 SQLite 表已经审计完成。

## 成员资格与摘要读取的精确整数检查

恢复调度之外，`readRecoveryMembershipFence`、`roomRecoveryMembershipAllows` 和
`latestVisibleIsCurrent` 原先仍直接读取 Int64。现在共用非负 int64 存储类型检查，
并覆盖摘要已有代次、状态版本、内容游标、MAX(room_sequence)、本地消息修订和摘要字段解码。
空的最新序号聚合仍返回零，保持原 SQL 聚合和原业务判定。

新增两种 REAL 成员修订的真实 SQLite 场景，检查状态读取、待办加载、unavailable 提交与摘要资格
全部报错且保留待办；另新增六个摘要字段 × 两种 REAL 的 Row 解码场景。
它们证明异常数据的拒绝边界，不代表生产正常写入会生成这些数据，也不声称自动修复损坏存储。
恢复整数、持久恢复与恢复引擎共 48 项 / 3 套件通过，1.783 秒；
日志 `/tmp/imv2-b01-recovery-authority-integers-after.log`。B01 仍开放。

## 共享命令重试与本地分页调用点

`GRDBV2LocalCommandStore` 的发送、成员、撤回、移除、禁言、移出成员、编辑、已读、表情、
会话偏好、收藏、群能力、转发、转发分块、社交、建群共 16 个重试存储入口，均调用
`GRDBV2CommandRetryCount.scheduleCommandRetry`。它先检查有限重试时间，读取非负 integer，
用 addingReportingOverflow 计算，再验证 Int64 可表示并在同一事务更新；异常不执行计数写入。
现有消息 outbox 的整数与 REAL 恢复专项在恢复存储类型批次中通过，其他业务入口本轮只核对调用关系。

本地 `favoritedMessages`、`conversationListPage`、`relationshipPage` 的 limit 限制为 1...100；
`relationshipWindow`、`conversationListWindow` 的 limit 限制为 1...500，precedingCount 小于 limit。
这些入口的 limit + 1 和窗口差值有明确前置上界，不作为待修复整数溢出。
这里只核对页大小计算，不把它外推为所有游标字段和响应解码都已完成。

## 其余后台任务计数专项

- `V2DirectRoomProfilePropagationWorker` 与 `V2ReadReceiptPreferencePropagationWorker`：24 场景，
  覆盖零/最大值减一/最大值、过期认领和失败恢复；检查接收方效果不重复。
- `V2ContentReviewWorker`：12 场景，检查 Int32 计数饱和、决策和暂停策略、旧租约隔离。
- `PostgresV2GroupEventWakeStore`：12 场景，含本地/路由两种入口，检查新修订保留与认领恢复。
- `PostgresV2MediaScanStore` / `PostgresV2MediaPurgeStore`：24 场景，含 pending/过期租约、成功/瞬时失败，
  检查 Int64 计数饱和、不误暂停、健康任务完成和延迟重试。

四项测试 / 一套件共 72 个参数场景通过，50.695 秒，日志 `/tmp/imv2-b01-remaining-worker-integers.log`。
沿用现有真实 PostgreSQL 专项，本批没有新增测试或改动生产计数逻辑。
群唤醒测试的历史展示名仍含 Hybrid，实际执行当前房间日志代码；不恢复旧投递模式。

## 角色权限恢复的存储边界

`enqueueRolePolicyRecovery`、`matchesRolePolicyRecoveryRequest` 与 `completeRolePolicyBaseline`
对房间成员修订和先前基线字段的直接 Int64 读取，统一改为先检查实际存储类型。
成员/权限修订必须为正 integer，房间序号为非负 integer；权限投影读取复用同一规则。
既有任务计数读取本身已限制 integer 与 Int32 上界，饱和重试算法无需改动。

新增四个字段 × 两种 REAL（1.5、Double(Int64.max)）的真实 SQLite 场景，未关闭约束。
无效房间修订不能建立/重置任务或推进失败计数；无效基线不能被读取为权限或被新结果覆盖。
失败后原请求及异常值保留；显式修复测试数据后相同待办可完成。不是自动数据修复功能。

恢复边界组 9 项通过（0.366 秒），正常持久恢复、权限投影和运行器补充组 10 项通过（0.278 秒）。
日志 `/tmp/imv2-b01-role-policy-storage.log`、`/tmp/imv2-b01-role-policy-regression.log`。
B01 仍开放，本轮未运行全仓、App 或真机测试。

## 待执行命令的修订与序号恢复

原 `commandStorageUnsigned(Int64)` 只能检查转换后的非负值；调用端先使用 Row 的 Int64 读取，
仍会在遇到不能精确表示的存储类型时失败。现提供必填/可选 Row 读取 helper，先检查
DatabaseValue.storage 为 int64，再沿用 UInt64 精确转换；只有可选字段的 NULL 返回 nil。

本轮替换 17 个可选、4 个必填读取点，涉及接受序号、编辑、撤回、移除、禁言、移出成员、
成员命令、表情和已读回执。没有把非法值钳制到零，没有修改合法零值及现有领域规则。

`V2PendingCommandRecoveryBoundsTests` 保留 14 字段 × 5 整数的原断言，新增同字段 × 2 REAL
（1.5 与 Double(Int64.max)）必须返回 commandConflict。它们是 Row 解码测试，并非数据库重开场景。
加上受影响 outbox 正常行为，共 41 项 / 10 套件通过，0.462 秒；
日志 `/tmp/imv2-b01-command-storage-types.log`。未运行全仓，B01 仍开放。

## 投影与同步 Row 转换

`projectionStorageUnsigned` 的五处 Row 读取和 `storageUnsigned` 的十一处 Row 读取改为先检查
DatabaseValue.storage。覆盖消息/时间线/修订/控制序号，快照 total_items/total_bytes，已读序号、
群公告、资料版本与失效版本、同步事件序号、房间成员修订及群能力命令的期望版本。
投影错误仍为 invalidMessagePayload，同步存储错误仍为 storageRangeExceeded；
合法整数范围和领域约束不变，不对异常值取整或补零。

新增消息/时间线/修订/控制序号 × 1.5/Double(Int64.max) 共 8 个 Row 解码场景。
因共享转换影响同步流程，本轮运行 V2SyncEngineTests 全套，以及投影边界、资料仓库与群能力响应专项，
共 130 项 / 4 套件通过，2.301 秒，日志 `/tmp/imv2-b01-projection-storage-types.log`。
这不是全仓、App 或设备验证；新增场景是 Row 解码而非数据库关闭/重开。

## 快照导入清单与进度的存储类型

`importedSnapshotManifest`、`matchesSnapshotImport`、`nextSnapshotPageIndex`、`applySnapshotPage`、
`prepareSnapshotActivation` 和 `activateAcknowledgedSnapshot` 的直接 Int64/Int 读取已改为
先检查 DatabaseValue.storage 为 int64。覆盖 generation、base_sequence、page_count、total_items、
total_bytes、next_page_index、applied_items、applied_bytes 八个字段。
原负值、页数和总量一致性检查保留；不取整、不钳制，也不自动修复损坏数据。
共享 `storageUnsigned(Row,column:)` 复用同一精确读取，再沿用非负判定。

新增 8 字段 × 2 REAL 值（1.5、Double(Int64.max)）× 导入/准备切换/确认切换三个阶段，
共 48 个真实 SQLite 场景，框架显示为 16 个参数场景、每个内部执行三个阶段。
除 next_page_index 注入需临时绕过页索引不超过总页数的 CHECK 外，其他字段不关闭约束。
验证所有相关入口拒绝、原 REAL 值/类型及游标保留；只恢复注入字段后，同一快照可继续应用与切换。
本批未增加数据库关闭/重开场景，不把它描述为进程恢复验收。

同步套件 124 项通过，3.600 秒，日志 `/tmp/imv2-b01-snapshot-storage-types-after.log`。
初轮日志为新增测试宏内缺少 try 的编译失败，修正测试后重跑；没有降低生产检查或断言。

本次搜索同时定位了后续审计入口：本地命令重复提交的期望修订/已读序号读取、
群发送能力与已读偏好读取、搜索索引版本与页定位、Push 意图版本读取。
这些是待核对调用前置条件与存储类型的入口，不以搜索命中直接判定全部有缺陷。
B01 仍开放，需把余下入口与边界用例逐项对应。

## Push 意图重开后的整数读取

`readPushIntent` 的 intent_revision、acknowledged_revision、attempt_count、expected_epoch、session_epoch
现先检查实际 SQLite integer 类型。必填字段不接受 NULL，可选 epoch 字段仅对 NULL 返回 nil；
原正值、确认版本顺序、Int32 重试计数上界和 claim/epoch 关系检查保持不变。
版本和 epoch 的数据库约束本已限制 integer；本次补恢复读取防护。
attempt_count 的既有 numeric CHECK 允许 1.5，因此此字段的分数场景无需绕过约束。

新增 5 字段 × 1.5/Double(Int64.max) 共 10 场景：注入异常后关闭并重开真实数据库，
读取、检查、重试和新 owner 激活都必须返回 invalidState；原值/类型、owner 和重试时间保持。
除 attempt_count=1.5 外，其余注入明确绕过 CHECK 来模拟异常存储，不声称正常业务写入可突破约束。
显式恢复测试字段后原意图完整一致，重试计数可继续增加。
本地 Push 与协调器两套件 14 项通过，1.275 秒，日志 `/tmp/imv2-b01-push-storage-types.log`。
这补齐上述五个 Push 入口的类型读取，不等同真实 APNs 或 B16/D02/D03 的设备生命周期验收。
命令重复提交、群能力/已读偏好及搜索索引的剩余读取入口仍需核对，B01 保持开放。

## 命令重复比较与已读合并水位

本地成员变更、撤回、编辑、已读回执的四个重复 operation 比较入口改用精确 integer 读取，
复用 commandConflict 错误与原业务比较；共享命令 Row helper 继续拒绝负值。
`enqueueIfReadReceiptAdvances` 的 MAX 聚合同时检查每个参与水位的序号为正 integer；
任一无效值令聚合返回 NULL，由读取 helper 拒绝，不能让较大的合法整数掩盖小数/负值/缺失结果。
空集合仍以 0 为水位，pending 使用请求序号、acknowledged 使用结果序号，原选择规则不变。

新增四类重复比较 × 两个 REAL 值，以及 pending/acknowledged 水位 × 两个 REAL 值，共 12 场景。
全部使用真实 SQLite 与正常 CHECK，不关闭约束。确认异常值不被覆盖、不插入新命令；
水位场景另放入合法序号 8，证明 1.5 不会被 MAX 掩盖。修复注入字段后重复提交仍幂等，
水位只允许序号 9 入队一次。没有改变 schema，也没有在生产中自动修复异常记录。

命令存储专项、既有命令恢复边界及四种 outbox 共 17 项 / 6 套件通过，0.171 秒；
日志 `/tmp/imv2-b01-command-duplicate-storage.log`。本批不是数据库重开测试，重启行为仅沿用相关 outbox 原有回归。
命令重复比较的上述入口已对应；B01 仍需完成群能力/已读偏好、搜索索引及其余入口范围核对。

## 私聊发送能力与已读可见性版本

本轮核对确认此前待审计的发送能力入口是 `directSendingCapability`，并非群权限入口。
它的 state_version 读取和持久化旧版本比较已改为实际 integer 类型检查。
私聊已读的 reader_preference_revision、viewer_preference_revision、read_through_room_sequence，
以及全局已读偏好的 preference_revision，同样先检查再比较；旧已读序号在判断新旧偏好前读取，
避免更新版本直接覆盖异常历史序号。版本/序号的既有非负规则、偏好正版本和可见零进度语义保留。

新增五字段 × 1.5/Double(Int64.max) 共 10 个真实 SQLite 场景，不关闭 CHECK。
新的同步批次不能覆盖异常值或推进游标；适用的公开读取接口也明确返回 storageRangeExceeded。
修复测试字段后重放同一批次，发送能力/偏好/已读进度按预期更新。
新专项、私聊已读可见性与同步引擎三套件共 127 项通过，3.679 秒；
日志 `/tmp/imv2-b01-social-storage-types.log`。未改 schema，未跑全仓、App 或真机。
B01 继续开放；搜索索引及其余恢复、比较入口仍需完成映射与核对。

## 搜索状态、任务和命中核验

`GRDBV2LocalMessageSearchIndex` 的索引状态观察/读取、generation、index_version、任务期望修订、
主库实际修订、重建文档的消息序号/修订、派生候选的序号/修订/代次以及命中主库复核，
现统一要求实际正 integer，再执行原代次/修订比较。LEFT JOIN 找不到主消息时仍以 NULL 表示缺失，
不将真实缺失误判为类型错误；SQLite 自身提供的 rowid 保留原读取。
此项检查针对进入解码/核验的记录，不宣称能发现被 SQL 条件排除的所有损坏记录。

新增七类位置 × 1.5/Double(Int64.max) 共 14 个真实 SQLite 场景，未关闭 CHECK。
索引状态的观察流和搜索读取都明确报错；待处理任务遇到异常主库修订/序号或任务修订时不删除任务；
命中候选的异常序号/修订也被拒绝。派生文档可由正常 rebuild 修复；主库记录只在测试显式修复后重试。
搜索与同步两套件 135 项通过，3.868 秒；日志 `/tmp/imv2-b01-search-storage-types.log`。
未改 schema、未跑全仓/App/真机。B01 仍开放。

后续搜索定位到的待审计项包括 reset 回滚游标、快照清理代次、成员/角色效果收据的重复比较，
以及资料、撤回/编辑等投影的内部版本比较。这些还需核对前置条件与对应测试，不以文本搜索直接作关闭或缺陷结论。

## 重置回滚游标与快照搜索状态复制

`cancelReset` 的回滚 generation/applied_sequence/server_acknowledged_sequence 改为检查 Row 的实际 integer 类型，
再构造恢复游标；异常发生在删除快照暂存/回滚记录和写回游标之前。
`prepareMessageSearchControlShadow` 对源 generation/index_version 做精确读取及正值检查，
沿用代次 Int64 上界防护；不允许 REAL 被复制或参与递增。

新增五字段 × 1.5/Double(Int64.max) 共 10 个真实 SQLite 场景。
只有回滚 acknowledged_sequence 注入需临时绕过它不超过 applied_sequence 的关系约束，其余保留 CHECK。
验证异常返回 storageRangeExceeded，游标不变、已导入页保留、activation_prepared 仍为 0、回滚记录仍在；
修复测试字段后取消重置恢复原代次/零进度，或完成原快照切换至序号 10。
同步与搜索两套件 136 项通过，3.957 秒；日志 `/tmp/imv2-b01-reset-fence-storage.log`。
没有新增数据库重开或进程中断场景，未改 schema、未跑全仓，B01 的其余投影内部比较与范围映射继续开放。

## 公告与角色权限效果的重复比较

公告与角色权限的历史收据 revision/可选 room_sequence、当前投影 revision/可选 room_sequence，
以及角色权限基线 permission_revision，现先检查实际正 integer。可选来源序号仅对 NULL 返回 nil，
保留未知来源元数据的语义；较新事件也必须先通过已有当前序号的类型检查，不能静默覆盖损坏记录。

新增九个读取位置 × 1.5/Double(Int64.max) 共 18 个真实 SQLite 场景，不关闭 CHECK。
收据比较场景显式移除旧 personal 同步事件 fixture、保留独立效果账本，以便相同源事实的新投递到达收据比较；
这属于受控测试构造，不宣称运行了同步日志实际裁剪任务。
异常时原字段/类型、同步游标和效果收据数量保持；针对基线或当前投影的失败也回滚本轮已插入的新收据。
恢复注入字段后同一事件可继续提交，重复事实不增加效果收据。
同步与成员恢复两套件 130 项通过，3.977 秒，日志 `/tmp/imv2-b01-effect-storage-types.log`。
未改 schema、未跑全仓/App/真机。成员效果历史聚合以及其他投影内部比较仍需审计，B01 未关闭。

## 成员效果历史的整数聚合

`applyMemberEffect` 的重复收据先检查 membership_revision、可选 room_sequence 及 projection_sequence 的实际正 integer，
重复源事实还须匹配原修订。最新版本聚合同时检查全部候选修订的类型和正值，避免较大的合法版本掩盖较小 REAL；
异常返回 invalidMessagePayload。写入角色时分别检查来源序号与投影序号，NULL 来源序号仍可回退到投影序号。

新增历史聚合及三个重复字段 × 1.5/Double(Int64.max) 共 8 个真实 SQLite 场景，保留正常 CHECK。
历史场景先保留合法版本 4，再污染版本 2 并投递版本 5，验证小数不能被较大版本掩盖；
重复场景只移除独立同步投递 fixture，保留成员效果账本，不代表执行了真实日志裁剪。
异常时游标、角色、历史记录数与异常原值保持；修复字段后重试原事件成功。
同步与成员恢复两套件 131 项通过，3.942 秒；日志 `/tmp/imv2-b01-member-storage-types.log`。
未改 schema、未跑全仓/App/真机，未新增快照或跨进程异常场景；其他投影内部比较及完整入口映射仍开放。

## 时间线、审核与群资料的版本比较

时间线提示重复比较的 timeline_sequence、禁言记录重复比较的 room_sequence、房间冻结状态排序的 room_sequence，
以及群资料比较的 membership_revision 改为经 storageInteger(Row,column:) 检查实际 integer 后参与比较。
不再让 REAL 小数被转换后当成已有序号，也不对超出 Int64 的 REAL 直接解码。

新增六条路径（四类重复投递、冻结状态与群资料的较新版本）× 1.5/Double(Int64.max)，共 12 个真实 SQLite 场景。
正常 CHECK 保持开启；重复投递只移除独立同步日志 fixture，以到达原投影的重复比较，不宣称执行了实际裁剪。
验证 storageRangeExceeded、游标/原始字段与 REAL 类型保留、新投递记录回滚；修复字段后同一批次成功，
重复事实保持序号 1，新状态推进到序号/修订 2。
同步、成员恢复与本专项共 132 项、3 套件通过，3.997 秒，日志 `/tmp/imv2-b01-room-projection-storage.log`。
未改 schema、未跑全仓/App/真机；私聊身份与个人资料版本、消息效果/墓碑等内部比较仍待完整核对，B01 未关闭。

## 消息效果、墓碑与旧式编辑的修订比较

消息效果收据重复比较、补回消息时的墓碑版本、重复墓碑比较、撤回时的当前消息版本、完整替换/旧式编辑的墓碑版本，
以及旧式编辑的当前版本，共七处改用 storageInteger(Row,column:) 读取实际 integer；REAL 返回 storageRangeExceeded。
原先已通过 decodeMessageProjection 读取的完整替换当前投影沿用既有精确检查，不重复实现。

新增七条路径 × 1.5/Double(Int64.max)，共 14 个真实 SQLite 场景，正常 CHECK 保持开启。
仅收据重复场景移除独立同步日志 fixture，保留消息效果账本；不宣称执行真实裁剪。
失败时游标、异常原值/类型、效果/投影/墓碑/搜索任务数量保持不变；修复字段后相同事件成功。
墓碑先到的消息补回、完整替换与旧式编辑迟到都保持撤回状态，不恢复正文；正常旧式编辑仍可推进文本。
同步与搜索两套件共 138 项通过，4.025 秒；日志 `/tmp/imv2-b01-message-effect-storage.log`。
未改 schema，未跑全仓/App/真机；个人资料、反应及其他尚未映射的入口仍需核对，B01 未关闭。

## 消息反应的来源序号与排序

`applyReaction` 的重复收据现检查实际正 integer room_sequence 并与输入效果的来源序号相等，
当前反应版本排序也经 effectInteger 检查；REAL 统一返回 invalidMessagePayload。
新增重复添加、较新移除、旧添加迟到三条路径 × 1.5/Double(Int64.max)，共 6 个 SQLite 异常场景，正常 CHECK 保持开启。
重复路径只移除独立同步投递 fixture，保留效果收据；不代表执行实际裁剪。
失败时游标、原字段/类型、效果收据数与反应可见状态保持；修复后原事件可重试，重复不新增收据，
较新移除删除反应、旧添加保留已移除状态。既有跨流、重开及快照回归同套件通过。
同步套件 128 项通过，3.833 秒；日志 `/tmp/imv2-b01-reaction-storage.log`。
未改 schema、未跑全仓/App/真机，也未新增快照损坏注入；个人资料及剩余入口映射仍开放，B01 未关闭。

## 资料缓存与失效记录的版本读取

私聊资料 revision、发现资料时缓存 revision/visibility_revision、完整资料保存时 revision/visibility_revision，
以及失效通知比较现有资料 revision，共六处改为 storageInteger(Row,column:) 检查实际 integer。
失效记录 minimum_revision 在通知合并与已满足清理前分别校验实际正 integer，避免 SQL MAX/比较静默覆盖或保留 REAL。
相关写入仍在原事务内，检查错误返回 storageRangeExceeded。

新增八个位置 × 1.5/Double(Int64.max)，共 16 个真实 SQLite 场景，正常 CHECK 保持开启。
先通过真实私聊资料/失效同步建立资料 1 与刷新要求 2，再注入异常，尝试资料 3 或隐藏通知 3。
失败时原字段/类型、游标、资料显示名、私聊投影及刷新记录数量保持；修复字段后原操作成功，
资料更新清除已满足要求，隐藏通知删除私聊投影并保留要求 3。
资料存储、资料仓储及同步三套件共 132 项通过，3.959 秒；日志 `/tmp/imv2-b01-profile-storage.log`。
未改 schema、未跑全仓/App/真机；未新增快照/进程中断异常场景，B01 的完整入口映射继续开放。

## 本人资格与他人成员变更的入口检查

`applyMembershipAwareRoomProjection` 在比较已有本人 membership_revision 前检查实际正 integer；
他人成员事件写入来源历史后，读取已有群资料版本也先检查实际正 integer，避免在 persist 的检查前提前返回。
两字段 × 1.5/Double(Int64.max) 共 4 个正常 CHECK 下的 SQLite 场景验证 invalidMessagePayload、
游标/原值/类型/成员效果数量不变；群资料检查失败会回滚刚插入的来源历史。修复字段后原批次成功。
同步与成员恢复两套件 134 项通过，4.079 秒；日志 `/tmp/imv2-b01-membership-entry-storage.log`。
未改 schema、未跑全仓或真机；本轮剩余范围见文首表，B01 未关闭。

## 有效已读水位聚合与更新

roomReadWatermarks 先确认每个候选 value 都是正 integer，再返回 MAX；任一异常使聚合结果为 NULL，
随后 storageUnsigned(Row,column:) 返回 storageRangeExceeded，不让合法较大水位掩盖小数，也不直接转换越界 REAL。
applyOwnReadWatermark 在 SQL 合并旧水位前检查实际正 integer，避免较新值静默覆盖异常状态。

新增持久水位、pending 请求、acknowledged 结果、旧水位更新四路径 × 1.5/Double(Int64.max)，共 8 个 SQLite 场景。
正常 CHECK 保持开启，同时保留合法水位 8；验证单房间及批量读取拒绝异常、未知房间仍为空、空输入仍为空，
异常更新不推进同步游标且原值/类型保留。修复字段后读取为 8，同一新水位 9 批次成功并推进游标。
命令重复、同步和已读 outbox 三套件共 135 项通过，3.881 秒；日志 `/tmp/imv2-b01-effective-watermark-storage.log`。
未改 schema、未跑全仓/App/真机；本轮没有新增快照/进程中断场景，B01 其他入口继续开放。

## 置顶事件及快照保留的来源序号

pinShouldReplace 与 applyPinnedMessage 的可选 room_sequence 经 optionalEffectInteger 读取：仅 NULL 表示未知，非 NULL 必须是正 integer。
快照复制 live 置顶前同样读取检查；快照开始保留置顶时，先验证 shadow 状态/收据和与保留房间、置顶对象或同源 incoming 收据相关的 live 收据，
防止 REAL 在 covered 比较中被提前排除或直接复制。已移除且无相关快照对象的房间不因此保留收据。

六处 × 1.5/Double(Int64.max) 共 12 个正常 CHECK 下 SQLite 场景：增量重复收据/当前状态，快照 live 状态/收据、shadow 状态/收据。
失败时游标、异常原值/类型、live 收据数量与置顶状态保持；修复字段后原增量或快照准备/切换成功。
重复 fixture 只移除独立同步投递记录；快照使用真实导入和准备入口，未模拟服务端 ACK 或进程强杀。
同步套件 129 项通过，4.125 秒；日志 `/tmp/imv2-b01-pin-storage.log`。既有 NULL 来源补齐、取消置顶、跨流及重开回归同轮通过。
未改 schema、未跑全仓/App/真机；权限快照、审核解码与全范围映射仍开放。

## 角色权限快照的两侧版本检查

preserveRolePoliciesInSnapshot 在新旧排序与全局版本 MAX 合并前，检查 shadow 全部角色/全局版本，
以及保留房间对应的 live 角色/全局版本。修订必须是正 integer，来源序号允许 NULL，否则也须为正 integer。
live/current 的四处 Swift 读取改为 effectInteger/optionalEffectInteger；current 序号检查早于版本大小分支。

六个位置（两侧角色修订、来源序号、全局权限修订）× 快照版本 1/2/3 对 live 版本 2 × 1.5/Double(Int64.max)，共 36 个正常 CHECK 下 SQLite 场景。
异常时游标、原字段/类型、live 收据数保持，activation_prepared 为 false；修复字段后同一快照准备/切换成功，
角色修订与全局修订保持 max(2, snapshotRevision)。既有权限空集、跨流、基线和来源冲突回归同轮通过。
同步套件 130 项通过，5.132 秒；日志 `/tmp/imv2-b01-policy-snapshot-storage.log`。
未改 schema、未跑全仓/App/真机或新增进程中断；增量全局权限 MAX 写入及其他 SQL 复制仍须纳入完整入口审计，不能由本次快照检查推断全部安全。

## 增量权限全局版本与审核记录公开读取

applyRolePolicy 在重复收据、迟到/较新版本分支前检查已有全局权限 revision 的实际正 integer，
防止 SQL MAX 静默保留或覆盖 REAL，也不允许重复分支跳过已有全局值检查。
在既有 effectStorageTypes 中增加较新/重复/迟到三路径 × 两种 REAL，共 6 个异常场景；
失败时游标、原值/类型和收据数量保留，修复后分别推进到版本 3 或保持版本 2。
审核解码改为 effectInteger 后转换 UInt64，复用 moderation 两个异常 fixture 验证公开 moderationActions 报 invalidMessagePayload，修复后读取序号 1。

同步与房间投影两套件 131 项通过，5.175 秒；日志 `/tmp/imv2-b01-policy-global-moderation-storage.log`。
未改 schema、未跑全仓/App/真机；进一步调用链检查定位 roomAppliedRoomSequence 聚合和 completeRolePolicyBaseline 的全局 MAX，已加入文首开放范围。

## 房间已应用序号的八来源聚合

roomAppliedRoomSequence 不再对各来源先 MAX 再转可选 Int64；改为对八来源原始候选验证类型及各自域，
任一异常令聚合结果为 NULL，storageUnsigned(Row,column:) 返回 storageRangeExceeded。
游标允许零，群事件/消息/反应/成员序号必须为正 integer；置顶/公告/权限序号允许 NULL，否则须为正 integer。
空集合、只有 NULL 来源和零游标时返回 0，最大合法 Int64 仍可转换为 UInt64。

八来源 × 1.5/Double(Int64.max) 共 16 个正常 CHECK 下 SQLite 场景通过。
事件与消息各有 100/200 两行，其他来源保留合法大值，覆盖同表及跨来源 MAX 掩盖小数；异常读取保持原值，修复后恢复 200。
所有场景还核验未知房间 0、Int64.max 及 NULL/零语义。
命令 `swift test --package-path IMV2ClientKit --jobs 4 --filter 'V2SyncEngineTests|V2RoomRecoveryRunnerTests'` 实际匹配同步套件 131 项、1 套件，5.288 秒；
没有名为 V2RoomRecoveryRunnerTests 的匹配套件，不能声称额外执行了恢复 runner 套件。日志 `/tmp/imv2-b01-room-applied-storage.log`。

成本边界：新检查读取房间原始候选，不能沿用旧 MAX 的索引极值成本；调用点为 App 的 roomReadCheckpoint。
需测量大历史房间及处理必要的性能问题后再收口；本轮没有容量测量，未跑全仓/App/真机，B01 仍开放。

## 已应用序号查询成本与索引修复

使用 [测量脚本](../../scripts/measure_v2_room_applied.py) 从当前 Swift 文件提取查询及八张相关表和索引。
临时 SQLite 保留正常 CHECK，构造目标/无关两个房间，每房间各有 1 千/1 万/10 万条事件、消息、反应，
最多 1 万成员，事件载荷 1 KiB、消息文本 256 字节。七次热缓存读取取中位数；不是完整 App、冷缓存或设备测量。

先前候选遍历在 10 万档约 23.97 ms，原嵌套 MAX 约 7.65 ms，且反应表扫描无关房间。
本轮在客户端 canonical schema 新增八个仅记录非法序号的稀疏索引，以及反应、成员角色、置顶三个 (room_id, room_sequence) 索引。
查询改为同一 SQL 读快照中先 EXISTS 检查异常，再按索引取 MAX；不撤销任何类型/空值/范围检查。
快照索引复制使用既有通用机制，新增断言验证置顶快照切换后异常索引存在，注入小数仍被拒绝、修复后正常读取。

| 每房间事件/消息/反应行数 | 最终查询中位 ms | 去掉新索引的同查询中位 ms | 带/不带新索引的单次写入 ms | 带/不带新索引的数据库字节 |
| --- | --- | --- | --- | --- |
| 1,000 | 0.0056 | 0.2886 | 27.7 / 24.3 | 4,345,856 / 4,214,784 |
| 10,000 | 0.0076 | 2.9299 | 243.9 / 230.2 | 42,196,992 / 41,304,064 |
| 100,000 | 0.0054 | 24.5485 | 1,874.7 / 1,753.6 | 413,720,576 / 408,657,920 |

最终读取每次小于进度回调的 1,000 VM 指令计量粒度；不是零指令。
最终及无索引 JSON 分别为 `/tmp/imv2-b01-room-applied-cost-final.json`、`/tmp/imv2-b01-room-applied-cost-no-index.json`；
最初遍历/旧 MAX 对比为 `/tmp/imv2-b01-room-applied-cost.json`。
写入只测一个批次，约 7%/1.2% 的耗时/空间增长仅对应 10 万档此样本，不能当作稳定性能比例或生产容量。

验证：同步 131 项（包含新增快照切换后的断言）通过，5.341 秒；同轮 schema 两项因旧对象数/指纹失败。
独立核对新库 211 对象，排除新增 11 索引后恰好恢复旧 200 对象及旧指纹 ec990167f156cd49，
更新预期为 42eabdd87f0a886d 后仅重跑 schema 两项，通过，0.047 秒。
日志 `/tmp/imv2-b01-room-applied-indexed-final.log`、`/tmp/imv2-b01-room-applied-schema-after.log` 保留该通过/失败顺序。
未新增旧布局升级；没有这些索引的既有数据库仍能执行正确查询，但不能继承新库成本结果。
服务端 schema/协议版本不变，未跑全仓、App 或真机；B01 剩余权限基线及完整入口映射继续开放。

## 权限基线完成时的全局与角色版本

completeRolePolicyBaseline 在当前请求匹配后，先检查全局权限修订实际正 integer，以及该房间已观察角色的修订和可选来源序号。
避免版本相等 SQL 把异常角色跳过，也不让全局 MAX 吞掉异常后清除恢复待办；仍保留不匹配旧请求返回 false 的规则。
三字段 × 相同基线 8 / 较新基线 9 × 1.5/Double(Int64.max)，共 12 个正常 CHECK 下 SQLite 场景通过。
异常返回 invalidMessagePayload，待办、游标、原字段/类型和基线 8 保持；修复后同一请求完成，待办删除且全局修订为对应 8/9。
同步套件 132 项通过，5.519 秒；日志 `/tmp/imv2-b01-policy-completion-storage.log`。
未改 schema、未跑全仓/App/真机。跨文件核对新增未读快照聚合入口，具体剩余范围见文首表；B01 未关闭。

## 未读快照的状态、水位与成员过滤

roomUnreadSnapshot 六个状态字段使用 storageUnsigned(Row,column:) 精确读取；成员资格版本在 Swift 过滤前检查实际整数，
避免 SQL 比较把异常成员版本误当作撤权/无结果。合法的较新撤权、同代非成员、未知账号/扫描绑定仍按原规则不返回房间。
独立 local_read 聚合先检查全部候选正 integer；无候选保留 NULL，异常用内部 -1 标记并经 storageUnsigned 拒绝，
不把损坏数据当作没有本地水位。查询仍在同一 SQLite 读取快照内，保持请求去重与每批 100 房间的规则。

六个状态字段、成员资格修订、持久水位、pending 请求、acknowledged 结果，共十位置 × 两种 REAL，20 个场景。
只有 head=1.5 及三个子序号的超大 REAL 注入绕过 head/子序号 CHECK，其余正常 CHECK；注入后立即恢复 CHECK。
验证单批包含重复/未知房间时抛 storageRangeExceeded、异常原值/类型不变、空输入/未知房间仍为空；
修复后服务端未读 5、本地水位 10、展示未读 2，最初无候选时 localReadWatermark 为 nil。
恢复持久化、未读模型与命令重复三套件 26 项通过，0.531 秒；日志 `/tmp/imv2-b01-unread-snapshot-storage.log`。
既有撤权、外部账号绑定及回执回归同轮通过；未跑全仓、App、真机或容量专项。B01 的其他 SQL 复制与完整跨模块映射仍开放。

## 成员快照来源历史的整数筛选

成员效果在快照合并前检查 shadow 历史，以及仍授权群/同源 incoming 对应的 live 历史，
membership_revision 与 projection_sequence 必须为正 integer，room_sequence 允许 NULL，否则也必须为正 integer。
检查位于冲突 join、来源复制和最新成员状态 reduction 前，不让较大移除修订掩盖小数历史。

两侧三个字段 × 1.5/Double(Int64.max)，共 12 个正常 CHECK 下 SQLite 场景。
先通过同步/房间流保存角色 2 及移除 3，快照携带旧角色 2；注入异常后准备返回 invalidMessagePayload，
游标、房间序号 20、异常原值/类型与 live 无角色状态保持，activation_prepared 为 false。
修复字段后同一快照切换至代次 2，房间序号仍为 20，旧角色不恢复。
成员恢复与同步两套件 139 项通过，5.989 秒；日志 `/tmp/imv2-b01-member-snapshot-storage.log`。
未改 schema、未跑全仓/App/真机；公告/权限/反应效果及普通房间行的其他 SQL 复制仍须核对，B01 未关闭。

## 公告与角色权限快照历史收据

公告快照在收据保留前检查已合并公告状态、shadow 收据以及对应房间 live 收据的 revision/room_sequence。
角色权限快照在版本筛选和冲突检查前验证 shadow 收据，以及有同角色状态、基线或同源 incoming 的 live 收据。
修订必须为正 integer，来源序号只有 NULL 可表示未知；避免 REAL 被 <=/MAX 条件筛掉后静默丢失历史证据。

两类收据 × 两侧 × 修订/来源序号 × 1.5/Double(Int64.max)，共 16 个正常 CHECK 下 SQLite 场景。
live 为版本 2、snapshot 为版本 3；失败保留原值/类型、live 版本 2、游标，activation_prepared 为 false。
修复字段后同一快照切换到代次 2、投影版本 3，并保留旧/新两条收据。
同步套件 133 项通过，5.961 秒；日志 `/tmp/imv2-b01-snapshot-receipt-storage.log`。
未改 schema、未跑全仓/App/真机；反应效果、权限基线筛选与普通房间行复制仍待核对，B01 未关闭。

## 反应快照状态与收据的整数检查

preserveReactionEffectsInSnapshot 在序号保留条件前检查 shadow 版本、shadow 收据，
以及与保留反应键匹配的 live 收据，room_sequence 必须为实际正 integer。
复制进入 shadow 的 live 状态也由该检查覆盖；失败回滚前序复制，不允许 REAL 被保留排序滤掉或带入最终银行。

live 状态复制/live 收据/shadow 状态/shadow 收据四路径 × 两种 REAL，共 8 个正常 CHECK 下场景。
测试使用相同合法反应事实，异常时游标、原值/类型和 live 可见反应保留，activation_prepared 为 false；
修复后同一快照切换到代次 2，版本 2 和一条收据保留。
同步套件 134 项通过，6.135 秒；日志 `/tmp/imv2-b01-reaction-snapshot-storage.log`。
本批只证明整数检查，不证明新旧添加/移除交错时可见表与版本表合并一致，后者仍需专项核对。
未改 schema、未跑全仓/App/真机；B01 其他复制路径及 B06 快照组合继续开放。


## 反应快照版本排序与可见状态一致性

后续专项发现，分别复制可见反应和版本记录会使旧添加覆盖新移除的可见结果，或丢失 live 的较新版本。
修复为先检查授权 live 与 shadow 的实际正整数序号和同键冲突，按较大房间序号保留状态，再合并历史收据；
同源历史摘要冲突拒绝准备事务。可见反应从最终 add 状态重建，排除撤回消息和 tombstone。
新增 8 个新旧方向/add-remove/撤回组合，实际激活、关闭重开并重放旧来源；另有 3 个同版本/同源/历史来源冲突回滚场景。
143 项同步/成员恢复测试通过，6.900 秒；详见[验证记录](verification-records.md#20260919-reaction-snapshot-order)。
这是 B06 的局部一致性修复；B01 的其他 SQL 复制、权限基线筛选和跨文件映射继续开放。


## 权限基线快照资格筛选

在 live 与 incoming 均授权且房间匹配的候选范围内，先检查基线 permission_revision、membership_revision、room_sequence
以及两侧房间 membership_revision，再进行修订相等、来源相等和基线成员版本上限比较。
成员/权限修订要求实际正 integer；room_sequence 保持非负 integer 合同。
避免异常值提前被比较过滤而静默丢失基线，也避免将 REAL 复制到已准备快照后才在公开读取时失败。
五位置 × 1.5/2^63 共 10 场景，验证失败事务保留原值/类型/游标和未准备标记；修复后激活同快照恢复两个 revision 8 权限角色。
同步专项 137 项通过，6.559 秒；[证据](verification-records.md#20260919-policy-eligibility-storage)。
未扩大到撤权房间的废弃基线，普通房间行及其他模块映射仍开放；未改 schema、未跑全仓/App/真机。


## 房间日志/游标快照复制与公开读取

授权保留房间的事件序号须为实际正 integer，应用游标和裁剪下界须为非负 integer；在复制前拒绝异常。
修复前测试显示准备成功后把 REAL 游标带入激活库，公开读取 2^63 值触发 GRDB Row 强制解码崩溃。
`groupEventCursor` 与 `roomLogTrimmedThroughSequence` 改为先验证实际整数类型，异常返回 storageRangeExceeded；缺失房间仍返回零。
12 个参数场景覆盖三字段、两种 REAL 及保留/移除两种范围；保留场景检查事务回滚、修复后同快照激活及重开，
移除场景确认坏的旧日志可丢弃且不会保留公告或事件。两个 getter 的异常读取和重开后的零裁剪下界同轮检查。
159 项、2 套件通过，7.633 秒；[专项记录](verification-records.md#20260919-snapshot-room-log-storage)。
未改 schema、未跑全仓或容量；普通消息/管理等投影复制及 B01 完整映射仍开放。


## 消息快照状态与相关历史整数检查

在 ON CONFLICT 复制之前检查授权 live 及 shadow 消息的 room_sequence、timeline_sequence、message_revision；
房间序号/修订须为实际正 integer，timeline_sequence 保留 schema 的非负范围。
撤回记录在复制前检查 shadow 与相关 live 修订为实际 integer 且大于 1；效果收据在版本筛选前检查实际正修订。
新增两侧消息三字段、两侧 tombstone、live 收据共 18 场景。修复后检查原值/类型/游标/未准备标记保持，修复值后同快照激活恢复撤回 revision 3。
初始夹具的 accepted 消息 ID 默认随 room_sequence 变化，导致两个收据场景未匹配目标；最终夹具显式绑定同一 ID。
最终同步/搜索串行 150 项、2 套件通过，55.973 秒；并发轮时限失败及夹具修正保留在[证据](verification-records.md#20260919-snapshot-message-storage)。
未改 schema、未跑全仓/App/真机或容量；其他普通表复制与 B01 全范围映射继续开放。


## 管理、控制和时间线快照复制

copyRoomRows 对三个明确调用点增加实际正 integer 序号检查：moderation/control 的 room_sequence 和 timeline 的 timeline_sequence。
检查全部 shadow 记录及原授权范围内的 live 记录，先于 ON CONFLICT DO NOTHING；被移除房间的旧异常记录不阻止重置。
18 场景覆盖三类、两种 REAL、live/shadow/移除；shadow 场景在已导入房间基线后复制合法 live 行作为损坏夹具，再注入异常。
保留场景验证事务回滚和修复后同快照激活；全部场景关闭重开，确认序号 20 或移除后无行。
11 项、2 套件通过，0.944 秒，包含既有 12 个增量读取异常场景和相关快照恢复回归；[证据](verification-records.md#20260919-snapshot-room-projection-storage)。
未改 schema、未跑全仓/App/真机/容量；其他普通表及快照初始化复制仍待映射，B01 开放。


## 快照初始化与准备的本人成员状态

初始化会复制整个 v2_room_membership_states，其中包括撤权历史；不能仅验证传入快照出现的房间。
在创建影子表前检查 live membership_revision 为实际正 integer，准备阶段在复制/撤权过滤前再次检查 shadow 全表。
8 场景覆盖 begin/prepare、成员/已移除及两种 REAL；失败保持游标和原值，初始化失败不留下影子表或导入记录，准备失败保持未准备标记。
修复原值后可继续同快照、关闭重开保留修订 2 及成员标记，再处理修订 3 的新授予。
16 项、2 套件通过，2.690 秒；[专项证据](verification-records.md#20260919-snapshot-member-fence-storage)。
同时核对 prepareDeviceOwnedIdentityShadow 的身份表无整数修订/计数列；prepareContactSearchShadow 使用 SQLite 自有 rowid。
未改 schema、未跑全仓/App/真机/容量；其他普通表/派生查询和跨模块完整映射仍开放，B01 未关闭。


## 房间恢复页提交的本地游标整数边界

applyGroupEventPageReportingChanges 曾两次直接将 Row 的 applied_room_sequence 解码为 Int64；REAL 大值触发 GRDB fatal error，
裁剪下界又直接进入 SQL MAX，可能保留异常值或被较大新值掩盖。
改为同一事务开头一次读取两字段并验证实际非负 integer，事件应用/排序比较之后以已验证旧游标判断永久缺口。
8 场景覆盖两字段、两种 REAL、空/有事件页；失败不推进游标、不落事件/冻结投影、不修改缺口标记。
修复值后可提交同页并置位真实缺口，重复投递不增加事件。51 项、4 套件通过，1.971 秒；[证据](verification-records.md#20260919-room-page-cursor-storage)。
源码核对快照摘要按已检查消息序号排序，列表整数列为 schema 布尔标记；这不代替全部普通表/派生查询及跨模块映射。
未改 schema、未跑全仓/App/真机或容量，B01 开放。


## 最新可见摘要的消息最大序号

GRDBV2RoomLatestVisible.latestVisibleIsCurrent 原仅验证 MAX 返回值；当 1.5 与合法 20 共存时，摘要读取/提交会误判有效并清除摘要待办。
改为同一 SQL 中先检查目标房间所有非法序号，非法返回 -1 交给 recoveryInteger 拒绝，再按索引取最大合法序号；空集合仍为零。
存在性子查询选择 message_id，使本机 SQLite 计划使用现有稀疏异常索引，而不是优先使用普通 room/sequence 覆盖索引扫描候选。
4 场景验证 1.5/2^63、目标/无关房间，异常目标不能完成摘要待办；修复值后原请求可继续。大值的缓存删除沿用原触发器，未要求它返回已删除缓存。
53 项、4 套件通过，1.909 秒；[证据](verification-records.md#20260919-latest-visible-max-storage)。
查询计划只在 Python SQLite 最小等价索引模型核对，无真机/GRDB 容量结论；未改 schema、未跑全仓，B01 仍开放。


## 恢复待办读取、合并及完成删除

原 roomRecoveryWork 只验证 target_head，priority 的 REAL 可被直接 Int 读取；重新入队/目录发现、ensure、状态/摘要提交和服务调度会比较或覆盖其他未检查整数。
新增统一检查：target_head/last_served_order 非负 integer，priority integer 且 0...2，目录成员修订 NULL 或正 integer，目录 owner epoch NULL 或非负 integer。
读取验证当前返回的工作行；入队/ensure/提交前验证目标房间现存行，服务记账前同样验证，重试更新与记账在同一事务内回滚。
完成删除前验证目标待办及 applied_room_sequence，避免 REAL 比较直接移除工作。
54 个操作/字段异常场景加 4 个完成比较场景，普通 CHECK 下验证请求修订、需要状态/摘要标记与数据库内容不被错误覆盖，修复后可继续。
60 项、4 套件通过，2.792 秒；[证据](verification-records.md#20260919-recovery-work-merge-storage)。
不声称查询筛选前全量扫描了所有延迟待办；目录页及触发器的其他读者、不可用/撤权清理等调用链仍需继续映射。
未改 schema、未跑全仓/App/真机/容量，B01 仍开放。


## 目录页复用缓存摘要的版本比较

commitRoomRecoveryDirectoryPage 原直接在 EXISTS 内比较缓存的 personal_generation、owner_epoch 和 membership_revision，
REAL 可能导致错误复用或重排摘要工作，目录游标仍推进。
现于同一页事务中在比较前验证三个字段为实际 integer（成员修订为正，另外两个保持非负存储范围）。
6 场景覆盖三字段 × 两种 REAL；页中第二个房间异常时，第一个房间的新增待办和目录游标一并回滚。
修复后同页可继续，合法缓存房间无需重取摘要，无缓存房间仍需摘要。
54 项、3 套件通过，2.218 秒；[证据](verification-records.md#20260920-directory-summary-storage)。
未改 schema、未跑全仓/App/真机/容量；其他目录输入、触发器与清理调用链继续映射，B01 未关闭。


## 恢复扫描的账号与安装绑定计数隔离

beginRoomRecoveryScan 原在账号或安装绑定变化时清空待办/摘要/房间状态，但保留旧 scan 的 service_sequence。
旧计数达到 Int64.max 时，新身份的首次服务记账也会失败。现在同事务删除旧 scan 后创建新行，使计数从 schema 默认零开始；
同账号同绑定重连不删除 scan，保留调度历史及耗尽保护。
6 场景覆盖用户变化、绑定变化、同身份及 7/Int64.max，验证旧 scope 失效、新身份无旧待办且首次调度到 1，
同身份普通计数继续递增、最大计数仍安全拒绝而不溢出。
61 项、4 套件通过，2.390 秒；[证据](verification-records.md#20260920-recovery-scan-binding)。

本轮还核对了剩余恢复边界：目录 entry 的不可变构造器限定 UInt64 至 Int64.max；进度 COUNT 为 SQLite 生成整数而非存量任意值；
完成候选和终验通过 readCursor 验证持久代次/序号，再要求 ACK 与应用位置一致；不可用清理先比较捕获的成员/状态与请求标识，未从待办计数转换后授权。
这些是源码调用链核对，不宣称重跑真实网络、全量延迟队列或所有 SQL 触发器故障矩阵。
未改 schema、未跑全仓/App/真机/容量；跨模块完整映射继续，B01 未关闭。


## Core 帧长度配置及算术入口核对

V2FrameLimits 原允许 Int.max 配置，但 Data/NIO 编码器会把 payload.count 转为 UInt32；配置未建立编码依赖的线格式上界。
构造器现要求 UInt32(exactly:) 成功，且为 headerLength 加法保留 Int 空间，非法配置抛 invalidLimits。
新增负值、UInt32.max+1、Int.max 拒绝场景及三个合法配置下最大声明长度测试；使用 18 字节帧头，不分配 4 GiB 包体。
64 位当前平台允许 UInt32.max 配置；不足最大声明长度时拒绝，最大配置下作为未完成帧保留并在 finish 时报告截断。
App 与本地探针的 65_536 配置位于范围内；Gateway 环境值经 throwing 构造器进入该边界。

| 本轮源码核对 | 保护依据与范围 |
| --- | --- |
| CapacityWindow / PushAdmission | 非负不可变输入；先判断剩余额度或严格小于上限，再递增，不能越过 Int.max |
| SendMessageAcceptance | 新发送先检查 1...Int64.max，递增后的 UInt64 可表示耗尽哨兵；重放分支保留原结果 |
| SendMessageFingerprint | 内部入口接受命令已验证实体；V2RichMessageContent 重查合成 Codable 字段并用 addingReportingOverflow 检查区间 |
| Revisions / ProfileRevision | 有符号构造边界或失败 RawRepresentable 构造保护转换；既有 Profile Codable 越界测试同轮通过 |
| ShardAdmissionLease | Core 代次不是 Int64 领域包装；本轮核对的 Server 两个命令额度池使用 Int64(exactly:)；不据此推断所有租约调用者已查完 |
| V2FrameDecoder | 当前 64 位平台 UInt32 声明转 Int 安全，声明长度先检查；头部偏移在已缓存长度检查后访问 |

40 项、10 套件通过，0.004 秒；[证据](verification-records.md#20260920-core-boundary-audit)。
未跑 Server/App/全仓或真实超大内存包体；跨模块剩余入口映射继续，B01 未关闭。


## Gateway 配置接入与服务端时间边界

[Gateway 配置](../../IMV2Server/Sources/IMV2Server/V2GatewayRuntimeConfiguration.swift) 的 IM_V2_MAX_FRAME_BYTES 直接经过 V2FrameLimits。
新增配置级测试拒绝 -1、UInt32.max+1、Int.max，允许 0、65_536、UInt32.max；错误沿用 V2FrameCodecError.invalidLimits。
这是上一批核心修复的实际环境配置入口验证，本轮没有重复修改编码器或服务端业务源码。

| 本轮服务端源码核对 | 结论与边界 |
| --- | --- |
| v2RateLimitRetryAfterSeconds | 窗口使用 Int(exactly:)；检查 PostgreSQL 时间戳后用 lower + (upper-lower)/2 二分，无先加后检的 Int 溢出 |
| V2DurableRetryPolicy | attempt 正值前置条件后才减一，指数最多 30；持久化时间可表示性由工作器调用点另行保护，不能仅靠策略得出全工作器安全结论 |
| PostgresV2UserProjectionWorker.recordFailure | failure_count 为 PostgreSQL bigint 且 schema CHECK >=0；递增前检查 <Int64.max。retry 时间写入前经过 v2PostgresFutureTimestamp；本轮仅核对调用链，未跑该工作器数据库场景 |
| Gateway nonNegative 配置转换 | 文本先经失败式 Int 解析和非负检查；当前 64 位平台转 Int64 可表达。其他平台和所有配置调用者不在本轮结论内 |

40 项、3 套件通过，0.004 秒，含配置、账户限流时间和 PostgreSQL 时间戳边界；[证据](verification-records.md#20260920-server-boundary-audit)。
未开启 PostgreSQL、未运行真实 TLS/工作器或全仓套件；重试分类策略、其他转换入口仍独立审计，B01 开放。


## 跨归属内容审核汇总预算

`V2RoutedContentReviewWorker` 原先只检查单个归属预算为正，多个归属的计数汇总可超出 Int。
现于任何工作启动前要求 `limitPerOwner <= Int.max / workers.count`，超限沿用 invalidLimit；构造器已保证归属数非零。
生产审核工作器经 PostgreSQL LIMIT 认领，每条租约各项计数至多递增一次，因此每项报告不超过单归属预算；推进协议同步注明此约束。
测试使用替身计数，不分配巨量任务：2/3 归属拒绝超上界且不调用工作器，1/2/3 归属的最大合法预算可精确汇总。
19 项、2 套件通过；[证据](verification-records.md#20260920-review-budget)。本轮未跑数据库或生产容量，不据此关闭其他工作器及 B01。


## 分片发送准入自适应阈值

`V2ShardedSendMessageAdmissionBatcher` 将自适应窗口阈值分配到各通道时，原用 `(value + divisor - 1) / divisor`。
配置允许 `minimumRequestsInWindow` 与 `maximumPendingRequests` 为 Int.max，因此即使只创建两个通道，中间加法也会溢出。
现改为商加非零余数对应的 1，保留向上取整和每通道至少 2 个样本的语义。
新增测试通过实际构造器覆盖 2/3/128 个通道与 Int.max-1/Int.max 阈值，读取空运行快照；不分配阈值数量的任务。
发送准入专项 27 项通过，含既有并发、稳定房间路由及共享容量行为；[证据](verification-records.md#20260920-sharded-threshold)。

本轮源码另核对：审批恢复分页上限 100、房间目录分页上限 100、联系人备注与群昵称分页上限 500、建群冻结清单分页上限 512、邀请目录导入命令上限 100，均在 `limit + 1` 前限制输入。
这些分页仅作源码核对，未新增数据库运行证据；其他计数/查询和长期运行指标仍需继续映射，B01 未关闭。


## 发送准入计数与压缩预算核对

本批只补测试和审计证据，没有修改生产实现。

| 已核对入口 | 保护与证据边界 |
| --- | --- |
| V2SharedSendMessagePendingCapacity.tryReserve | 仅在 current < maximum 时加一，maximum 为正 Int；释放依赖每个已取得令牌恰好释放一次，重复释放属于前置条件失败，不据此声称调用者全审计完成 |
| 发送准入 / 数据库准入耗时指标 | 单调时钟非正耗时返回零；秒转毫秒使用 multipliedReportingOverflow，汇总使用饱和加法；本轮为源码核对，未伪造时钟运行边界测试 |
| 分片发送准入 UInt64 指标汇总 | addingReportingOverflow 后饱和到 UInt64.max；不涵盖各通道所有累计指标自身的长期回绕语义 |
| Server / ClientKit protobuf 编码 | 压缩预算先检查正值；膨胀比乘法前使用 Int.max / ratio 验证，上界不可表示时回退未压缩帧；本轮仅源码核对，未跑两端协议套件 |
| V2ZlibFrameCompression | 非正预算拒绝；压缩输入和解压输出预算分别验证；膨胀比乘积不可表示按既有合同抛 expansionRatioExceeded |

新增测试覆盖负值/零预算、最大可表示膨胀比乘积与越界一步、Int.max 倍数、精确字节预算及少一字节。
压缩模块 8 项测试通过，含原有黄金向量、往返、损坏输入和资源上限；[证据](verification-records.md#20260920-compression-boundaries)。
只分配小型输入和输出缓冲，不以本机结果代替跨平台 zlib、真实超大帧或全范围 B01 验收。


## 恢复待办的持久化时间边界

SQLite REAL 亲和性不保证值是有限数值。待办原只校验整数，读取可将异常入队时间传入 Date；合并/重试又可能覆盖非法时间。
统一行校验现接受整数或有限实数时间，拒绝文本、非有限值等，错误为 invalidWork。
重试在匹配 room_id/request_revision 的行上先校验再更新，过期请求仍不改写新请求。既有整行校验调用点同时保护合并、状态/摘要提交及完成路径。
测试覆盖 enqueued_at/next_attempt_at × 正负无穷 × 合并/重试的 8 个场景，断言异常值、请求修订和 service_sequence 不变，修复存储后可继续；两种排序模式读取文本入队时间被拒绝，合法负小数时间可读取。
57 项恢复整数/持久化/引擎测试通过；[证据](verification-records.md#20260920-recovery-dates)。
本轮不新增全队列扫描或修改 schema；next_attempt_at 非法而被 WHERE 排除的待办不会仅靠本次读取校验发现，未选中队列的诊断与查询前筛选仍开放。


## 恢复进度的重试时间聚合校验

上一批遗留的“异常 next_attempt_at 被到期筛选排除”现由 roomRecoveryProgress 覆盖：在同一读快照中，非空队列分别查询 MIN/MAX，再通过共享 recoveryTimestamp 校验实际存储类型及有限性。
SQLite 数值排序在文本/二进制之前；MAX 可发现隐藏在正常数值之后的非数值与正无穷，MIN 覆盖负无穷。NOT NULL 列没有被聚合忽略的空值。
不再使用可能因文本而失败的 Double.fetchOne 直接解码；异常统一返回 invalidWork，不删行或把损坏当作队列完成。
该检查用于恢复进度，不改变单次 roomRecoveryWork 的到期筛选；队列其他字段的未选中行校验仍未完成。

8 个新增参数场景：正负无穷/文本/二进制各与单独异常房间、另有正常房间组合，拒绝后保存原值，修复后返回正确计数和最早时间；空队列也覆盖。
59 项、3 套件通过；[证据](verification-records.md#20260920-recovery-progress-dates)。
从当前源码提取表、索引及查询的本机 SQLite EXPLAIN 显示两次极值均使用 due_idx 覆盖索引；这是查询计划诊断，不是 GRDB 设备容量验收。未增加索引或 schema。


## 异常重试时间的运行器生命周期验证

在真实 SQLite 中预存两个恢复待办，其中一个 next_attempt_at 为文本或正无穷，另一个仍正常到期。
分别从前台 run 与后台 runBounded 启动，验证 invalidWork 上抛、engine 回到 idle、未拉目录或正文、两个待办及异常房间请求修订保留、正文游标为零。
显式修复异常行后，模拟重连替换通知流并复用同一停止的引擎；在 6 页/房间总预算内恢复到两个房间游标 5，待办清空，未调用无界个人流完成证明。
4 个参数场景及运行器专项共 24 项通过；[证据](verification-records.md#20260920-recovery-invalid-date-runner)。
本轮只补测试；新通知流为替身，不代表真实 TLS 重连或真机后台。没有自动改写坏库，B01/D08 继续开放。

## 服务端既有转换的收敛核对（2026-09-20）

本轮沿调用链核对以下直接转换，未发现需要新增保护层的缺口；仅记录源码依据，不新增测试或声称 B01 全范围关闭。

| 转换位置 | 已有保护及结论 |
| --- | --- |
| PostgresV2ReadReceiptStore.appendPreferenceProjection | setPreferences 在新写入前校验 now；偏好时间由该值写入。幂等返回也校验持久化时间。毫秒转换位于 PostgreSQL 微秒可表示范围内。 |
| V2ConversationCapabilitiesService 的会话状态与收藏投影 | 新操作先校验 now，可空 muteUntil 单独校验；重放校验持久化时间。无需再为私有投影方法新增一套时间策略。 |
| PostgresV2DirectMessagingStore.appendDirectRoomProfileProjection | 方法内先校验 profile.updatedAt 和正 revision，再构造毫秒及修订投影。 |
| PostgresV2MessageProjectionStateRepository 状态构造 | Int64(state.messageRevision) 前已有 UInt64(Int64.max) 上界检查。 |
| PostgresV2SnapshotArtifactBuilder 累加及返回转换 | 当前 schema 将 next_page_index 限定为 0…4096、item_count 为 0…1000000、total_bytes 为 0…268435456；既有 PostgresV2SnapshotCounterBoundsTests 验证真实约束拒绝越界。不能仅见到加法就重复新增饱和计数器；本结论依赖当前 schema 就绪要求，不支持绕过约束的数据库。 |

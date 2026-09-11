# 房间读模型合同

状态：**设计已定；未读三根支柱、投递重试分类、房间活动时间、房间摘要聚合接口及其线
协议与客户端传输、客户端未读目录与 App 角标已实现并通过回归验证；单聊切 `room_log`／
已改为部署默认；第 3 步的两个前置条件（历史授权收口、客户端按服务端宣告纳管）已完成；
明示 mention 已改为通知（Push 通道承担）；标准群推广读模型已具备能力与开关（按房间宣告
权威副本形态，**已改为部署默认 `room_log`**）；operator 按来源事件的批量重放已实现；保留窗口
（窗口／永久两种模式）与"历史不完整"标记已落地，默认永久即不裁剪；进入房间按 §5.4
推进到本设备已应用序号、追平房间头时直接推进到 head 已落地**。
本文规定目标架构与验收不变量。实施进度与相关缺陷的当前状态见
[问题状态表](status.md) 中的 B03、B04、D07。

适用范围：单聊与群聊的消息投递、未读计数、房间日志保留，以及客户端同步模型。
不适用于用户级状态（联系人、资料、偏好、收藏、Push 意图、设备会话），那些继续走
个人控制流。

**不追求旧版本兼容**：项目未上线，本文描述的是**唯一**目标形态。因此实现里不保留
"缺字段就推断""旧格式回退""两套并存"这类兼容分支：服务端宣告的字段缺失或取值未知就按
不可解码处理，schema 迁移只服务测试夹具与新环境建库，不再为已部署的旧版本设计升级路径。
需要保留的只有同一版本内部的**迁移期**机制（迁移路径的三步、灰度开关与回滚开关）。

## 1. 问题

现模型的权威副本是**每个收件人一份**。投递达到重试预算（默认 10 次、约 4 分钟）后
进入 `paused`，此后不再被领取、不转终态、不被 GC，只能由运维逐条重放。结果是同一
条事实存在两份持久副本，而其中一份的写入可以永久失败：

- 收件人无法察觉：未提交的投递不消耗同步序号，其同步流依然连续
- 发送方只看到 `MessageAccepted`
- 系统不会自愈

三个暂停层级与五种失败原因的完整分析不在本文重复；本文只规定消除该失败模式的
目标形态。

## 2. 产品决定

以下决定是本文的前提，改动其中任何一条都需要重新评估架构。

| # | 决定 |
| --- | --- |
| 1 | **已发送 ≠ 已送达**：不做投递回执，不做"已送达 N/M"展示 |
| 2 | 单聊与群聊统一到读模型：权威是房间事件日志，每用户副本只能是可重建的加速层 |
| 3 | 未读尾部必须送达：已读线之后、本设备未接收的事件必须能补齐 |
| 4 | 列表只展示最后一条消息摘要（本地投影，见 §4）；进入房间才拉取完整未读尾部 |
| 5 | 保留窗口可配置为「窗口」或「永久」两种形式 |
| 6 | 未读数必须正确同步，多设备一致 |
| 7 | 进入房间 = 已读 |
| 8 | 静音房间累计未读；静音只影响提醒 |
| 9 | 推送只在设备在线时有意义，且只是加速 |
| 10 | 单用户房间数**无上限**：不设配额，也不设准入上限；规模阈值只切换聚合策略，见 §8 |

## 3. 目标架构

```
服务端：每个房间一份事件日志（room_sequence 为排序键），与消息接受同事务提交
在线设备：连接顺手推送事件，可携带载荷；载荷无效时降级为纯提示
离线设备：上线后按房间游标拉取
推送为 fire-and-forget：服务端不记录"推给谁了"
```

核心变化是**删除"服务端代读"这一层**，而不是新建一套系统。单聊 `room_log` 模式与
大群 hybrid 已经采用该形态，客户端已具备按房间游标、目录扫描与加速载荷降级的能力。

不变量：**推送不得作为唯一依据**。连接半开、设备挂起、事件仅写入 socket 缓冲都
不等于客户端已收到，因此无论是否推送，客户端都必须能够拉取。

## 4. 三个视图的取数方式

| 视图 | 数据 | 方式 |
| --- | --- | --- |
| 会话列表 | 房间身份、标题、置顶、免打扰、最后一条消息预览来自**本地投影**；未读数与 head 来自**服务端摘要**（复制进本地未读目录，按活动有界轮转） | 本地投影保证离线与冷启动即时可渲染；服务端只承担它独有的部分（未读与房间头），有界分页 |
| 打开房间 | 未读尾部与最近窗口 | 单房间游标增量拉取，补齐到 head |
| 向上滚动 | 更早历史 | 按需分页；缺失时标记历史不完整 |

**列表为什么是"本地优先 + 服务端未读"的混合形态**（这是产品决定，不是迁移中的临时状态）：

1. **离线与冷启动必须立刻可渲染。** 可渲染所需的房间身份、标题、置顶、免打扰全部是该用户
   **自己**的状态（§7 归入个人控制流），服务端摘要不提供它们；因此无论列表源怎么切，最终
   都要与本地状态合并，多出来的只是一次跨源拼接。
2. **排序与置顶是本地语义。** 置顶先于活动时间、免打扰只影响提醒，这两条已经成立的产品语义
   都基于本地投影；把列表源整体换成"服务端活动序"会把它们一起丢掉。
3. **服务端不可替代的职责是未读与 head。** 那是唯一无法在客户端正确推算的量：要排除自己发的
   消息，要对齐服务端已读线，还要在多设备间收敛。摘要里的"最新可见消息摘要"因此是**可选**
   字段——客户端已经持有同一批内容，不必再把它复制到列表渲染路径上。
4. **预览不构成授权边界。** 授权发生在内容入口：房间日志拉取、媒体授权、转发来源都执行
   "事件发生时成员 ∩ 当前成员"；本地投影在授权被撤销（离群、停用、撤回、擦除）时会被清除。
   列表里的预览是**装饰**，不是可用来换取内容的凭据，所以把它留在本地不会放宽任何读取口径。

该划分取消的是"客户端必须追平全部房间"：未读由服务端给出并按活动有界轮转，内容按需拉取，
房间数再多也不改变单次请求的代价。

## 5. 未读机制

### 5.1 公式

```
基线(room, user) = MAX(room_read_receipts.read_through_room_sequence,
                       该用户在该房间最新一条消息的房间序号)
未读(room, user) = MAX(rooms.room_sequence − 基线(room, user), 0)
```

第二项就是 §5.3 的"自己的消息不计未读"；没有已读记录时基线取自己的最新消息序号，
因此刚入群且从未打开过房间的用户未读为 0。

权威在服务端。客户端只做本地乐观更新，并在下次摘要刷新时以服务端值为准。

### 5.2 三根支柱

| 支柱 | 现状 |
| --- | --- |
| 已读线单调：只前进，旧设备重放不得回退 | 已实现 |
| 成员区间变化时把已读线推进到当时的 head | 已实现：入群与房间创建路径在事务内初始化已读线；真实 PostgreSQL 回归随 Postgres 门禁执行 |
| 自己的已读线变化传播给该用户的全部设备 | 已实现（私聊与群聊）：水位真正前进时写入 `own_read_watermark` 投影，私聊路径同时镜像到目标用户分片；客户端单调保存为 `v2_room_read_watermarks`。群路径由回执 CTE 回传推进前的值来判断是否前进，重复上报同一序号不产生投影 |

第二条消除"离群期间的事件虚报未读"，并让重入后未读从零开始。若没有已读记录，
入群时写入初始已读线等于当时的 head。

第三条是一条用户级投影，内容仅为 `{room_id, read_through_room_sequence}`，走个人
控制流。**未读同步与内容同步是两件独立的事**：其他设备收到该投影即可把未读归零，
无需拉取任何消息内容。

### 5.3 补充规则

- 自己发送的消息不得计为未读。**该规则在未读计算层实现，而不是在发送路径推进已读线**：
  发送消息是全系统最热的路径，为它增加一次 `room_read_receipts` 写入会把它变成热表；
  更关键的是，已读线一旦被发送事务静默推进，读回执投影（对端"已读"指示）就失去了
  触发点，只能等下一次显式回执。因此未读计算排除读者自身作为发送者的事件：
  取该房间中自己最新消息的房间序号，与已读线取较大者后作差。该查询由
  `messages_room_sender_sequence_idx (room_id, sender_user_id, room_sequence DESC)`
  支撑，每房间一次索引查找。
- 上报的已读线必须校验上界：`readThroughRoomSequence ≤ rooms.room_sequence`。
- 未读推进必须幂等：同一操作 ID 重复提交只回放原结果。

### 5.4 进入房间 = 已读

| 本地状态 | 行为 |
| --- | --- |
| 本地已应用序号 ≥ head | 进入即推进，无需往返 |
| 本地落后 | 先补齐到 head，再推进 |
| 离线进入 | 用本地已知的最高已应用序号推进；服务端按 `max` 合并 |

**进入即已读清的是计数，不是义务。** 无论未读计数如何归零，设备仍必须把已读线
以下的内容补齐到本地；否则用户向上滚动会看到断档，这比当前的静默延迟更难排查。

**实现状态（已落地）**：客户端处于最新端时上报的已读线是**本设备已应用到的房间序号**，
而不是最后一条可见消息的序号——房间头包含编辑、撤回、reaction、置顶、公告、角色变更
这些非消息事件，只按消息序号上报会让"房间尾部是非消息事件"的房间未读永久停在 1。
可靠房间日志（私聊与混合大群）由 `v2_group_event_cursors.applied_room_sequence` 与只
追加的 `v2_group_events` 精确回答；标准扇出群没有持久化游标，退化为各投影自带的来源
序号取较大值。该序号追平服务端房间头时直接推进到 head，本地落后时只上报真实已应用
位置。房间头取自本地未读目录，没有轮转覆盖到的房间保持现状，不用本地推算冒充。

回归：App 侧固定"房间尾部是非消息事件时未读仍会清零"、"本地落后时不越界上报"、
"浏览历史位置时不推进"、"未知房间头时不凭空推进"；ClientKit 侧固定"只按可见消息序号
读已应用位置会漏掉编辑尾部"（把游标与事件表从查询里去掉时该用例会失败）。

**标准群不再有这条边界**：部署默认已经是 `room_log`（§9 第 3 步），新建标准群与私聊、
混合大群一样由本地游标精确回答，上面这条"扇出群没有持久化游标"的限制只会在**显式**
选择兼容基线（`IM_V2_GROUP_DELIVERY_AUTHORITY_MODE=fanout`）的环境里出现，那些环境
同时也就显式接受了"编辑/撤回尾部可能让未读停在 1"这一条。

### 5.5 静音

静音是展示层属性，不是计数层属性。未读计算完全不读取静音状态，静音只影响本地
通知、提示音与角标样式。

## 6. 保留窗口

保留下限的依据是**活跃用户的已读线**，不是设备扫描线：

```
floor(room) = MIN(read_through_room_sequence)
              over 仍活跃的用户
              且不新于 now − minimumRetentionWindow
```

只要日志保留在所有活跃用户的已读线之上，任何人打开房间都能完整补齐未读尾部；
已读线之前的历史不承担送达义务，可以安全裁剪。

### 6.1 两种模式

| 模式 | 配置 | 行为 |
| --- | --- | --- |
| 窗口 | 设备/用户放弃宽限 = N 天 | floor 只计入最近活跃的用户 |
| 永久 | 放弃宽限 = ∞ | 计入全部历史用户，无人追上则 floor 不推进 |

两种模式共用同一条代码路径，差异只是过滤条件。「永久」的实际含义是**被最慢的用户
钉住**，并非保留全部历史；因此永久模式必须配套用户/设备撤销清理与兜底上限，否则
存储无法收敛。

**实现状态（已落地）**：模式与宽限由 `IM_V2_ROOM_LOG_RETENTION_MODE`
（`permanent` 默认／`window`）与 `IM_V2_ROOM_LOG_RETENTION_WINDOW_SECONDS`（默认 30 天）
配置；下界由 `rooms.log_trimmed_through_room_sequence` 承载，单调只增。裁剪是本项目里
**唯一**允许删除房间事件的路径，触发器要求"语句显式声明这是保留裁剪"且"被删事件序号
低于该房间的下界"，两条同时满足才放行，因此事件对普通写入路径仍然是只追加的。
被裁剪过的房间同时退出进程内直聊日志缓存，避免缓存继续提供已删除的历史。

客户端一侧：`GroupEventPage` 新增 `log_trimmed_through_room_sequence`；客户端把它落进本地
游标行，并在"本页之前本地序号低于该下界"的那一刻置位**永久的**"历史不完整"标记
（缺口是服务端删掉的，不可能补齐）。对话页在时间线顶部显示"更早的消息已不可用"
（`v2.message.history-incomplete`），而不是把最近窗口当成完整历史。

### 6.2 边界规则

- **永久 → 窗口是破坏性变更**：会推进 floor 并删除仍被需要的日志，必须走审批与
  影响评估；反方向安全。配置变更只允许"变长"方向在线生效。
- 房间规模分档：小房间可精确计算活跃用户已读线的下界；大房间使用近似与时间窗口
  兜底，能力边界必须写进对外承诺。
- 新设备的初始窗口（从最近 N 条起步）独立于保留模式，两者不得混为一谈。
- 一旦判定历史不完整，必须显式标记，不得静默缺失。

## 7. 边界划分

| 内容 | 归属 |
| --- | --- |
| 房间内容：消息、编辑、撤回、reaction、公告、置顶、角色变更 | 房间事件日志 |
| 房间关系：成员变更、角色 | 个人控制流 |
| 用户级状态：联系人、资料、偏好、收藏、Push 意图、设备会话 | 个人控制流 |
| 自己的已读线 | 个人控制流 |

该划分使个人同步流从"承载全部消息"退化为"只承载控制状态"，其容量、保留与压缩
压力随之下降。

## 8. 房间数无上限的分级策略

单用户房间数无上限，因此**任何同步关键路径上都不得出现全量扫描**；所有遍历必须
有界分页，并可持久化轮转指针。

| 用户房间规模 | 未读聚合策略 | 精度承诺 |
| --- | --- | --- |
| 阈值以内 | 服务端一次精确聚合（成员索引扫描 + 主键点查） | 列表页与总数均精确 |
| 超过阈值 | 活跃窗口优先 + 客户端有界轮转补齐 | **列表页内精确**；总角标允许有界滞后，并声明收敛时间上限 |

固定规则：

- **服务端摘要页**内每一行的房间未读必须精确——页是有界的，必须算准。
- 客户端本地列表的角标来自有界轮转的目录，因此**轮转尚未覆盖到的房间不显示角标**：宁可暂时
  少显示，也不用本地推算冒充服务端值。覆盖顺序按活动倒序，冷房间由持久化轮转指针补齐。
- 只有跨全部房间的聚合值（如 App 图标总角标）在大房间规模下允许滞后。
- 轮转指针必须持久化，保证长期不活跃的房间最终也会被检查到。
- 服务端不得为"未读待办"引入 per-member 写索引：那会把每条消息的写放大乘以成员数，
  正是本方案要消除的成本。

### 8.1 "无上限"的直接后果

上限是聚合口径问题，不是准入问题：**不设房间数配额**，房间数不得成为拒绝建群、
拒绝加入、拒绝发送或同步失败的理由。阈值只切换聚合策略，不改变一个人能加入多少房间。

- 任何按用户枚举房间的查询都必须走 `room_memberships (user_id, …)` 的有界索引分页；
  请求路径上不得出现无 `LIMIT` 的全量读取。
- 会话列表首屏只取有活动的房间（`rooms_last_event_at_idx`）；冷房间由持久化轮转指针
  在后台补齐，不阻塞首屏。
- 客户端本地存储随房间数线性增长，必须支持按房间的懒加载与淘汰；首启同步、备份恢复
  与设备迁移都不得依赖"扫描全部房间"。
- 服务端不得为用户物化"全部房间"的聚合视图；此类视图的成本随房间数增长，正是本方案
  要避免的形态。

## 9. 迁移路径

| 步骤 | 内容 | 风险 |
| --- | --- | --- |
| 1 | **重试分类**（不改模型）：瞬时错误无限重试并封顶退避；确定性错误立即暂停。**已实现**：策略新增失败类别与判定入口；全部 9 处生产重试分支（fan-out 投递、outbox relay 两处、媒体扫描、媒体清理、内容审核、转发投递、转发媒体导入、已读偏好传播）均已分类；room outbox 与 fan-out delivery 的"最老未完成年龄"指标及 `IMV2Stalled*` 告警已落地，停滞由年龄而非暂停计数发现。预算制处置入口保留，但仅供测试夹具与显式构造暂停状态的调用方使用。**按来源事件的批量重放已实现**：只回放指定事件下的暂停行，带 1...500 的行数上限，逐行审计由批量标识稳定派生；`read_receipt_preference_propagation`／`user_projection` 仍只支持单目标 | 低 |
| 2 | **单聊切 `room_log`**：**已实现**。部署默认改为 `room_log`（不配置即为目标架构，兼容基线必须显式选 `planner`）；`edit`／`withdraw`／`reaction` 本来就只写房间事件日志、不产生逐用户投递副本，`moderation` 的扇出由第 1 步的分类与年龄告警覆盖；客户端把私聊房间纳入游标同步集合，并有回归固定该性质 | 中 |
| 3 | **标准群推广读模型**：**已实施，并已成为部署默认**。房间新增 `delivery_authority`（schema 32），群聊的权威副本形态由它决定：混合大群恒为 `room_log`，标准群取创建时的部署策略 `IM_V2_GROUP_DELIVERY_AUTHORITY_MODE`，**不配置即为 `room_log`**；兼容基线必须显式选 `fanout`。按房间切到 `room_log` 后，消息只写房间事件日志、不产生任何逐用户投递行，客户端按房间游标恢复；`edit`／`withdraw`／`reaction` 本就只写日志，mention 已改为通知（前置条件 3）。默认切换同时消除了 §5.4 的扇出群未读边界 | 高 |

第 1 步是迁移期安全网，不是目标架构的组成部分。

**判定范围（按数据库回归校正）**：只有**消息与房间写入路径**的 `corruptPersistenceState`
（载荷身份、投影状态、队列序号或既有回执不自洽）判为确定性——那是毒丸行真正出现的地方。
其余存储的同名 case 不判为确定性：它们在时钟、延迟或容量无法编码时走的是**优雅降级**
路径（例如 forward export 的 `pendingDelay` 无法编码时回退到重试策略），判为确定性会
破坏既有降级行为并让可恢复的工作停工。

第 2 步的**回滚**是配置项而不是代码：把 `IM_V2_DIRECT_FANOUT_MODE` 显式设回 `planner`
并滚动重启即可；本地 E2E 与分阶段 profile 都显式选择模式，因此默认值变化不会悄悄改变
它们的验证目标。

**已有画像都显式固定模式**：负载、池隔离、归档基线与本地叠加层（
`docker-compose.gateway-loadtest.yml`、`docker-compose.gateway-pool-isolated.yml`、
`docker-compose.benchmark-hot-baseline-9c8de4fb.yml`、`docker-compose.server-override.yml`、
`docker-compose.local-account.yml`、`docker-compose.gateway-shared.yml`）在两次默认值
切换（第 2 步的 `IM_V2_DIRECT_FANOUT_MODE` 与第 3 步的
`IM_V2_GROUP_DELIVERY_AUTHORITY_MODE`）时都补上了显式配置：历史数字与各自的验证目标
不会因为默认值变化而改变。把这些画像切到 `room_log` 是各自独立的、需要重新跑通验证的
动作；`docker-compose.direct-room-log.yml` 与 `docker-compose.room-shard-validation.yml`
本来就显式选择读模型，因此跟随新默认。

## 10. 第 3 步的前置条件

1. **所有房间内容的读取入口按历史授权收口（事件发生时成员 ∩ 当前成员）。已收口**，
  逐入口证据如下；谓词本体是 `v2ForwardSourceVisibility(actorID:)` 与房间日志拉取里
  等价的内联谓词，两处都要求"加入修订 ≤ 事件提交修订"且"离开修订 > 事件提交修订"，
  并且在分页 `LIMIT` 之前过滤。

   | 入口 | 谓词 |
   | --- | --- |
   | 房间日志拉取 | 当前成员 ∩ 事件提交修订（`PostgresV2GroupEventLogStore.pull`） |
   | 会话摘要预览 | 同上（`PostgresV2RoomSummaryStore.visibleMessages`） |
   | 媒体授权 | `v2ForwardSourceVisibility`（`PostgresV2MediaVisibilityAuthorization`） |
   | 转发来源 | `v2ForwardSourceVisibility`（转发、导出、媒体导入、群能力共用） |
   | 引用与置顶目标 | `v2ForwardSourceVisibility`（`PostgresV2GroupCapabilitiesStore`） |
   | 已读者目录 | 历史 ∩ 当前（`PostgresV2ReadReceiptStore.readers`） |
   | 个人快照与投影 | 按该用户已投递的接受事实（`user_projection_versions`）重建，不跨用户读取 |

   回归：`mediaAuthorizationFollowsTheMembershipGap` 用"加入→离开→重入"的区间夹出空档，
   并**刻意伪造一条陈旧投递投影**，断言空档期媒体仍被拒绝、区间内媒体照常放行，且房间
   日志与摘要给出同一结论。若谓词退化成"只看当前成员"，该用例会直接放行空档内容并失败。
2. **客户端具备全房间游标与聚合水位能力。已具备**：房间是否按游标恢复由**服务端宣告**
   （`delivery_authority`），客户端不再从 `delivery_mode` 推断。

   为什么要新开一个字段而不是复用投递模式：`rooms.delivery_mode` 描述用哪种扇出规划器，
   并且在房间创建后**不可变**（有触发器拒绝修改）；"哪一份是权威副本"却要能按房间推进，
   否则标准群永远无法切到读模型。两者今天取值一致（混合大群与标准群默认都是
   `room_log`），差异正是 §9 第 3 步已经打开的那一处。

   | 层 | 行为 |
   | --- | --- |
   | 服务端 | 房间创建与成员变更投影载荷都带 `delivery_authority`；推导规则集中在一处 |
   | 客户端 | `v2_room_profile_projections` 保存该字段；游标同步集合、`isKnownRoomLogRoom`、`groupEventAccess`、快照导入都按它取房间 |
   | 单调性 | 只向 `room_log` 前进：少拉一次会让客户端收不到只写日志的内容，多拉一次只是幂等重复 |
   | 缺字段 | 按不可解码拒绝：项目未上线，客户端不保留"缺字段就按投递模式推断"的静默回退（`enrollmentRejectsMissingAuthority`） |

   回归：服务端断言创建投影携带该字段；客户端断言"标准投递模式 + `room_log` 权威"会被
   纳入游标同步、"标准投递模式 + `fanout`"不会、缺字段被拒绝、以及较弱的后续声明不会
   把房间退回个人流。
3. **明示 mention 的可靠投递重新定位：已完成。** 房间日志房间里的显式 `@` 不再创建
   任何逐用户投递（`hybrid_mention_targets` 计划、`fanout_plan_targets` 与 `room_outbox`
   都不再产生），只给被 @ 成员的有效设备入队**通知**（`push_wake_outbox`），内容仍靠
   房间游标恢复。这样提及不再是"必须送达的副本"，也就不会留下"发送成功、通知永远发不出去
   且无人知晓"的失败面。

   | 方面 | 行为 |
   | --- | --- |
   | 入队 | 与消息接受同事务，外键绑定源事件；单条消息最多 32 名被 @ 成员、每人最多 5 台有效设备 |
   | 准入 | 复用既有推送消费侧：活动启用 + 按设备、按 UTC 整点的预算；预算缺失只把唤醒标记为 `suppressed`，不影响消息 |
   | 默认 | 未创建活动时不产生通知行，静默关闭；启用步骤见 [推送通知运维手册](../../IMV2/docs/10-operations/push-wake-notifications-runbook.md) |
   | 审计形态 | 每条房间日志消息仍保留一条零目标的终端计划行，因此操作结果形状不变，但全局扇出在结构上不可能发生 |

## 11. 待决定

| 事项 | 建议 |
| --- | --- |
| 静音房间是否计入 App 总角标 | 不计入，否则静音形同虚设 |
| 打开房间时未读量极大（如数千条） | 自动补齐到未读起点，分批渲染 |
| 「永久」模式的兜底上限 | 365 天（**已实现为部署配置**：需要收敛存储的部署应选 `window`；选 `permanent` 即接受不裁剪） |
| 保留窗口的配置粒度 | 先全局 + 按房间类型，不做每房间自由配置（**已实现为全局配置**） |
| 未读聚合的规模阈值与收敛时间上限 | 需按实测确定 |

## 12. 明确不做

- 维护两份都作为权威的持久副本。
- 服务端为每个用户维护"房间活动/未读待办"索引（每条消息 × 每个成员一次写）。
- 通过加长重试预算或调高告警阈值来规避问题。
- 把"在线推送、离线拉取"实现为两套投递语义或两条权威路径。

## 13. 可独立落地、不依赖迁移决策的部分

| 事项 | 依赖与现状 |
| --- | --- |
| 未读支柱二：成员区间变化推进已读线 | 无外部依赖。**已完成**：入群（`v2InitializeJoinedMemberReadWatermark`）与房间创建（`v2InitializeNewRoomReadWatermarks`）在各自事务内把已读线初始化到当时的 head |
| 未读支柱三：自己的已读线投影给自己的设备 | 无外部依赖。**已完成**（私聊与群聊两条路径） |
| 重试分类、年龄指标与运维重放 | 无外部依赖。**已完成**：失败分类判定入口 + 全部 9 处生产重试分支分类 + `IMV2Stalled*` 年龄告警；operator 单目标重放与按来源事件的批量重放均已实现（后者带 1...500 行数上限与逐行派生审计） |
| `rooms.last_event_at` | **已完成**：列、`rooms_touch_last_event_at` 触发器（只在房间序列前进时刷新）、倒序索引、readiness 校验、可重复执行的 30→31 迁移与漂移门禁均已落地并验证；同一批还加入 `messages_room_sender_sequence_idx` |
| 房间摘要聚合接口 | 依赖上两行。**已实现**：`V2RoomSummaryService`／`V2RoomSummaryStore` 定义接口，`PostgresV2RoomSummaryStore` 用两个各自有界的查询实现，`V2RoutedRoomSummaryStore` 负责跨分片扇出；细节见 §13.3 |
| 摘要命令的线协议、网关与客户端传输 | **已实现**：protobuf 新增 `RoomSummaryList`／`RoomSummaryPage`（帧命令 109／110，wire 兼容新增，不改 protocol 27 协商）；网关校验不透明游标后调用摘要服务；客户端传输层 `roomSummaries(cursor:pageSize:)` 已校验未读不超过房间头、预览序号不越过房间头 |
| 客户端未读展示与全房间游标 | **已实现**：本地未读目录 + 持久化轮转游标 + 展示换算规则；App 会话列表按房间标识取未读并显示角标。细节见 §13.5 |

上面各项均已交付并通过真实数据库验证。特别注意第 4 行：客户端与 App **原本完全没有
未读概念**（会话列表模型里没有未读字段），这一列是新增能力而非既有能力的修复；列表仍然
是本地优先，只有未读与房间头来自服务端（§4）。

### 13.1 实施约束（复核代码后确认）

- **支柱三必须服务端与客户端同批落地。** 客户端对未知投影类型会抛出错误并回滚整个
  同步事务，因此服务端先发出新投影类型会让所有客户端无法应用增量。
- **支柱三的客户端一半就是客户端未读状态。** 两者操作同一份数据（房间已读水位），
  必须一起设计，否则会先加一张本地表、随后再改一次。
- **重试分类需要先确定分类机制。** 现有 `last_failure_code` 是写入 SQL 的字面量
  （`worker_failure`、`retry_exhausted`），没有错误到类别的映射函数；分类需要新增
  明确的判定入口，不能靠字符串匹配。
- **`rooms.last_event_at` 属于发布行为。** 新增列需要同时更新 canonical schema、
  迁移链、`V2SchemaReadiness` 与 schema 漂移门禁，且必须由 Postgres 门禁验证。

### 13.2 本地数据库验证（可复现）

本机没有 Docker，但存在 Homebrew PostgreSQL 二进制，因此数据库级改动可以不经容器验证：

```sh
# 两个一次性集群（官方集成脚本的等价形态）
initdb -D <dir1> -U im_v2_test --auth=trust && pg_ctl -D <dir1> -o "-p 55431" start
initdb -D <dir2> -U im_v2_test --auth=trust && pg_ctl -D <dir2> -o "-p 55432" start
createdb -h 127.0.0.1 -p 55431 -U im_v2_test im_v2_test
createdb -h 127.0.0.1 -p 55432 -U im_v2_test im_v2_test

IMV2_POSTGRES_TEST_DATABASE_URL='postgres://im_v2_test@127.0.0.1:55431/im_v2_test' \
IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL='postgres://im_v2_test@127.0.0.1:55432/im_v2_test' \
IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE=1 \
IMV2_REQUIRE_CROSS_STORE_POSTGRES_TESTS=1 \
swift test --package-path IMV2Server
```

第 1 步、支柱二、支柱三（双路径）与年龄指标的数据库行为均由该套件覆盖；改用临时集群
后单轮耗时约 27 分钟，定向筛选（`--filter`）可把单点验证压到数秒。

### 13.3 房间摘要聚合接口（已实现）

接口：`V2RoomSummaryService` + `V2RoomSummaryStore`，返回值每行包含
`roomID / roomKind / head / lastEventAt / unreadCount / latestMessage`。分页键是
`(last_event_at DESC, room_id DESC)`，与房间序号、个人时间线序号无关。

**两个各自有界的查询**，而不是一个覆盖全部房间的巨型 join：

| 查询 | 内容 | 支撑索引 |
| --- | --- | --- |
| `roomActivityWatermarks` | 按活动倒序取一页房间，携带 head、未读数 | `rooms_last_event_at_idx` 顺序扫描 + `room_memberships_pkey` 逐房间校验 + `messages_room_sender_sequence_idx` 取"自己最新消息" |
| `visibleMessages` | 只对本页房间求最新可见消息 | 两种接受形态各自按房间序号倒序扫描并在第一行停下：`room_events_room_id_room_sequence_event_type_key`、`messages_room_timeline_sequence_key` |

跨分片部署下由 `V2RoutedRoomSummaryStore` 展开：每个**物理**存储最多查询一次
（逻辑分片可能共用同一个库），各自返回自己的前 `limit` 行后按
`(last_event_at DESC, room_id DESC)` 合并取全局前 `limit` 行。全局前 N 行必然包含在
各存储的前 N 行里，因此页边界与单库实现一致；只有在所有存储都取尽时 `hasMore` 才为
`false`。扇出宽度随物理存储数增长，不随房间数增长。

**可见性复用同一谓词**：摘要与房间日志读取都用"事件发生时成员 ∩ 当前成员"。这不是
为摘要单独放宽的规则，而是同一条：若摘要比日志多显示内容，历史授权就被旁路了。测试
用同一批数据分别调用摘要与房间日志读取，断言两者对"最后一条可见消息"结论一致。

**规模证据（真实 PostgreSQL）**：20,000 个房间、其中 10,000 个属于查询用户的库里，
一页 20 行的查询计划走 `rooms_last_event_at_idx`，实际只读 22 行、166 个缓冲区；预览
查询在 500 条历史的房间上只读 1 行事件（改写前是 500 行 + 排序），代价是"最近的可见
事件"而不是"该房间的全部历史"。

**分页键精度证据**：游标里的时间戳是微秒整数。把同一段 SQL 临时降级成毫秒后，
真实数据库回归立刻失败——同一毫秒内更早 300 微秒的房间从第二页消失；恢复微秒后通过。
这条断言因此不是"看起来对"，而是能区分正确与错误实现。

**已知边界**：摘要不承担完整性。最新事件载荷无法解码时，该房间预览为空，正文仍可经
房间日志按游标拉取；这是刻意的降级，不是静默丢消息。

**当前消费方**：客户端把摘要写进本地未读目录（未读与 head），列表的预览与排序仍来自本地
投影（见 §4）。摘要里的 `latestMessage` 因此暂时只用于工具与未来可能的列表源切换，界面
不依赖它；如果将来要把列表源整体切到服务端摘要，这一段已经就绪，不需要新增协议。

### 13.4 线协议与客户端传输（已实现）

| 层 | 内容 |
| --- | --- |
| 协议 | `RoomSummaryList`（`cursor`、`page_size`）／`RoomSummaryPage`，帧命令 109／110；新增 oneof 字段属兼容变更，**不改变** protocol 27 的协商范围 |
| 网关 | 解析不透明游标（base64 + 版本号，失败一律 `INVALID_ARGUMENT`），按已认证身份取一页，回填 `next_cursor` |
| 客户端 | `V2ClientRoomSummaryTransport.roomSummaries(cursor:pageSize:)`：校验未读不超过房间头、预览序号不越过房间头、房间标识不重复、游标不超预算 |

游标是**不透明字符串**，客户端不得解析或拼接。服务端游标载荷只含排序键
`(last_event_at 的微秒整数, room_id)`：不携带授权信息，因为每一页都重新按当前成员
资格过滤，伪造游标既不能越权也不能改变可见集合；这也让"游标跨设备复用"没有安全含义。

预览正文在服务端按 ``V2RoomSummaryLimits/maximumPreviewCharacters``（80 个字符）截断。
这不是偷懒：它是"一页 100 个房间仍留在 64 KB 帧预算内"的前提，测试用最坏情况
（整页 × 80 个 4 字节字符 × 最长游标）断言整页仍小于帧预算。正文永远以房间游标为准。

### 13.5 客户端未读展示与全房间轮转（已实现）

会话列表是本地优先的：房间标题、置顶、免打扰都来自本地投影。未读数却只能由服务端给出，
因此客户端做的是**复制一份未读目录**，而不是自己推算未读：

| 组件 | 职责 |
| --- | --- |
| `V2ClientRoomUnreadDirectoryStore`（GRDB 实现） | 每个房间一条 `{head, 未读, 活动时间}`，外加单例轮转游标与轮次 |
| `V2ClientConversationUnreadDirectory` | 每次刷新只走给定页数，写入目录并推进持久化游标；一轮走完后从最新活动重新开始，并淘汰本轮没再出现的房间 |
| `V2ClientConversationUnread.displayedUnread` | 唯一换算规则（下） |
| App `V2GRDBConversationDataSource` | 列表按房间标识取未读：`refresh(pageBudget: 1)` 推进轮转，再按本页房间批量读一次目录 |

换算规则只减不增：

```
展示未读 = min(服务端未读, max(head − 本地已读水位, 0))
```

本地水位领先服务端（刚进入房间、回执还在路上）时取更小的本地值，这正是"进入房间即已读"
无需等待往返的原因；本地水位落后服务端时取服务端值，绝不虚报。任何本地状态都不可能让
展示值超过服务端值。

**本地已读水位包含未发送的回执。** `roomReadWatermark` 取"服务端投影"与"本设备已入队或
已确认的回执"的较大值；被拒绝的回执不计入。App 在消息进入可见区域时已经上报回执，因此
角标会立即归零，离线打开房间同样成立。

**进入房间的推进按 §5.4 写回服务端。** 处于最新端时上报的是本设备已应用到的房间序号
（追平房间头时直接上报 head），因此房间尾部是非消息事件时未读不会再停在 1。上报走本地
持久回执队列，离线进入同样成立；回执队列暂时接不下时，下一次刷新会重试。

**冷房间靠轮转补齐，而不是靠推算。** 一次刷新只走一页（最活跃的房间最先刷新），轮转游标
持久化，进程重启后从断点继续。目录还没覆盖到的房间不显示角标——宁可暂时不显示，也不用
本地数据冒充服务端的计数。

## 14. 验收不变量

1. **未读收敛**：同一用户的多台设备，在已读线传播收敛后，查询同一房间得到相同的
   未读数。
2. **进入即已读**：进入房间并补齐后，该房间未读为 0；传播收敛后其他设备的同一房间
   未读也为 0。**房间尾部只有非消息事件时同样成立**（见 §5.4 的实现状态）。
3. **静音不影响计数**：静音房间与非静音房间走同一条未读计算路径，差异仅在提醒行为。
4. **无永久停滞**：任何一条已被 `MessageAccepted` 的消息，最终要么对全部授权收件人
   可见，要么留下显式的终态记录；不得存在既未送达、也不可见、也不告警的状态。
5. **不静默缺失**：保留窗口之外的历史必须显式标记为不完整。**已实现**：服务端回报裁剪
   下界，客户端置位永久标记，对话页顶部显示"更早的消息已不可用"。
6. **推送不是依据**：丢弃或重复全部实时提示后，客户端仍能通过拉取达到与推送存在时
   相同的最终状态。
7. **无全量扫描**：房间数达到阈值以上时，同步关键路径的单次请求成本不随房间总数
   线性增长。
8. **无准入上限**：房间数不构成拒绝建群、拒绝加入或拒绝发送的理由；规模阈值只切换
   聚合策略，不改变可加入的房间数。

## 15. 依据

| 结论 | 依据 |
| --- | --- |
| 重试预算耗尽后暂停且不转终态 | [V2DurableRetryPolicy.swift](../../IMV2Server/Sources/IMV2Server/V2DurableRetryPolicy.swift)、[PostgresV2RoomOutboxStore.swift](../../IMV2Server/Sources/IMV2Server/PostgresV2RoomOutboxStore.swift) |
| 暂停行不被领取、不被 GC | [PostgresV2RoomOutboxStore.swift](../../IMV2Server/Sources/IMV2Server/PostgresV2RoomOutboxStore.swift)、[V2ControlPlaneHousekeepingWorker.swift](../../IMV2Server/Sources/IMV2Server/V2ControlPlaneHousekeepingWorker.swift) |
| 告警与 runbook | [imv2-alerts.yml](../../IMV2/observability/prometheus/imv2-alerts.yml)、[durable-work-operator-replay.md](../../IMV2/docs/10-operations/durable-work-operator-replay.md) |
| 默认私聊也走扇出 | [IMV2Server/.env.example](../../IMV2Server/.env.example) |
| 已读线单调、只投影给对方 | [PostgresV2ReadReceiptStore.swift](../../IMV2Server/Sources/IMV2Server/PostgresV2ReadReceiptStore.swift) |
| 入群/建群初始化已读线 | [PostgresV2RoomReadWatermark.swift](../../IMV2Server/Sources/IMV2Server/PostgresV2RoomReadWatermark.swift)、[PostgresV2RoomMembershipStore.swift](../../IMV2Server/Sources/IMV2Server/PostgresV2RoomMembershipStore.swift) |
| 投递失败的瞬时/确定性分类 | [V2DurableWorkFailureClassification.swift](../../IMV2Server/Sources/IMV2Server/V2DurableWorkFailureClassification.swift)、[V2DurableRetryPolicy.swift](../../IMV2Server/Sources/IMV2Server/V2DurableRetryPolicy.swift) |
| 房间活动时间与未读索引 | [schema.sql](../../IMV2/sql/schema.sql)、[20260911_room_last_event_at.sql](../../IMV2/sql/migrations/20260911_room_last_event_at.sql) |
| 摘要聚合接口实现 | [V2RoomSummaryService.swift](../../IMV2Server/Sources/IMV2Server/V2RoomSummaryService.swift)、[PostgresV2RoomSummaryStore.swift](../../IMV2Server/Sources/IMV2Server/PostgresV2RoomSummaryStore.swift)、[V2RoutedRoomSummaryStore.swift](../../IMV2Server/Sources/IMV2Server/V2RoutedRoomSummaryStore.swift) |
| 摘要行为测试（含真实数据库） | [V2RoomSummaryStoreTests.swift](../../IMV2Server/Tests/IMV2ServerTests/V2RoomSummaryStoreTests.swift) 与 `PostgresV2RoomWriteStoreIntegrationTests.swift` 中的 `roomSummaryAggregation`／`roomSummaryMatchesRoomLogVisibility` |
| 摘要的线协议 | [im_v2.proto](../../Protocol/im_realtime/v2/im_v2.proto) 的 `RoomSummaryList`／`RoomSummaryPage`、[V2FrameCodec.swift](../../IMV2Core/Sources/IMV2Core/V2FrameCodec.swift) 的帧命令 109／110 |
| 摘要网关与客户端传输 | [V2GatewayDomainCommandHandler.swift](../../IMV2Server/Sources/IMV2Server/V2GatewayDomainCommandHandler.swift) 的 `handleRoomSummaryList`、[V2RoomSummaryCursorCodec.swift](../../IMV2Server/Sources/IMV2Server/V2RoomSummaryCursorCodec.swift)、[V2ProtobufSyncTransport.swift](../../IMV2ClientKit/Sources/IMV2ClientKit/V2ProtobufSyncTransport.swift) 的 `roomSummaries` |
| 客户端未读目录与展示规则 | [V2ConversationUnreadDirectory.swift](../../IMV2ClientKit/Sources/IMV2ClientKit/V2ConversationUnreadDirectory.swift)、[V2ConversationUnreadModel.swift](../../IMV2ClientKit/Sources/IMV2ClientKit/V2ConversationUnreadModel.swift)、[V2ConversationDataSource.swift](../../IMApp/IMApp/V2/V2ConversationDataSource.swift)、`V2ConversationUI.swift` 的角标渲染 |
| 有效已读水位（含未发送回执） | [GRDBV2LocalSyncStore.swift](../../IMV2ClientKit/Sources/IMV2ClientKit/GRDBV2LocalSyncStore.swift) 的 `roomReadWatermarks(roomIDs:)` |
| 进入房间推进到已应用序号／房间头（含非消息事件） | [V2ConversationDetailStore.swift](../../IMApp/IMApp/V2/V2ConversationDetailStore.swift) 的 `advanceReadLineWhenAtLatestEnd`、[V2ConversationDataSource.swift](../../IMApp/IMApp/V2/V2ConversationDataSource.swift) 的 `roomReadCheckpoint(roomID:)`、[GRDBV2LocalSyncStore.swift](../../IMV2ClientKit/Sources/IMV2ClientKit/GRDBV2LocalSyncStore.swift) 的 `roomAppliedRoomSequence(roomID:)`、[V2ConversationUnreadDirectory.swift](../../IMV2ClientKit/Sources/IMV2ClientKit/V2ConversationUnreadDirectory.swift) 的 `knownHeads(roomIDs:)` |
| 房间权威副本形态（服务端宣告） | [V2RoomDeliveryAuthority.swift](../../IMV2Server/Sources/IMV2Server/V2RoomDeliveryAuthority.swift)、[V2ClientRoomDeliveryAuthority.swift](../../IMV2ClientKit/Sources/IMV2ClientKit/V2ClientRoomDeliveryAuthority.swift)、[V2RoomProfileProjection.swift](../../IMV2ClientKit/Sources/IMV2ClientKit/V2RoomProfileProjection.swift) |
| 提及通知（替代逐用户可靠投递） | [V2MentionPushWake.swift](../../IMV2Server/Sources/IMV2Server/V2MentionPushWake.swift)、[推送通知运维手册](../../IMV2/docs/10-operations/push-wake-notifications-runbook.md) |
| 标准群切读模型的房间开关 | [V2RoomDeliveryAuthority.swift](../../IMV2Server/Sources/IMV2Server/V2RoomDeliveryAuthority.swift)、[20260912_room_delivery_authority.sql](../../IMV2/sql/migrations/20260912_room_delivery_authority.sql) |
| 保留窗口与"历史不完整"标记 | [V2RoomLogRetention.swift](../../IMV2Server/Sources/IMV2Server/V2RoomLogRetention.swift)、[20260913_room_log_retention.sql](../../IMV2/sql/migrations/20260913_room_log_retention.sql)、`PostgresV2GroupEventLogStore.pull` 的裁剪下界、`GRDBV2LocalSyncStore.roomLogHistoryIsIncomplete` |
| 上线与回滚步骤 | [房间读模型上线手册](../../IMV2/docs/10-operations/room-read-model-rollout-runbook.md) |
| 房间日志与序号 | [schema.sql](../../IMV2/sql/schema.sql) 的 `room_events`、`rooms`、`room_read_receipts` |
| 已具备的按房间游标与目录扫描 | [V2GroupEventSync.swift](../../IMV2ClientKit/Sources/IMV2ClientKit/V2GroupEventSync.swift) |
| 推送加速载荷可降级为纯提示 | [V2TLSFrameConnection.swift](../../IMV2ClientKit/Sources/IMV2ClientKit/V2TLSFrameConnection.swift) |

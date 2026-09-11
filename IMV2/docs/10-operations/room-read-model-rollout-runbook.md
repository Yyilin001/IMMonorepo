# 房间读模型上线手册

状态：能力与开关均已实现并通过真实数据库回归；本手册记录**部署动作**与回滚手段。
项目未上线，因此没有需要迁移的既有生产房间——所有房间都会由新代码按下面的策略创建。

方案与不变量见[房间读模型合同](../../../docs/reviews/room-read-model-contract.md)。

## 开关一览

| 开关 | 取值 | 默认 | 作用 |
| --- | --- | --- | --- |
| `IM_V2_DIRECT_FANOUT_MODE` | `room_log` / `preplanned` / `planner` | `room_log` | 单聊的权威副本；`planner` 是兼容基线，也是回滚手段 |
| `IM_V2_GROUP_DELIVERY_AUTHORITY_MODE` | `room_log` / `fanout` | `room_log` | **新建**标准群的权威副本形态；混合大群恒为 `room_log`；`fanout` 是兼容基线 |
| `IM_V2_ROOM_LOG_RETENTION_MODE` | `permanent` / `window` | `permanent` | 房间日志保留：永久（不裁剪）或按活跃读者窗口裁剪 |
| `IM_V2_ROOM_LOG_RETENTION_WINDOW_SECONDS` | 正整数 | 30 天 | 窗口模式下读者不再钉住日志下界的宽限 |

推进读模型的顺序建议：**先只读验证 → 再放量写入路径 → 最后收窄保留窗口**。
前两步的部署默认都已经是目标形态（`room_log`），需要显式决定的只剩保留窗口；
保留窗口是唯一会删除数据的开关，永远放在最后，并且只允许"变长"方向在线调整。

## 第 1 步：单聊（默认已是目标形态）

新部署不配置 `IM_V2_DIRECT_FANOUT_MODE` 即为 `room_log`。需要回到兼容基线的环境必须显式
选择 `planner`（负载、池隔离、归档基线与本地叠加层就是这么固定的）。

验证：

```sql
-- 单聊消息不应再产生逐用户投递；发送完成记录应声明 room_log 权威。
SELECT count(*) FROM im_v2.fanout_deliveries AS delivery
JOIN im_v2.rooms AS room ON room.room_id = delivery.room_id
WHERE room.room_kind = 'direct';
```

```sql
SELECT delivery_authority, count(*)
FROM im_v2.message_send_completions
WHERE group_delivery_mode IS NULL
GROUP BY delivery_authority;
```

期望：直聊扇出投递为 0，完成记录的权威形态为 `room_log`。客户端表现是"按房间游标恢复"，
推送只是提示（见[推送通知手册](push-wake-notifications-runbook.md)）。

## 第 2 步：标准群（默认已是目标形态）

新部署不配置 `IM_V2_GROUP_DELIVERY_AUTHORITY_MODE` 即为 `room_log`：**新建**标准群直接以
房间日志为权威副本，不再产生 `fanout_plan_targets` / `fanout_deliveries` / 对应
`room_outbox`，客户端按房间游标恢复；`edit`／`withdraw`／`reaction` 本来就只写日志，
`@` 走通知。需要回到兼容基线的环境必须显式选择 `fanout`（负载、池隔离、归档基线、
本地叠加层与投影共享叠加层就是这么固定的）。

```sql
-- 新建标准群的权威副本形态分布。
SELECT delivery_authority, count(*)
FROM im_v2.rooms
WHERE room_kind = 'group' AND delivery_mode = 'standard_fanout'
GROUP BY delivery_authority;
```

**既有房间的形态不可就地翻转**：`rooms.delivery_mode` 有不可变触发器，而
`delivery_authority` 的变更必须能先被客户端读到（客户端只在房间/成员投影里收到该字段），
否则切换瞬间会出现"服务端已停止逐用户投递、客户端还在等个人流"的窗口。项目未上线，
没有这类存量房间；将来若确实需要迁移既有房间，必须先实现并验证一条显式的
"权威副本形态变更"事件与过渡期扇出加速，再执行，不要直接改列。

**为什么默认是 `room_log`**：读模型房间的未读按本设备已应用到的房间序号推进到房间头
（[合同 §5.4](../../../docs/reviews/room-read-model-contract.md)）。扇出群没有持久化游标，
"房间尾部恰好只有一条编辑或撤回"时未读会停在 1；标准群切到 `room_log` 后这个边界消失，
因此它同时也是未读正确性的前提，而不只是一个容量选择。

观察指标：`im_v2_room_outbox_backlog`、`im_v2_fanout_delivery_backlog` 应随切换下降；
`IMV2Stalled*` 告警（最老未完成年龄超过 30 分钟）必须保持为 0。

## 第 3 步：保留窗口（会删数据，最后做）

默认 `permanent`，即"计入全部历史读者的已读线、没有人追上就不推进"，等价于不裁剪。
切到 `window` 之前必须确认：

1. 客户端已经能处理 `log_trimmed_through_room_sequence` 并显示"更早的消息已不可用"；
2. 窗口长度覆盖产品承诺的离线上限（默认 30 天）；
3. 这一步是**破坏性**的：窗口外读者返回时会看到历史不完整，属于已批准的产品行为。

```sql
-- 当前各房间的裁剪下界与非零值数量。
SELECT count(*) FILTER (WHERE log_trimmed_through_room_sequence > 0) AS trimmed_rooms,
       min(log_trimmed_through_room_sequence) AS lowest_floor
FROM im_v2.rooms;
```

回滚：把模式改回 `permanent` 只会停止继续裁剪，**已经删除的历史不会回来**；因此窗口
长度只允许在线调大，调小必须走审批与影响评估。

## 回滚手段总表

| 目标 | 动作 | 影响 |
| --- | --- | --- |
| 单聊回到兼容基线 | `IM_V2_DIRECT_FANOUT_MODE=planner` 并滚动重启 | 立即恢复逐用户投递；房间日志仍是完整副本 |
| 新建群回到兼容基线 | `IM_V2_GROUP_DELIVERY_AUTHORITY_MODE=fanout` | 只影响之后新建的标准群 |
| 停止裁剪历史 | `IM_V2_ROOM_LOG_RETENTION_MODE=permanent` | 停止继续删除；已删除的不可恢复 |
| 清理暂停工作 | operator 单目标重放或按来源事件批量重放 | 见[运维重放手册](durable-work-operator-replay.md) |

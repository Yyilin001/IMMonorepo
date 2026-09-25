# 直聊 room-log 单机压测记录（2026-08-19）

状态：历史实验记录。文中的 `IM_V2_DIRECT_FANOUT_MODE` 和旧扇出表已从当前运行时与 schema 删除，不能据此配置当前部署；当前范围见[实现状态](../implementation-status.md)。

这是一份当时版本的实验记录，不是当前版本或生产容量承诺。

## 环境与方法

- 单台 ARM64 8 vCPU / 16 GiB Gateway + PostgreSQL，同一可丢弃压测数据库；内容审核关闭。
- `IM_V2_DIRECT_FANOUT_MODE=room_log`，1,000 TLS 连接，三个直聊目标/连接，128-byte 文本，
  60 秒 hold，连接与业务均以受控 ramp 启动。
- 每次正式读写实验先清空测试消息、fanout、sync 与 admission 计数；保留测试身份和 schema。
  测试客户端同时执行发送和 `--room-log-reads 1`，即 ACK 后以 per-room cursor 拉取。
- 400/600/800 档均从没有历史消息的 room corpus 启动，因此 room-event 延迟代表增量读取。

## 结果

| 请求速率 | 消息 ACK | 消息 p95 | room-event page p95 | 连接/业务失败 | 结论 |
| --- | ---: | ---: | ---: | ---: | --- |
| 400 msg/s | 24,669 | 286.9 ms | 182.8 ms | 0 / 0 | 稳定 |
| 600 msg/s | 37,506 | 527.4 ms | 490.3 ms | 0 / 0 | 可用但接近延迟预算边缘 |
| 800 msg/s | 40,975 / 49,245 sent | 9,844.1 ms | 9,499.4 ms | 0 / 0 | 不稳定；未完成请求在测试结束时积压 |

400 档数据库计数确认 `messages` 和 `room_events` 各新增约 24.7k 行；`fanout_plans`、
`fanout_deliveries`、`fanout_sync_payloads`、`message_projection_states`、`user_sync_log` 与
`room_outbox` 均为零增量。WAL 为 79,544,261 bytes / 24,692 message inserts，约 **3.22 KiB/
message**。

曾以有积压的历史 room 从 cursor=0 运行 400 msg/s，消息 p95 为 1,197.8 ms。该数值是冷恢复与
写入叠加，不能拿来代表稳定在线客户端；它说明新设备/长离线恢复需单独做分页、限速和 UX 预算。

## 瓶颈证据

800 档 `pg_stat_statements` 的最大消耗已是 room-log 提交 CTE（约 67 s 累计）和消息接收预读
（约 58 s），而不是 fanout 表。原 8-shard admission 更新也有成本，但扩大到 32 个新 direct
shard 后，800 档反而更慢（消息 p95 11.3 s）；该实验还包含 3,000 个新 direct-room 创建，且
PostgreSQL 已接近单机 CPU 上限。因此 32-shard overlay 未采用，不能把 shard 数增加当作通用
吞吐解法。

## 结论与后续门槛

该配置的短时、混合读写稳定工作点应暂定为 **不高于 600 msg/s / 1,000 在线连接**，并以 400–500
msg/s 作为更保守的长时间 soak 起点。提高单机上限的下一优先级是合并/批量化消息接收预读和
admission 更新，降低每消息 CTE 与 shard counter 的写入次数；编辑、撤回、reaction 仍是独立的
fanout 路径，不能用本记录外推其性能。

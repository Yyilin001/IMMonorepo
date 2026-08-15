# ADR-005：命令幂等与 outbox/inbox 至少一次语义

状态：已接受  
日期：2026-07-23  
所有者：V2 后端负责人

## 背景与决定

网络响应可在服务端提交后丢失。`SendMessage` 使用 `(sender_user_id,
client_message_id)`；其它可变命令使用 actor 范围内稳定 operation ID。重放相同
不可变输入返回原结果，重用 key 却改变输入返回 `IDEMPOTENCY_CONFLICT`。

所有实体 ID 与操作 ID 使用 1–128 个 ASCII RFC 3986 unreserved 字符
`ALPHA / DIGIT / "-" / "." / "_" / "~"`。这使 ID 可以作为单一 URL
path component、数据库键和本地缓存键；空白、控制字符、`/`、`%`、查询/片段
分隔符以及 Unicode 都不是合法 V2 ID 编码。同步 token/receipt 是独立的服务端
能力类型，不复用实体 ID 编码。

权威写事务同时写入 source outbox；fan-out 以 receiver inbox/`user_sync_log`
唯一性去重，允许至少一次重试但不允许重复投影。

首方客户端对普通 operation ID 的自动重试寿命固定为 30 天。到期命令必须先在
SQLite 中原子转为 `rejected/IDEMPOTENCY_WINDOW_EXPIRED`，再选择任何网络重试。
服务端普通 operation result 与 `user_projection_effects` 的保留期不得少于 35 天；
部署通过 `IM_V2_IDEMPOTENCY_RETENTION_SECONDS` 显式配置（本地基线 45 天）。超过
服务端窗口后，同一个 ID 不再承诺返回历史结果，应由产品发起一个全新的操作。

保留 worker 只删除非权威的普通命令结果。消息事实、room event、账号禁用记录、
operator route/replay audit 和尚有 moderation/read-receipt outbox 引用的结果不在该
集合中。Projection effect 还必须满足：projector 已越过其 sequence、对应 sync log
已被 compactor 删除且没有有效迁移 fence；当前 `user_projection_versions` 不随 effect
删除。凭证回放密文使用自身更短的 `replay_expires_at` 清理边界。

## 备选方案

- 至多一次：响应丢失会丢业务操作；
- 恰好一次 RPC：无法覆盖跨网络/进程故障；
- 持久 key + outbox/inbox 去重：接受至少一次传输并收敛业务效果。

## 后果、回滚与复审

- 每个命令必须定义 key、唯一约束、冲突输入、重放窗口和结果保留期；普通首方
  operation 使用上述统一窗口，审计/权威例外必须单独登记。
- broker publish、worker crash 或 live hint 丢失不得使 source event 消失。
- 新跨 shard 命令、保留期变化或改动 dedupe key 时复审；不能在客户端仍可重试、
  durable 引用未消失或迁移 fence 有效时删除已接受命令的幂等记录。

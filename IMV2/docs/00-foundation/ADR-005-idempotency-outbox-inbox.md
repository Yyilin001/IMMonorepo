# ADR-005：命令幂等与 outbox/inbox 至少一次语义

状态：已接受  
日期：2026-09-28
所有者：V2 后端负责人

## 背景与决定

网络响应可在服务端提交后丢失。当前 typed HTTP 发送操作使用 `(sender_user_id,
client_message_id)`；其它可变命令使用 actor 范围内稳定 operation ID。重放相同
不可变输入返回原结果，重用 key 却改变输入返回 `IDEMPOTENCY_CONFLICT`。

所有实体 ID 与操作 ID 使用 1–128 个 ASCII RFC 3986 unreserved 字符
`ALPHA / DIGIT / "-" / "." / "_" / "~"`。这使 ID 可以作为单一 URL
path component、数据库键和本地缓存键；空白、控制字符、`/`、`%`、查询/片段
分隔符以及 Unicode 都不是合法 V2 ID 编码。同步 token/receipt 是独立的服务端
能力类型，不复用实体 ID 编码。

权威写事务同时写入 source outbox；fan-out 以 receiver inbox/`user_sync_log`
唯一性去重，允许至少一次重试但不允许重复投影。

客户端按领域声明首次提交期限；尚未提交的意图到期后不能开始发送。已经开始提交的操作保留原身份，通过原回执查询和关闭协议恢复；本地年龄、404、403、超时或重试预算耗尽均不能证明操作未执行。预算耗尽进入等待用户处理的调度状态，不伪造 rejected，也不自动生成替代身份。

成功、关闭及确定拒绝的最小操作证明永久保留，重放先核对原身份和冻结输入。内容正文、临时任务和投影效果各自按领域策略清理，不能将证明与可清理记账混为一类。账号删除必须永久失效原身份命名空间，不能通过清空证明重新开放旧请求。

`IM_V2_IDEMPOTENCY_RETENTION_SECONDS` 及35天下限仅约束现有可清理的非权威记账。Projection effect 还须满足 projector 已越过其 sequence、对应 sync log 已清理且不存在有效迁移 fence；当前 `user_projection_versions` 不随 effect 删除。凭证回放密文使用自身更短的 `replay_expires_at`，不改变原操作最终事实。

## 备选方案

- 至多一次：响应丢失会丢业务操作；
- 恰好一次 RPC：无法覆盖跨网络/进程故障；
- 持久 key + outbox/inbox 去重：接受至少一次传输并收敛业务效果。

## 后果、回滚与复审

- 每个命令定义身份、唯一约束、冻结输入、首次提交期限、原证明查询和关闭语义；当前合同不保留旧30天到期即失败路径。
- broker publish、worker crash 或 live hint 丢失不得使 source event 消失。
- 新跨 shard 命令、保留期变化或改动 dedupe key 时复审；不能在客户端仍可重试、
  durable 引用未消失或迁移 fence 有效时删除已接受命令的幂等记录。

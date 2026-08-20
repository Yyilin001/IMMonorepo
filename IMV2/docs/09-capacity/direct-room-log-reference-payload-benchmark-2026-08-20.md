# Direct room-log 正文引用压测记录（2026-08-20）

这是 `message_reference_v1` 事件正文收缩的实现验证，不是与 2026-08-19 公网直连压测
可直接比较的容量承诺。

## 变更

- plain direct `message.accepted` 事件只保存 `message_id`、revision 和时间；正文仍只写入
  `messages`；
- `message_content_versions` 的数据库 trigger 在正文 revision 变化前保存旧版本，因此历史事件
  不会因编辑而重放出新正文；
- room-event pull 使用一次 SQL 同时完成授权、revision fence、事件分页和正文引用恢复。

## 环境与口径

- 单台 ARM64 8 vCPU / 16 GiB Gateway + PostgreSQL，同一可丢弃数据库；审核关闭；
- 1,000 TLS 连接、600 msg/s、128-byte 正文、三个 direct 目标/连接、60 秒 hold；
- 每个客户端 ACK 后执行 per-room cursor pull；不执行 Sync pull；
- 由于当日压测机至公网 443 的 TLS 中间链路在 ClientHello 阶段断开，负载通过 **4 条 SSH
  隧道**（每条 250 连接 / 150 msg/s）接入。这样验证 Gateway/PostgreSQL 写入与读取路径，但会
  改变网络排队特征，不能把其端到端 p95 与公网直连基线做严格 A/B。

## 结果

| 指标 | 结果 |
| --- | ---: |
| 连接认证 / 连接失败 | 1,000 / 0 |
| 业务失败 | 0 |
| 消息 ACK | 39,685 |
| 各分片消息 ACK p95 | 260.03–271.45 ms |
| 各分片 room-event pull p95 | 229.36–238.50 ms |
| `messages` / `room_events` 写入行数 | 39,739 / 39,739 |
| accepted room event 含 inline `text` 的行数 | 0 |
| accepted room-event payload 总大小 | 8,504,138 bytes |

`pg_stat_statements` 中，room-log 提交 CTE 为 39,739 次、平均 1.451 ms；`locked_room`
发送预读为 36,739 次、平均 1.487 ms；引用式 room-event pull 为 39,634 次、平均 0.493 ms。
因此本改造确认了事件正文没有重复持久化、pull 授权与读取已合并为一次数据库往返；单机下一阶段
热点仍是消息提交 CTE 和发送前 `locked_room` 预读。

## 结论与下一步

1. 该试验通过了连接、发送、room-log pull 与窄事件存储的真实环境验证；历史正文版本由数据库
   trigger 和集成测试覆盖。
2. 公网直连测试恢复后，必须以同一条 load generator、同一 ramp 和同一新房间 corpus 重跑至少
   两次 600 msg/s，比较 ACK/room-event p95、WAL bytes/message、PostgreSQL CPU 和热点 SQL。
3. 不应把本次较低 p95 直接归因于引用改造：四路隧道改变了客户端排队模型。后续优化应优先减少
   `locked_room` 往返与消息提交 CTE 内的同步更新，而不是继续仅压缩 JSON。

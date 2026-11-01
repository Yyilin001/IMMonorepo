# 当前消息发送与结果恢复合同

发送入口核对日期：2026-11-01。范围：普通消息发送、房间执行、成功记录及客户端结果恢复。
协议版本以 [协议版本文件](../../Protocol/im_realtime/v2/protocol_version.txt) 为准，数据库结构以 [canonical schema](../../IMV2/sql/schema.sql) 为准。

## 入口与身份

客户端先持久化发送意图和冻结内容，再经已认证、已协商消息发送能力的 TLS/TCP 连接提交业务操作。
断线重试及结果查询保持房间、发送者、客户端消息 ID、操作指纹和首次提交期限。

| 操作 | 当前通道 |
| --- | --- |
| 普通消息提交 | TCP（TLS） |
| 普通消息结果恢复 | TCP（TLS） |

[App 装配](../../IMApp/IMApp/V2/V2AppRealtimeRuntime.swift)只向
[发送客户端](../../IMV2ClientKit/Sources/IMV2ClientKit/V2RoutedMessageSendOperationClient.swift)注入实时连接。
当前没有普通消息的 HTTPS 提交、恢复路由或 `automatic`／`httpOnly`／`realtimeOnly` 传输配置。
连接不可用、结果未知或能力未协商时不会自动改走 HTTPS；编辑、撤回等独立 HTTP 操作不构成普通发送后备通道。
2026-11-01 产品范围确定为 TCP-only。HTTPS 仅预留后续扩展方向，当前不实现普通消息的 HTTPS 提交、恢复或自动后备；此前双通道方案仅在 Git 历史保留。

`IM_V2_MESSAGE_SEND_OPERATIONS_ENABLED` 默认开启，控制 Gateway 的消息发送能力协商。
关闭该开关不会启用 HTTPS 后备通道；部署前必须与当前客户端合同一并评估。
关键开关的默认值统一登记在[当前实现与发布证据](../../IMV2/docs/implementation-status.md#关键配置默认值)。

服务端以 `(room_id, sender_user_id, client_message_id)` 标识一次发送。
内容指纹由 [SendMessageFingerprint](../../IMV2Core/Sources/IMV2Core/SendMessageFingerprint.swift) 定义；接受成功后的重放使用原成功记录，不从已经编辑或撤回的消息正文重算指纹。

## 房间执行与资源边界

房间 Actor 持有顺序和当前已提交状态。同房间执行轮次串行；不同房间可以并发，事务互相独立。
同房间积压的兼容消息可以合批；批处理不是将多个房间放进一个消息事务。
数据库资源按实际物理池调度，写连接仍是有限的共享资源。

普通 current-state 权限路径使用节点版本化内存事实。冷加载按 scope 合并，首次从控制数据库读取，策略提交后主动更新；不恢复旧 TTL／周期续租缓存设计。
权限事实的具体边界见 [版本化权限快照](policy-versioned-memory-snapshot-implementation.zh-CN.md)。

[发送存储](../../IMV2Server/Sources/IMV2ServerInfrastructure/PostgresV2MessageSendOperationStore.swift) 与
[房间发送内存](../../IMV2Server/Sources/IMV2ServerInfrastructure/V2DirectRoomSendAcceptanceMemory.swift)
共享房间初始化结果。普通简单私聊热路径直接使用已提交内存状态构造写入，不执行独立房间预检查询。
不满足快速路径条件的陌生人限制、特殊内容、审核和其他业务使用对应持久化路径；不能把简单私聊路径推广为所有命令均无数据库预检。

普通内存权限发送依靠唯一房间实例、顺序轮次和真实在途工作的退役等待，不逐条取得旧 Owner／activation SQL 执行围栏。
其他控制、成员变更与复杂业务的围栏仍按各自合同处理。这个边界不证明任意分区、租约过期或旧进程恢复都已验收。
房间生命周期规则见 [Virtual Actor 合同](room-virtual-actor-contract.md)。

## 原子持久化与提交确认

[私聊批量写路径](../../IMV2Server/Sources/IMV2ServerInfrastructure/RoomWrite/V2RoomWriteDirectBatchPath.swift)
将房间游标、消息、成功完成记录及必要事件放在同一原子提交中。
符合条件的发送使用单语句隐式事务，并等待连接确认语句已经结束且处于可归还状态；多语句业务保留显式事务。
不能把收到 SQL 行结果或 CommandComplete 单独当成事务已成功。

确认提交后先归还连接，再更新已提交内存状态并返回 ACK。
同房间在收尾完成前保持执行占用，其他房间可以使用已归还的连接。
发送成功表示持久接受，在线投递与对方已读是分别确认的事实。

房间旧 command-credit 内存池及每条消息更新的房间命令额度设计已经移除。
陌生人消息限制、网络字节预算、数据库连接预算和其他业务配额仍是独立边界，不能一并视为已删除。

## 不可变结果与恢复

`message_send_completions` 是发送成功与永久拒绝的唯一持久结果表，不保存消息正文。同一 `(room_id, sender_user_id, client_message_id)` 只能写入一次结果。
成功记录包含内容指纹、消息／事件身份、房间／时间线序号及操作响应元数据，并与消息同事务写入。
拒绝记录只保存身份、指纹、原因与确认时间，不含成功消息字段；明确业务拒绝及显式关闭均在事务确认提交后才返回回执。两种结果都禁止覆盖或删除，当前没有启用结果 GC。
原 `message_send_operation_receipts` 已从 schema 和发送写入路径移除，不保留第二份发送结果。
2026-11-01 已确定：明确业务拒绝永久关闭该发送身份，权限恢复也不使它重新可提交；用户重发创建新身份。限流、暂时繁忙返回 `deferred`，断线或超时保持结果未知，均不伪造永久拒绝。

结果恢复按房间数据路由读取本人对应的原结果，并核对操作和内容指纹。
`query` 不激活房间、不占房间发送队列、不取得发送操作锁，也不创建新的提交事务；查不到返回 `unresolved`，不等于发送失败。
`closeIfAbsent` 使用写入准入和有界事务：尝试插入 `closedUnsubmitted` 拒绝结果，与迟到成功共用唯一主键。成功先提交则返回原成功；关闭先提交则后续接受事务在结果写入处冲突并回滚，不能保留消息或其他部分变更。查询与关闭错误、超时都不能被客户端当作关闭成功。

数据库已提交而服务端在 ACK 前退出时，客户端用原身份查询成功记录。
未确定结果时保留原持久任务，按原期限与重试规则恢复；不生成新的消息身份，也不刷新首次提交期限。首次提交期限结束后的恢复请求使用显式关闭；客户端取得匹配的持久拒绝回执后，才允许丢弃旧意图或使用新身份重发，并回收其队列配额。

## 验证入口与容量边界

2026-11-01 已把永久发送结果表的行数估算、堆/索引/总字节接入私有指标，并补齐只读统计快照和容量告警。当前隔离样本只证明单表存储与 WAL 量测路径，不构成生产增长或长期容量批准；每日盘点、预算与不可删除边界见[永久发送成功记录的容量与保留](../../IMV2/docs/10-operations/observability.md#永久发送成功记录的容量与保留)。当前仍未启用终态结果归档或 GC。

- [原结果测试](../../IMV2Server/Tests/IMV2ServerTests/PostgresV2SendSuccessRecordTests.swift)：结果元数据、原回执重放与权限变化后的永久拒绝。
- [关闭竞争测试](../../IMV2Server/Tests/IMV2ServerTests/PostgresV2MessageSendTerminalTests.swift)：关闭与实际在途提交竞争、原成功优先及拒绝结果不可变。
- [结果恢复测试](../../IMV2Server/Tests/IMV2ServerTests/PostgresV2MessageSendOperationRecoveryTests.swift)：只读恢复和结果不确定边界。
- [单语句提交测试](../../IMV2Server/Tests/IMV2ServerTests/V2SingleStatementRoomWriteTests.swift)：真实提交确认和失败处理。
- [提交后丢 ACK 测试](../../IMV2Server/Tests/IMV2ServerTests/V2SharedRoomSendCommitAckLossTests.swift)：提交事实与传输确认分离。
- [房间初始化测试](../../IMV2Server/Tests/IMV2ServerTests/V2RoomSendInitializationTests.swift)：初始化数据复用与资源归属。
- [网络入口登记测试](../../IMV2ClientKit/Tests/IMV2ClientKitTests/V2HTTPRouteRegistryTests.swift)：实际 HTTP 路由、发送通道登记及请求适配器边界一致。
- [当前合同检查](../../scripts/check_v2_protocol_documentation.py)：协议、schema、发送通道表和关键配置默认值与对应源码一致；不替代业务和部署验收。

测试源文件存在不是执行通过的证据。最近的性能实测保留在 [当前优化与运行记录](send-throughput-5000-20261008.zh-CN.md)。
其中 R156／R157 为全部发送房间预热后的两次 3,000 msg/s、各 180 秒通过；不能据此宣称稳定 3,500／5,000 msg/s 或生产长期容量。
早期单 Gateway、旧扇出和 command-credit 报告只在 Git 历史保留，不用作当前部署参数或容量依据。

2026-11-01 的 J11/E03 定向验证见[发送终态证据](../verification/send-terminal-20261101.json)：覆盖真实 PostgreSQL 提交/关闭竞争、原回执恢复和客户端满队列后的确认关闭与新编号重发。

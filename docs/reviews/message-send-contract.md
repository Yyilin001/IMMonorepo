# 当前消息发送与结果恢复合同

2026-11-17 核对。本文覆盖普通消息从 Gateway 提交、房间 Actor 执行、PostgreSQL 落库到发送方 ACK，以及 ACK 丢失后的恢复。
协议版本以 [协议版本文件](../../Protocol/im_realtime/v2/protocol_version.txt) 为准，数据库结构以 [canonical schema](../../IMV2/sql/schema.sql) 为准。

## 入口与身份

客户端先持久化发送意图和冻结内容，再经已认证、已协商消息发送能力的 TLS/TCP 连接提交业务操作。
断线重试及结果查询保持房间、发送者、客户端消息 ID、操作指纹和首次提交期限。

| 操作 | 当前通道 |
| --- | --- |
| 普通消息提交 | TCP（TLS） |
| 普通消息结果恢复 | TCP（TLS） |

[App 装配](../../IMApp/IMApp/V2/V2AppRealtimeRuntime.swift)为[发送客户端](../../IMV2ClientKit/Sources/IMV2ClientKit/V2RoutedMessageSendOperationClient.swift)注入实时连接。普通提交与恢复仅支持 TLS/TCP，连接不可用时按原任务恢复。`IM_V2_MESSAGE_SEND_OPERATIONS_ENABLED` 默认开启，控制 Gateway 是否协商该能力。
关键开关的默认值统一登记在[当前实现与发布证据](../../IMV2/docs/implementation-status.md#关键配置默认值)。

服务端以 `(room_id, sender_user_id, client_message_id)` 标识一次发送。
内容指纹由 [SendMessageFingerprint](../../IMV2Core/Sources/IMV2Core/SendMessageFingerprint.swift) 定义；接受成功后的重放使用原成功记录，不从已经编辑或撤回的消息正文重算指纹。

## 房间执行与资源边界

| 组件 | 持有的状态与职责 |
| --- | --- |
| Gateway | 校验连接账户与操作身份，限制在途请求数和字节数。房间目录缓存路由；命中后仍向 Host 发起调用。`cachedResponses` 统计这类调用收到的响应次数。[网关命令](../../IMV2Server/Sources/IMV2ServerGateway/V2GatewayCommandFamilies.swift) · [房间目录](../../IMV2Server/Sources/IMV2ActorRuntime/Client/V2RoomDirectory.swift) |
| 房间 Host | 按激活令牌维护房间发送游标和已提交状态。生产批次通过 `prepareSendOperationBatch` 校验、准备后执行。公开的 `executeSendOperationBatch` 仍有调用方，并复用同一套校验与结果排序。[Host 装配](../../IMV2Server/Sources/IMV2Server/Composition/Room/V2RoomServerActivationFactory.swift) · [消息执行器](../../IMV2Server/Sources/IMV2ServerApplication/Room/V2RoomMessagingExecutor.swift) |
| 房间分片 PostgreSQL | 以完成记录保存发送终态。Host 的重放缓存按操作键保存已提交的接受结果，返回缓存回执时仍核对指纹。缓存未命中时走持久化路径。[发送存储](../../IMV2Server/Sources/IMV2ServerInfrastructure/PostgresV2MessageSendOperationStore.swift) |

房间 Actor 持有顺序和当前已提交状态。同房间执行轮次串行；不同房间可以并发，事务互相独立。
同房间积压的兼容消息可以合批；批处理不是将多个房间放进一个消息事务。
数据库资源按实际物理池调度，写连接仍是有限的共享资源。

普通 current-state 权限路径使用节点版本化内存事实。冷加载按 scope 合并，首次从控制数据库读取，策略提交后主动更新。
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

## 不可变结果与恢复

`message_send_completions` 是发送成功与永久拒绝的唯一持久结果表，不保存消息正文。同一 `(room_id, sender_user_id, client_message_id)` 只能写入一次结果。
成功记录包含内容指纹、消息／事件身份、房间／时间线序号及操作响应元数据，并与消息同事务写入。
拒绝记录只保存身份、指纹、原因与确认时间，不含成功消息字段；明确业务拒绝及显式关闭均在事务确认提交后才返回回执。两种结果都禁止覆盖或删除，当前没有启用结果 GC。
限流、暂时繁忙返回 `deferred`，断线或超时保持结果未知，均不伪造永久拒绝。

**恢复入口由 Gateway 装配决定。** 生产 Gateway 为 `V2RoomRefMessagingClient` 注入分片查询器，`query` 和 `closeIfAbsent` 都按房间路由到 PostgreSQL。直查报错时直接返回错误。未注入查询器的调用方通过房间 Actor 恢复，Host 先校验请求房间与激活令牌一致，再调用同一存储入口。[生产装配](../../IMV2Server/Sources/IMV2ServerApp/GatewayRoomServicesAssembly.swift) · [路径选择](../../IMV2Server/Sources/IMV2ServerInfrastructure/RoomClients/V2RoomRefMessagingClient.swift) · [Actor 适配器](../../IMV2Server/Sources/IMV2ServerInfrastructure/Room/Messaging/PostgresV2RoomMessagingAdapter.swift)

| 客户端遇到的情况 | 下一步与服务端结果 |
| --- | --- |
| 发送结果未知，仍在首次提交期限内 | 用冻结的身份和指纹发起 `query`。生产直查走读取准入，无需激活房间。匹配时返回原回执；查不到返回 `unresolved`，客户端可以退避后用原命令重提。 |
| 原身份已有完成记录，但内容或操作指纹不同 | 返回 `fingerprintConflict`。客户端将任务标记为需要处理。 |
| 首次提交期限已过，结果仍未知 | 发起 `closeIfAbsent`，通过写入准入在有界事务中尝试写入 `closedUnsubmitted`。关闭和迟到的发送竞争同一唯一键。发送先提交则返回原回执；关闭先提交则后续发送重放拒绝回执。超时或错误时保留原任务继续确认。 |
| 获得匹配的永久拒绝回执 | 原身份已终结。即使权限随后恢复，用原身份重试仍返回原拒绝；用户重新发送使用新的客户端消息 ID。 |

单条重提、结果查询和关闭冲突后的回读共用完成记录查询及同一套指纹判定。关闭尝试插入后用一条新的 SQL 语句读取胜出的记录，以便观察刚刚提交的竞争事务。[完成记录读写](../../IMV2Server/Sources/IMV2ServerInfrastructure/PostgresV2MessageSendResults.swift) · [客户端恢复调度](../../IMV2ClientKit/Sources/IMV2ClientKit/V2MessageSendWork.swift)

## 验证入口与容量边界

2026-11-17 的定向验证使用隔离 PostgreSQL 16。代理扣留数据库 COMMIT 的成功响应后，重放取回原消息 ID，消息、事件和完成记录各保留一条。关闭与在途提交竞争、指纹冲突、永久拒绝在解封后继续重放均有定向验证。双房间故障用例在组合运行中出现过一次 `authorityLost`，单独复跑通过，原因待查。此次故障注入位于数据库连接；真实客户端 TLS 连接丢失发送 ACK 的端到端演练仍待验证。[单房间故障注入](../../IMV2Server/Tests/IMV2ServerTests/V2RoomActivationCommitAckLossTests.swift) · [双房间故障注入](../../IMV2Server/Tests/IMV2ServerTests/V2SharedRoomSendCommitAckLossTests.swift) · [策略变化后重放](../../IMV2Server/Tests/IMV2ServerTests/PostgresV2RoomWriteStoreIntegrationTests+PolicyOwners.swift)

结果表的行数估算、存储占用、告警和每日盘点见[容量与保留说明](../../IMV2/docs/10-operations/observability.md#永久发送成功记录的容量与保留)。

- [原结果测试](../../IMV2Server/Tests/IMV2ServerTests/PostgresV2SendSuccessRecordTests.swift)：结果元数据、原回执重放与权限变化后的永久拒绝。
- [关闭竞争测试](../../IMV2Server/Tests/IMV2ServerTests/PostgresV2MessageSendTerminalTests.swift)：关闭与实际在途提交竞争、原成功优先及拒绝结果不可变。
- [结果恢复测试](../../IMV2Server/Tests/IMV2ServerTests/PostgresV2MessageSendOperationRecoveryTests.swift)：只读恢复和结果不确定边界。
- [单语句提交测试](../../IMV2Server/Tests/IMV2ServerTests/V2SingleStatementRoomWriteTests.swift)：真实提交确认和失败处理。
- [提交后丢 ACK 测试](../../IMV2Server/Tests/IMV2ServerTests/V2SharedRoomSendCommitAckLossTests.swift)：提交事实与传输确认分离。
- [房间初始化测试](../../IMV2Server/Tests/IMV2ServerTests/V2RoomSendInitializationTests.swift)：初始化数据复用与资源归属。
- [网络入口登记测试](../../IMV2ClientKit/Tests/IMV2ClientKitTests/V2HTTPRouteRegistryTests.swift)：实际 HTTP 路由、发送通道登记及请求适配器边界一致。
- [当前合同检查](../../scripts/check_v2_protocol_documentation.py)：协议、schema、发送通道表和关键配置默认值与对应源码一致；不替代业务和部署验收。

发送吞吐、预热条件与容量验证范围见[发送压测记录](send-throughput-5000-20261008.zh-CN.md)。

2026-11-01 的 J11/E03 定向验证见[发送终态证据](../verification/send-terminal-20261101.json)：覆盖真实 PostgreSQL 提交/关闭竞争、原回执恢复和客户端满队列后的确认关闭与新编号重发。

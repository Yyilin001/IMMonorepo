# SendMessage 请求指纹实施合同

状态：历史实施记录。下文版本、向量与验证数对应 2026-09-05，不是当前协议合同。
当前保留与清理要求见[现行合同](send-completion-retention.md)。当前实现见 [SendMessageFingerprint.swift](../../IMV2Core/Sources/IMV2Core/SendMessageFingerprint.swift)
和[当前实施记录](room-log-only-implementation.md)。旧升级脚本已移除，新环境只安装规范 schema。

这是 B11/D07 的历史实施记录，配合 [47 项修复进度](archive/2026-09-05-system-remediation-progress.md) 阅读。Core 编码、纯 reducer、9 处消息 INSERT 的原子完成记录、PostgreSQL 重放读取和无正文 ACK 已接入。协议为 22，schema 为 9；GC、owner 迁移与性能证据仍待完成，B11 保持实施中。

## 编码版本与兼容边界

`V2SendMessageCommand` 完成内容验证后计算一次 `V2SendMessageFingerprint`。该字段没有客户端输入参数，也不从客户端提供的 digest 恢复。使用 swift-crypto SHA-256，结果为 32 字节；持久化读取构造器校验版本和长度。

编码按下列顺序流式送入 SHA-256。整数为 8 字节无符号大端；字符串为 UTF-8 字节数再接原始字节；presence/variant tag 为 1 字节；数组先写元素个数。字符串不修剪，不做 Unicode composition 转换；UUID 在已有 Identifier 边界统一字母大小写。当前媒体、mentions、entities 都保留命令顺序，与已有 wire/ordinal 持久合同一致。

| 顺序 | 内容 |
| --- | --- |
| 1 | 字符串 `im.v2.send-message`，整数版本：普通发送 `1`，转发 `2` |
| 2 | roomID、senderUserID、clientMessageID 三个字符串 |
| 3 | 原始 text 字符串 |
| 4 | media 数组，每项 mediaID 字符串 |
| 5 | mentions 数组：user 为 tag `1` + userID，everyone 为 tag `2` |
| 6 | entities 数组：offsetUTF16、lengthUTF16、kind 字符串、可选 linkURL.absoluteString |
| 7 | 可选 replyTo.messageID |
| 8 | targetRule：eligibleMemberCount 为 tag `1`；exactTargetCount 为 tag `2` + 非负整数 |
| 9 | 可选 forward：无为 tag `0`；有为 tag `1` + messageID + senderUserID；v2 另追加 sourceRevision 整数 |

所有可选字符串以 tag `0` 表示 nil，或 tag `1` 后接长度前缀字符串，避免 nil/empty/相邻字段拼接歧义。实体在命令入口重新校验，范围相加使用 checked addition，避免 Codable 绕过构造校验以及整型溢出。

独立 Python `struct.pack('>Q', n)` / `hashlib.sha256` 向量已固定进 Core 测试：

| 测试向量 | 编码字节数 | SHA-256 |
| --- | --- | --- |
| `room-1 / user-1 / client-1 / hello`，其余默认 | 118 | `b9dd74c465574e6befa5331282391eebe346e5ee5990ef4dba904001f1e25016` |
| 测试中的完整 Fixture（媒体、mentions、entities、reply、exactTargetCount、forward），v2 / sourceRevision=1 | 325 | `8572cfa8437d7d1ac1dcfb28ad47cb3d83e77db26b6325bf16ab10db02b59f6d` |

纯 reducer 的完成记录同时持有原指纹和 acceptance draft，Core 操作键为 `(roomID, senderUserID, clientMessageID)`。该 draft 是原有 reducer 结果，不是最终的无正文数据库完成记录。

## 持久化实现与尚待完成的合同

1. 新增 PostgreSQL `message_send_completions`，主键 room/actor/client，保存版本、32 字节 digest、message/event ID、初始 message/timeline sequence、membership revision、delivery authority、group delivery mode、direct recipient 和 createdAt。表内无正文、entities/link 或媒体展示数据，没有 message/room 级联删除，UPDATE trigger 拒绝改变任何已完成字段。当前 schema 合同为 `im-v2-current-9`；Swift 启动 gate 和本地 SQL gate 要求新表，未迁移的旧库不能假装兼容。未自动修改开发者现有数据库。重放读取现只查完成记录并比较原始指纹，不读取可变正文、媒体表或当前投递模式。当前 capacity profile 的一致性检查放在原操作查找之后，已完成重试不依赖新运行参数。
2. `PostgresV2RoomWriteStore.swift` 的 9 处 `INSERT INTO im_v2.messages` 均在原 SQL 内追加 completion CTE，分布在普通 persist、standard fanout、room-log、plain/batch、hybrid 与 typed conditional/CAS SQL。完成记录与消息/事件/额度效果在同一事务提交。批量入口复用已有 columnar 输入，新增 version 和二进制 digest 数组；PostgresNIO 使用 ByteBuffer 的 bytea[] 编码，JSON/SQLKit fallback 使用明确的 Base64 解码。未改成逐条循环写入，也未增添数据库往返；对应 prepared statement 均升级名称以匹配新绑定合同。各路径仍需对应集成证据。
3. SQL unique key、advisory lock、批量重复 operation 检测、prior-operation preflight 和 denial 已统一为 room/actor/client 三元范围。denial 也保存版本和原请求 digest，同操作改参返回冲突。普通与批量 SQL 锁键的 UUID 均使用小写，批量按 PostgreSQL hash 锁键排序。条件批量 SQL 在等待 operation 锁时可能保留旧 MVCC snapshot；仅明确的 completion/messages 操作键唯一冲突在事务回滚后转换为批量 fallback，重新走读取完成记录的路径，其他 SQL 错误照常上报。这一精确竞争调度仍需补充集成证据。
4. 新增 `V2MessageAcceptanceReceipt`，`V2SendMessageOutcome.idempotent` 只带完成元数据；新接受消息仍保留供实时投递使用的完整对象。Gateway、forward、special-account 及 shadow recovery 已使用 receipt；shadow 恢复使用完成记录中的 event ID 与 recipient，不再依赖消息行。协议 22 的 `MessageAccepted` 只保留 message ID、room ID、room sequence、createdAt；旧内容字段的编号和名称全部 reserved。客户端校验房间一致、正序号且不超过 Int64、非负时间，不从 ACK 重建内容。旧协议 21 的客户端/服务端必须匹配升级，不能混用。
5. 接受命令的 `V2ForwardMessageSource` 必须携带有界 `V2MessageRevision`；历史展示继续使用不带版本的 `V2ForwardedMessageAttribution`，两者不能互换。初始 SQL 读取 content revision，最终在源房间/消息锁下严格比较；新转发采用 v2 编码，普通发送仍生成原 v1 字节。持久化解码接受 v1/v2，不能把旧完成 digest 重新计算成当前内容。转发操作首次分配 client ID 时持久绑定 source revision，后续不同版本（即使正文相同）返回 IDEMPOTENCY_CONFLICT；数据库 trigger 阻止改绑身份或覆盖已完成结果。
6. 内容删除后保留完成记录或明确拒绝过期 operation 的 epoch fence；记录随 room owner 迁移，GC 覆盖重试和备份恢复窗口。不得用 message 级联删除悄悄移除重放防护。
7. 验收必须运行真实 PostgreSQL 的 ACK 丢失→编辑/撤回/清除→重试，同 ID 逐字段冲突，跨 room 同 client ID，模式切换与所有批量路径；记录新增 WAL/CPU。Core 向量和服务测试不能替代这些验收。

批量 completion 的 membership revision 取自该次 `message_insert RETURNING`，group delivery mode 取自已经通过授权和模式 gate 的具体写入路径；不能在条件 SQL 等待锁后，再通过普通 `rooms` SELECT 的旧 MVCC snapshot 重建该 revision。普通路径则直接绑定先前锁定的 room snapshot。Direct recipient 来自不可变的参与者 pair，未重新推导成员受众。

目前没有启用完成记录 GC。集成测试在 standard、hybrid、hybrid-mention 三种路径逐步修改、撤回、删除主消息及版本/mentions 依赖，每一步实际重发原命令并验证得到原 receipt；删除后七类业务字段变更均冲突。这不代表所有事件正文、媒体、备份已清除，也不替代 B03/B04 的内容和权限生命周期合同。

## Schema 7→8 迁移

旧 source revision 升级脚本已移除；本段仅记录当时的历史工作，不再提供升级执行步骤。

部署该迁移需要先停止旧版本写入，再依次完成 7→8 与 8→9 迁移并启用要求 schema 9 的服务；启动 gate 不能撤销已经启动的旧进程。普通发送的 v1 仍保持固定向量，已有 v1 receipt/denial 无需重写。迁移拒绝非 schema 7 的输入，重复执行失败后必须保持现有 schema 和记录。

最新源版本与迁移测试结果以修复进度表为准。精确版本绑定不等于当前版本受众已实现；转发路径已补当前编辑版本受众；B03/B04 的其他读取与恢复入口仍需后续闭环，见转发源授权合同。

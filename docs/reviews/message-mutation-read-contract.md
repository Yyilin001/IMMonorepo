# 普通消息变更的历史读取与扫描游标

对应 B03/D07。承接[接受事实与房间日志合同](message-mutation-delivery-authority-contract.md)。reaction 操作者原消息授权、普通编辑/作者撤回/reaction 的房间日志读取过滤，以及 ClientKit 对已扫描空洞的消费均属于当前行为；完整组合验收仍见[问题状态表](status.md)。

## 授权与读取

reaction 新操作必须同时满足当前成员身份与 accepted 时刻的成员身份；两个判断可由不同入群区间满足。检查发生在 reaction 存在性、remove no-op 和限额判断之前，纯新成员无法借无变化操作探测旧消息 reaction。已经完成的同一 operation 重放保持原幂等合同，离群后的重放不创建新变更。

writer 与 room pull 共享从 message 唯一索引及 completion 主键读取接受事实的查询；completion 的 accepted membership revision 是依据，不能使用缺失的 message-row 副本作替代。房间 pull 在一个 PostgreSQL 查询快照内检查当前成员、事件发生时成员和原 accepted 成员，先按索引截取有界候选窗口，再在窗口内过滤；离群期间的变更不会在重入后补发。

缺少接受记录的普通变更保留为不完整候选，读取该页失败；它不能被当作无权事件过滤后推进游标。不可见于事件发生时的内容仍按历史区间过滤。已有 accepted 读取继续使用原版本内容，不能回退为当前编辑文本。缓存只保存符合已有准入条件的 accepted；遇到 mutation 空洞或旧成员区间不能覆盖的范围回到持久查询。全群共享缓存页仍须在读取时鉴权。

## 当前 continuation

`GroupEventPage.next_room_sequence` 明确表示本次认证查询已检查到的房间序号，至少覆盖最后一条返回事件。尚有未检查候选时，只推进至本次候选窗口的最后序号；两个候选来源都已耗尽时可推进至同一快照的房间 head。空可见页也可前进。`has_more=true` 必须严格前进，避免忙循环。

ClientKit 传输、持久存储、前台预览存储及预览 engine 均接受最后事件序号小于 continuation。仍拒绝乱序、越界、倒退及无进展的后续页。持久流在同一 SQLite 事务中写可见事件、物化投影和扫描游标；无权空洞不制造事件或消息，坏 payload 回滚整个事务。重开数据库保留游标，精确重复页保持幂等。前台预览只更新内存 continuation，不写 durable room cursor 或 personal ACK。

这一 continuation 语义始于历史 protocol 26；当前 wire contract 为 protocol 32，
服务端 PostgreSQL schema 为 `im-v2-current-55`。客户端与服务端必须使用同一当前协议。

## 有界候选窗口

持久房间 pull 的 `pageSize=P` 同时限制候选检查数量和返回事件数量：

1. `room_events` 按 `(room_id, room_sequence)`，`messages` 按 `(room_id, timeline_sequence)` 各取游标后的前 `P+1` 条。
2. 消息来源使用 `messages_room_log_candidates_idx` 部分索引，只包含 `accepted_event_storage='message_row'`；撤回记录仍包含在内。
3. 合并后取全局前 `P+1` 条；前 `P` 条构成检查窗口，多出的一条只证明还有候选，不执行授权与正文还原，也不消费其游标。
4. 窗口内沿用当前成员、事件成员、原接受成员和正文完整性检查。不可见记录消费扫描预算；因此允许不足一页甚至空页且 `has_more=true`。
5. 有后续候选时，continuation 是窗口末尾序号；耗尽时才推进到同一查询快照的 head。授权事实或必需正文缺失仍使当前页失败，不能作为不可见内容跳过。

候选窗口和授权处于同一查询快照，房间 Actor 的 FIFO、激活围栏和事务锁保持原合同。
当前 canonical schema 与 readiness 同时要求上述部分索引；按未发布项目政策从空库建库，不增加历史升级路径。

## 未完成边界

- 此游标沿用已认证请求的 room 与连接代次校验，不代表完整的 account/installation/access epoch 恢复协议已经完成。
- 新编辑已接通 [typed full replacement](message-edit-replacement-contract.md)，可合法跨 rev1→rev3；不会补发无权期间 rev2。其他缺依赖恢复仍按[问题状态表](status.md)验收。
- 按 ID/引用/pin、媒体、snapshot、其他前台内容入口需继续验证原始和具体内容版本受众。
- 独立无正文 content revocation 与完整房间恢复目录/基线按各自当前合同验收；普通撤回不扩大为追溯擦除。当前版本只以全新数据库和新版客户端为基线。

## 验证

验证必须覆盖新成员读取旧消息变更、无权窗口及尾部 continuation、缺少接受记录时拒绝该页、
reaction add/remove 的当前与历史资格、坏 payload 回滚和重启后的游标保持。

历史分层回归的版本、日志和失败记录见[运行证据](verification-records.md#20260906-message-read-authority)。
该证据只覆盖当时的源码，当前同版全链路与生产负载验收独立判断。

后续批次已补齐回复/置顶写入授权，并让转发与按消息定位的媒体读取统一使用不可变接受记录，见[历史引用授权](message-reference-visibility-contract.md)。其他内容读取与完整恢复仍按上列范围继续验收。

有界分页回归位于 `PostgresV2RoomWriteStoreIntegrationTests+BoundedLogReads.swift`：
混合来源、连续不可见窗口、重入成员、尾部空洞、缺失接受事实，以及 1,000/50,000 条历史的首页和中间页。
扫描验证重放实际生产 SQL 与绑定参数的 `EXPLAIN (ANALYZE, BUFFERS)`，检查候选部分索引和实际扫描行数；
这是本机查询计划证据，不替代线上并发和冷磁盘延迟验收。

本次定向查询计划、同房间发送等待与运行命令见[有界分页验证记录](verification-records.md#20260927-bounded-room-log-pagination)。

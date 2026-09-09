# 普通消息变更沿用原接受记录的分发归属

对应 B03，当前只完成普通编辑、作者撤回、reaction 的分发选择。B03 的历史受众交集、缺基线恢复、typed replacement、内容撤销和快照合同仍开放。

## 权威来源

`message_send_completions` 在消息接受事务中保存不可变的 message ID、accepted event ID、room sequence、accepted membership revision 和 `delivery_authority`。普通变更通过已锁定的 message 行取得 `(room_id, sender_user_id, client_message_id)`，按现有 completion 主键查询并检查消息身份及原始 room sequence。不增加发送热路径索引，也不扫描全部接受记录。

读取发生在原有 owner/room/message 锁和授权、版本检查之后、额度预留及状态修改之前。缺失或不匹配的接受记录使新变更失败并回滚，不能从当前部署配置、房间默认值或正文存储位置推测。已完成操作仍先读取自己的幂等记录，保留既有重放合同；本批没有删除接受记录的生产清理任务。

完成记录中的 accepted membership revision 是权威事实。历史 room-event 物理存储路径不填充 messages 上的同名优化列，不能把该列的默认值当作原始成员版本。

## 分发和额度

| 消息的接受方式 | 普通变更的处理 |
| --- | --- |
| direct planner / preplanned、standard group | 原逐用户额度预留、planning plan、room outbox |
| direct room-log、hybrid group | 只预留命令额度，零 target/零 fanout cost 的 terminal 审计 plan，无新增 room outbox；从有序房间日志恢复 |

实现复用 `V2RoomEventDeliveryMode` 的两种执行分支，内部枚举转换不是房间策略变更。terminal plan 暂沿用已有 `hybrid_room_log` 审计标签；该标签不能用来判断房间类型。群 delivery mode 已被数据库约束为不可变。私聊中不同消息仍可能由不同发送策略接受，必须逐消息查询。

正文位于 `messages` 或 `room_events` 是物理布局，与上述分发归属独立。编辑后的原 accepted 事件仍使用不可变投影状态恢复原内容，变更事件保持自己的房间序号。幂等请求不追加事件或分发计划。

## 未关闭的边界

后续批已为新 personal 变更的 fanout 实现 `VisibleAtAccepted ∩ MemberAtMutation` 受众过滤及精确额度结算，见[受众结算合同](message-mutation-audience-contract.md)。其他读取入口与旧积压还未完成同等过滤。当前投影消费者仍不能恢复所有合法缺基线/版本缺口场景；不能靠跳过个人 checkpoint 或扩大旧全文受众解决。客户端持久缺失依赖、账号/安装/成员代次栅栏和完整快照恢复继续待实现。

审核删文属于回溯性的 content revocation，可能需要通知已离群的原受众并清理本地全文、搜索和缓存。因此本批未将 moderation redaction 简单改成 room-log 分支；其独立无正文撤销合同与持久 tombstone 仍需实现。原 owner 栅栏与迁移限制保持适用，本批不关闭 B27 或完整迁移。

## 验证

旧生产实现的隔离 PostgreSQL 反例：12 个参数场景中，direct room-log 的三种变更各错误新增 room outbox、planning plan 和非零 target，共 9 个失败断言。最初测试尝试修改群 delivery mode，被现有不可变触发器拒绝；修正为合法的群模式对照后重新取得上述反例，未绕过触发器。

修复验证覆盖七种发送/物理存储路径乘三种变更、同一私聊先接受相反归属的消息、房间日志原内容与完整有序变更、删除接受记录后的完成操作重放，以及两种群模式下缺少记录时所有相关业务表保持原样。首次修复构建因嵌套 `#require` 宏失败，拆开后重新构建。扩展运行执行 186 项测试，只有三条测试断言失败：富文本私聊实际仍采用 `message_row`，而非测试原先假设的 `room_event`。按真实路径修正，并补充开启审核的 `room_event` 私聊对照。最终 **186 项测试 / 14 套件**通过，退出 0，耗时 168.977 秒；其中新增 21 个分发归属场景和 6 个缺失记录回滚场景全部通过。日志、执行脚本及源码哈希见[验证证据](evidence/20260906-message-delivery-authority/manifest.json)。PostgreSQL 25、protocol 25、SQLite 173+5 未改；真实 TLS/App、Linux、容量和完整迁移仍待验证。

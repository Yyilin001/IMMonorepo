# 会话偏好与收藏的弱网合同

本合同对应应用级弱网 W3 的两个领域：会话置顶/归档/静音、消息收藏。当前 wire 为 protocol 33，PostgreSQL 新建库合同为 `im-v2-current-55`；不提供旧协议、旧本地 lane 或历史 schema 的兼容路径。

## 意图与提交

客户端先在账户 SQLite 写入 `v2_personal_preference_intents`。意图与已冻结 work 共用 2,000 条、32 MiB 活跃容量限制。会话偏好按 room 排序，收藏按 room/message 排序；不同 key 独立推进。只有同 key 队首才能冻结操作 ID、目标值、expected revision、首次提交截止和指纹。冻结、领域 command 和公共 work 在同一事务提交。

版本取已确认原回执与同步投影中的较大值。前项尚未确定时不冻结后项，因此连续离线修改不会全部使用初始版本。远端并发修改仍会产生明确版本冲突，不自动改写已经冻结的命令。首次提交窗口读取 Core 注册策略，目前为意图入队后 7 天；未经发送的过期意图可本地结束，已经可能发送的操作必须核对或取得关闭证明。

`v2_operation_work` 是执行状态、轮次预算、下一步时间及 claim 的唯一来源。旧 `v2_pending_conversation_states`、`v2_pending_message_favorites`、其清理索引/触发器、独立 outbox 与运行循环已删除。App 的公共 dispatcher 注册这两个适配器，前台页面只入队。

## 权威结果

TLS 两类提交请求必须携带 expected revision 和首次提交截止，返回独立的 `PersonalPreferenceReceipt`。投影消息不能作为命令回执。回执绑定账户、领域、room/message、operation ID、指纹版本和摘要；结果为 committed、rejected 或 closed。成功结果必须包含原始目标值及恰好递增一次的 revision。

恢复入口为 `POST /v2/rooms/{roomID}/personal-preferences/operations/recover`，请求/响应使用 Core Codable 合同。query 返回原回执、unresolved 或 fingerprintConflict；closeIfAbsent 只能在同一权威锁下证明原操作未提交并写入永久关闭记录。超时、取消、403 或普通传输错误本身不能生成拒绝/关闭证明。

服务端通过 RoomRef administration 在房间 owner 的 activation fence 和事务内处理提交与恢复。原回执留在 room owner；用户投影通过该 owner 的持久 user-state outbox 投递至 user shard。Gateway 不直接写控制库中的房间事实。

## 投影与生命周期

同步投影的 revision 必填且为正。旧 revision 被忽略；同 revision 内容不同视为协议错误并回滚应用事务。false 收藏、全部关闭的会话设置仍保留版本，不能通过删除行丢失修订栅栏。

本地原回执与同步投影分别保存：前者推进命令顺序并提供冻结基线，后者负责现有页面展示。收到有效原回执后，即使调用方取消也可完成原操作；旧失败不能覆盖完成结果。HTTP 恢复走账户统一调度，TLS 发送也在实际传输层获取许可。

## 验收边界

SQLite 专项覆盖队首冻结、跨 key 推进、统一容量、首次窗口过期、丢 ACK 后同身份查询、伪回执拒绝和投影单调性；协议专项覆盖错 scope、缺失冲突版本及无效关闭证明。服务端 PostgreSQL 验证和 App 回归结果记录在[实施状态](application-weak-network-progress.md)。

本批不代表 W3 全部命令完成。其他领域仍须迁入公共 work；个人操作需要补齐统一的用户可见失败/继续确认入口。完整离线启动、multipart 上传、后台传输及端到端容量验收仍属于后续阶段。

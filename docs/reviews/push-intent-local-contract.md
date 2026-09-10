# B16 客户端持久 Push 意图

此批在 [版本化 HTTP](push-intent-http-contract.md) 之后增加本地事务状态；尚未实现自动 reconciler，也未将 App 开关从旧接口切换过来。B16 继续实施中。

## 状态与账号边界

新增 `v2_push_intent` 单行表，主 SQLite 从 172 增至 **173** 个对象，搜索库保持 5。schema 指纹为 `0xd39d3ac5c9ce1b60`；协议 25、PostgreSQL 19 未变。

每次读写验证当前 SQLite 的 user_id 和安装绑定。行内保存设备、执行器 owner UUID、用户偏好、待提交开关、单调 revision、已确认 revision、会话 claim/expectedEpoch/epoch、尝试数、下次尝试时间和暂停原因。APNs token 不保存；tokenReference 只是随机 UUID，用于匹配执行器内存中的一次系统 token 获取结果。

执行器先 inspect 当前记录，再在确认当前 App 身份和生命周期仍有效后，以完整旧记录进行比较并接管。旧记录有变化则接管失败，不能不加判断地重读并抢占。相同 owner 重试接管幂等。新 owner 保留不确定的 claim，但清空 tokenReference 并预留更高 revision；新设备不沿用前一设备的 epoch。旧 owner 修改抛 staleOwner，迟到的 ACK/claim/failure 因完整状态不匹配而不落盘。

本地比较不能代替 App 的认证生命周期验证；未来调用方仍须在异步操作前后判断自己是否拥有当前账号/安装会话。

## 本地事务

- 修改用户开关同时保存 preference、desired 和新 revision；关闭清除 tokenReference。
- 新 token 先保存新的随机引用并递增 revision，实际 token 留在执行器内存中。尚未拿到 token 的 enabled 状态不能确认完成。
- claim 请求在 HTTP 前持久保存准确 requestID/expectedEpoch；响应只可将完全匹配的记录改为 expectedEpoch+1，响应丢失或重启继续使用原 claim。
- 只有相同 owner、设备、意图、claim、重试状态的确认才更新 acknowledgedRevision。确认不删除 disabled 行。
- 退出先保存 desired=false 和新 revision，保留用户 preference。再次激活可恢复 preference，但调用方必须先处理既有退出/撤销状态，不能用重新激活跳过未完成退出。
- 网络失败可按完整状态保存 nextAttemptAt；stale/conflict/auth 分类可持久暂停。普通开关、token 到达和激活不会自动清掉暂停。显式、重新验证身份后的会话重启才清空 claim/epoch，并递增 revision。
- revision 达 Int64 上限拒绝继续写入；没有环绕。SQLite 同时约束整数类型、ACK 范围、claim/epoch 配对、tokenReference 与 enabled 配对及重试字段。

任何 SQLite 事务失败均保留旧状态。本表不属于个人/群投影 shadow bank，不触发消息列表刷新；实际自动发现/调度观察器留待 reconciler 阶段完成。

## 迁移和验证

`recordPushIntent` 仅增加空表，不推断历史远端端点和用户意图；App 后续应在首次激活时明确导入该用户的原偏好。迁移保留账号绑定、真实 pending reset 和待发送消息。测试覆盖数据库重开后继续原 claim、token 更新前后旧 ACK、先关闭后 claim 回包、偏好与退出分离、退避/暂停/显式重启、跨账号/安装/设备/owner 拒绝、迟到接管、事务回滚、版本溢出、SQL 非法状态，以及快照重建期间保留 Push 元数据。

结果见[本地存储证据](../../docs/reviews/verification-records.md#20260906-push-intent-local)。本批没有执行远端 HTTP；没有证明自动重试、定时器、真实杀进程、App 点击或 A→B→A 的组合行为。后续继续实现一个有界单飞 reconciler、token 内存所有权及账号/安装/退出生命周期接线，再做远端最终状态验收。

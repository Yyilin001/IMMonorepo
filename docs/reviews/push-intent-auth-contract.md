# B16 Push 认证代次与退出清理

App 的普通设置和退出清理均使用 V2HTTPPushEndpointClient 的 session/epoch 初始化入口。认证代次与服务器 Push session epoch 是两个不同边界：前者防旧本地 owner 借用新登录凭据，后者拒绝远端迟到低版本写入。

私有 credential adapter 在获取/刷新凭据前后检查认证代次，并核对返回凭据属于同一代次；HTTP adapter 在发送前和响应/错误返回后复核。替换会话或任务取消返回 CancellationError，因此执行器不确认旧意图，也不把旧请求安排到新会话。相同认证代次内的正常刷新仍可使用。无法撤销已经到达服务器的写入，最终状态继续依赖服务端版本条件写。

退出先保存既有 pending marker 并使交互认证代次失效。端点清理停止、排空旧设置，再创建绑定清理代次的执行器。它接管相同 SQLite 记录、保留原服务器 claim/epoch，并保存更高版本禁用意图。进程恢复的 pending logout 使用同一路径。认证凭据直到禁用确认后才交给后续本地退出步骤。

[证据](../../docs/reviews/verification-records.md#20260906-push-intent-auth)包含六项新测试（迟到响应参数为 204/401/503/网络错误）：同设备重新登录、获取凭据时刷新被新登录替代、同代次正常刷新、非配合传输取消，以及真实 SQLite/认证 actor/执行器的退出组合。退出测试控制旧 PUT 在失效后远端完成，验证旧 ACK 未写本地、清理更高版本最终禁用、原偏好和凭据保留。HTTP 为受控替身，条件数据库写的真实证据仍见前批。

最终 ClientKit **361 项 / 57 套件**、App **176 项 / 17 套件**通过。首次新测试编译因嵌套 #require 宏失败，拆开宏后定向和全量均通过；失败日志保留。

本批不把 401/403 自动解释为可删除当前凭据的终态，不改变 B09 其他 HTTP 入口；旧响应被取消并不能证明当前 HTTP 终止流程已闭环。B08 的持久分步退出、离线撤销补偿、锁屏/杀进程和 V2AppStore 完整 A→B→A 仍开放；B16 真实 HTTPS→Account→PostgreSQL/App 与 APNs 验收仍开放。protocol 25、PostgreSQL 19、SQLite 173/5 不变。

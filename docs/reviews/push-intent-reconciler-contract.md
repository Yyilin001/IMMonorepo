# B16 Push 自动执行器

本批承接 [本地持久状态](push-intent-local-contract.md)，实现自动发现、单飞传输、输入合并和持久退避。App 仍使用旧 Push 设置链路；状态观察、App 开关、退出及账号生命周期尚未接入，B16 保持实施中。

## 执行与输入

`V2PushIntentReconciler` 为一个账号/安装/设备 owner 服务。activate 读取旧记录并比较接管，不自动重试过期接管；调用方仍须在此前后确认当前认证生命周期。

本地输入由独立任务合并：保存完整 preference/desired/tokenReference 并比较旧状态，成功后递增 revision；若其间有新输入则继续保存最新输入。它不等待 HTTP 完成，因此旧注册悬挂时仍可先持久保存关闭意图。HTTP 每次 flush 最多发送一个请求，所有并发 flush 调用共享一个任务；单个 UI 等待者取消不取消这项共享操作。

APNs token 只存在执行器内存和正在发送的请求中。新 token 对应新随机引用；重复 token 不额外递增版本，并可重试之前未能保存的本地输入。关闭或退出清除当前 token；sign-out 阻止该 owner 的后续开启与 token 回调。真实 token 不写 SQLite、日志或 UI 状态。

## 自动调度

GRDB ValueObservation 观察当前账号/安装/device/owner 的待办时间，缓冲一项更新。查询仅选取未确认、未暂停且能够构造请求的记录；启用但未取得 token 的状态等待系统回调。任务先订阅后读取，沿用 V2CommandRetryScheduler 的单调睡眠与壁钟重查，每次请求完成后重新读持久状态。

步骤为读取当前服务器 epoch、持久保存 claim、发送原 claim、保存授予的 epoch、发布当前版本并确认。丢失 claim ACK 后重试相同 ID/expectedEpoch，不重新申请。每轮只发送一个请求，失败先保存下次尝试时间。

网络错误按 1、2、4…60 秒退避。HTTP 429 读取 Retry-After 整数秒，至少 1 秒，缺失/无法解析时使用 60 秒，并保留高于本地上限的服务器等待要求。stale/version-required 持久暂停；内容/协议冲突不自动重试；认证拒绝暂停并向运行调用方抛出。显式验证身份后的 restartSession 才重新申请 epoch，保持最终 desired。

停止执行器取消并排空运行、HTTP 和本地保存任务。请求返回后再次检查取消；即使远端已经提交，迟到结果也不会清除本地待办。随后由当前 owner 按原版本或更高版本收敛。owner 已变化时旧结果不提交，旧执行器也不能继续选取新 owner 的工作。

## 验证边界

[证据](../../docs/reviews/verification-records.md#20260906-push-intent-reconciler)覆盖真实 SQLite、实际自动观察及一秒退避定时器、长 Retry-After、token 更新、旧注册等待期间关闭、共享 flush 与单个等待者取消、claim 提交后丢响应及重开数据库、stale 暂停/显式重启、退出后旧 token、非配合 HTTP 取消后的迟到成功和 owner 替换。

测试远端是受控传输替身；它用于记录调用、控制 ACK 丢失和等待顺序。服务端条件写的真实 PostgreSQL/HTTP 验证见此前证据，本批未重新运行服务器或将执行器直接连接到真实 Account 进程。App 单元测试只验证兼容，不能证明开关已经采用执行器。

协议 25、PostgreSQL 19、SQLite 173/5 不变。后续仍须接入 App 状态观察、用户偏好迁移、OS 回调、连接/账号/安装生命周期与退出错误处理，并执行真实 HTTPS、杀进程、A→B→A 及服务端最终状态组合验收。

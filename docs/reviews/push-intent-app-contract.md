# B16 App Push 意图接线

App 设置、APNs 回调与退出清理已接入版本化执行器。SQLite 是意图、版本、确认和重试状态的权威来源；UI 通过有界 GRDB 观察自动更新，不再分别发送无版本 register/remove。B16 保持实施中，真实网络和账号生命周期组合验收仍开放。

## 所有权与偏好

V2AppStore 在认证 attempt/session epoch 检查之间获取账号、安装、设备 scope 并激活执行器；旧设置停止后才能接管。丢弃认证页面时先停止并排空设置、观察和传输任务，再关闭数据库。并发 stop 调用共享同一清理任务，任何调用方都不能提前越过排空边界。

每个用户原有的 UserDefaults 偏好键只备份当前 owner 接受的 SQLite preference。新记录才以该键初始化，持久记录存在时以 SQLite 为准。备份在 MainActor 同步写入，避免旧异步写晚于新账号对象；退出保存 preference、将 desired 设为 false。真实 token 仅交给执行器内存，不进入备份或 UI。

## 设置和退出

开启等待系统 token，收到 token 后由执行器自动注册。关闭可以在旧 HTTP 请求等待期间持久保存；开关在注册期间仍可操作。网络失败显示自动重试状态，手动重试按钮可重新请求系统 token 或显式恢复暂停会话。UI 拒绝较旧 revision、epoch、ACK、重试次数和暂停状态回退；已成功注册后的迟到系统失败不会覆盖成功状态。

退出先持久保存禁用意图，再推进读取 epoch、原 claim 和版本发布，只有禁用确认后才继续删除凭据。失败抛出并保留待办。恢复 pending logout 时即使没有设置对象，也会打开原账号存储并使用相同版本链路。单次推进次数有界，退避中的意图继续保持 pending，不伪装远端已移除。

## 验证

本批 [证据清单](../../docs/reviews/verification-records.md#20260906-push-intent-app)保存 ClientKit **355 项 / 56 套件**、App 最终 **176 项 / 17 套件**通过的日志，也保留 isolated deinit 和测试 fixture actor 隔离的两次编译失败及修正后日志。最后一次测试的会话句柄在上下文恢复时不可用，以 xcodebuild 的 TEST SUCCEEDED 和进程已结束作为终态证据，不推断未观察到的退出码。

9 项 App 设置测试使用真实 SQLite 和真实执行器，覆盖注册期间关闭、自动退避、重建 owner 保留关闭、系统失败/重试、退出 ACK 和失败、迟到 token、非配合取消请求及两个 stop 等待者。远端为可控制传输替身。这些测试不等于真实 App→HTTPS→Account→PostgreSQL 组合验证，也不证明 V2AppStore 的 A→B→A、进程被杀、终态 HTTP 和退出重入全部正确。

未运行真实 APNs、签名设备、后台预算及手工 VoiceOver/Dynamic Type/RTL 验收。本批不改变 protocol 25、PostgreSQL 19、SQLite 173/5。

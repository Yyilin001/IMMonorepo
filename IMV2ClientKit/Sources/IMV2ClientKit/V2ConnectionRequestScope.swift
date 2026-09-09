import Foundation

/// 通过任务局部值把订阅操作绑定到特定连接代际。
///
/// 领域传输 actor 调用保留此任务上下文，底层注册请求或等待提示时检查代际，
/// 防止旧会话的清理把取消订阅发送到替换连接。此范围不提供用户认证，也不替代持久化操作身份。
enum V2ConnectionRequestScope {
    /// 可选的预期连接代际；nil 表示调用方未施加此额外约束。使用方应在受控作用域内设置，让异步调用继承。
    @TaskLocal static var connectionID: UUID?
}

/// 下载会话存储错误。
public enum V2MediaDownloadSessionStoreError: Error, Equatable, Sendable {
    /// 请求参数不满足约束。
    case invalidRequest
    /// 下载会话当前不可认领、消费或释放。
    case sessionUnavailable
}

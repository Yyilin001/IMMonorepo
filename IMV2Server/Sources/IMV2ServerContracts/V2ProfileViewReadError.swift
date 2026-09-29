/// 资料视图读取错误。
public enum V2ProfileViewReadError: Error, Equatable, Sendable {
    /// 请求键为空、超限或存在重复。
    case invalidRequest
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}

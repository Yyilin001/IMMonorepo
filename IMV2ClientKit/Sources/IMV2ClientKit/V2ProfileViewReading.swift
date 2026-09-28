import IMV2Core

/// 资料视图读取能力。
public protocol V2ProfileViewReading: Sendable {
    /// 按查询键批量读取资料视图。
    ///
    /// - Parameter keys: 查询键列表。
    /// - Returns: 与查询键一一对应的结果。
    /// - Throws: 请求非法、认证失败或网络失败时抛出。
    func readProfileViews(_ keys: [V2ProfileViewLookupKey]) async throws -> [V2ProfileViewLookupResult]
}

/// Invalid input to the local authorized projection reader.
public enum V2ProfileViewClientError: Error, Equatable, Sendable { case invalidRequest }

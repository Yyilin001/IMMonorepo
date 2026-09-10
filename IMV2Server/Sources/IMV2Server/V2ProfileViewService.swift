import Foundation
import IMV2Core

/// 由已认证 HTTP 边缘传入资料存储的有界请求。
///
/// 请求只携带来自私聊房间或已授权房间上下文的稳定标识，
/// 它不是通用的身份目录查询接口。
public struct V2ProfileViewReadRequest: Equatable, Sendable {
    /// 单次请求允许的最大查询键数量。
    public static let maximumKeys = V2ProfileViewLookupLimits.maximumKeys

    /// 发起查询的用户。
    public let actorUserID: UserID
    /// 本次查询的键列表，保持调用方给出的顺序。
    public let keys: [V2ProfileViewLookupKey]

    /// 校验并保存查询请求。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起查询的用户。
    ///   - keys: 非空且不超过 ``maximumKeys`` 的键列表，键之间不允许重复。
    /// - Throws: 键为空、超出上限或存在重复时抛出
    ///   ``V2ProfileViewReadError/invalidRequest``。
    public init(actorUserID: UserID, keys: [V2ProfileViewLookupKey]) throws {
        guard !keys.isEmpty, keys.count <= Self.maximumKeys, Set(keys).count == keys.count else {
            throw V2ProfileViewReadError.invalidRequest
        }
        self.actorUserID = actorUserID
        self.keys = keys
    }
}

/// 资料视图查询的持久化能力。
public protocol V2ProfileViewStore: Sendable {
    /// 按请求键读取资料视图。
    ///
    /// 每个请求键都会返回一项结果；无权限、被拉黑、已删除与不存在的对象由存储层
    /// 刻意收敛为同一类结果，避免调用方据此推断目标对象是否存在。
    ///
    /// - Parameter request: 已校验的查询请求。
    /// - Returns: 与请求键一一对应的结果列表。
    /// - Throws: 持久化状态损坏或存储不可用时抛出。
    func read(_ request: V2ProfileViewReadRequest) async throws -> [V2ProfileViewLookupResult]
}

/// 资料视图查询服务，把边缘请求原样转交存储。
public struct V2ProfileViewService: Sendable {
    private let store: any V2ProfileViewStore

    /// 组合资料视图存储。
    ///
    /// - Parameter store: 实际执行查询的存储实现。
    public init(store: any V2ProfileViewStore) {
        self.store = store
    }

    /// 读取资料视图。
    ///
    /// - Parameter request: 已校验的查询请求。
    /// - Returns: 与请求键一一对应的结果列表。
    /// - Throws: 存储实现抛出的错误。
    public func read(_ request: V2ProfileViewReadRequest) async throws -> [V2ProfileViewLookupResult] {
        try await store.read(request)
    }
}

/// 资料视图读取错误。
public enum V2ProfileViewReadError: Error, Equatable, Sendable {
    /// 请求键为空、超限或存在重复。
    case invalidRequest
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}

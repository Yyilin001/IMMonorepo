import IMV2ServerContracts
import Foundation

/// 可重放的转发工作类型。
public enum V2ForwardWorkReplayKind: String, Codable, Sendable { case delivery, media }

/// 一次运维重放请求。
public struct V2ForwardWorkReplayCommand: Equatable, Sendable {
    /// 本次重放的幂等操作标识。
    public let operationID: UUID
    /// 目标逻辑分片，必须是已配置的归属之一。
    public let shardID: String
    /// 需要重放的工作类型。
    public let kind: V2ForwardWorkReplayKind
    /// 目标转发导出记录。
    public let exportID: UUID
    /// 媒体工作序号；投递类工作必须为空。
    public let ordinal: Int?
    /// 运维重放原因。
    public let reason: V2DurableWorkReplayReason

    /// 校验并保存重放请求。
    ///
    /// - Parameters:
    ///   - operationID: 幂等操作标识。
    ///   - shardID: 目标逻辑分片，需非空、不超过 128 字节且不含首尾空白。
    ///   - kind: 工作类型。
    ///   - exportID: 目标转发导出记录。
    ///   - ordinal: 媒体工作序号；投递类必须为空，媒体类需落在 `0...9`。
    ///   - reason: 运维重放原因。
    /// - Throws: 分片标识或序号与工作类型不匹配时抛出
    ///   ``V2ForwardWorkReplayError/invalidTarget``。
    public init(operationID: UUID, shardID: String, kind: V2ForwardWorkReplayKind,
                exportID: UUID, ordinal: Int? = nil, reason: V2DurableWorkReplayReason) throws {
        guard !shardID.isEmpty, shardID.utf8.count <= 128,
              shardID == shardID.trimmingCharacters(in: .whitespacesAndNewlines),
              (kind == .delivery && ordinal == nil) || (kind == .media && ordinal.map { (0...9).contains($0) } == true)
        else { throw V2ForwardWorkReplayError.invalidTarget }
        self.operationID = operationID; self.shardID = shardID; self.kind = kind
        self.exportID = exportID; self.ordinal = ordinal; self.reason = reason
    }
}

/// 运维重放错误。
public enum V2ForwardWorkReplayError: Error, Equatable, Sendable {
    /// 目标分片或工作序号不满足约束。
    case invalidTarget
    /// 请求的分片不在当前部署配置中。
    case unknownShard
    /// 目标工作当前不可重放。
    case targetUnavailable
    /// 目标房间归属已变更。
    case ownerChanged
    /// 同一操作标识已被不同载荷占用。
    case idempotencyConflict
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}

/// 单个分片内的运维重放能力。
public protocol V2ForwardWorkReplayStore: Sendable {
    /// 重放一条处于可重放状态的转发工作。
    ///
    /// - Parameters:
    ///   - command: 已校验的重放请求。
    ///   - operatorPrincipal: 已认证的运维主体标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 重放结果。
    /// - Throws: 归属变化、目标不可用或持久化失败时抛出。
    func replay(_ command: V2ForwardWorkReplayCommand, operatorPrincipal: String, now: Date) async throws -> V2DurableWorkReplayResult
}

/// 转发工作的运维重放服务。
///
/// 运维只能选择已配置的某个归属，不能指定数据库地址，也没有全表扫描入口。
public struct V2ForwardWorkOperatorReplayService: Sendable {
    private let stores: [String: any V2ForwardWorkReplayStore]
    private let principal: String
    private let now: @Sendable () -> Date

    /// 组合各分片的重放存储与运维主体。
    ///
    /// - Parameters:
    ///   - stores: 逻辑分片标识到重放实现的映射。
    ///   - operatorPrincipal: 运维主体标识，需符合通用运维主体格式。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Throws: 运维主体格式非法时抛出 ``V2ForwardWorkReplayError/invalidTarget``。
    public init(stores: [String: any V2ForwardWorkReplayStore], operatorPrincipal: String,
                now: @escaping @Sendable () -> Date = Date.init) throws {
        guard V2DurableWorkOperatorReplayService.isValidPrincipal(operatorPrincipal)
        else { throw V2ForwardWorkReplayError.invalidTarget }
        self.stores = stores; principal = operatorPrincipal; self.now = now
    }

    /// 按命令指定的分片执行重放。
    ///
    /// - Parameter command: 已校验的重放请求。
    /// - Returns: 重放结果。
    /// - Throws: 分片未配置时抛出 ``V2ForwardWorkReplayError/unknownShard``；
    ///   其余错误来自存储实现。
    public func replay(_ command: V2ForwardWorkReplayCommand) async throws -> V2DurableWorkReplayResult {
        guard let store = stores[command.shardID] else { throw V2ForwardWorkReplayError.unknownShard }
        return try await store.replay(command, operatorPrincipal: principal, now: now())
    }
}

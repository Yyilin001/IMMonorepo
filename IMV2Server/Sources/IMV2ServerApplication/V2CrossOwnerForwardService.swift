import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

/// 单个源归属所需的转发存储组合。
public struct V2ForwardSourceEndpoint: Sendable {
    /// 源端转发导出存储。
    let exports: any V2ForwardExportPreparing
    /// 源端回执查询存储。
    let receipts: any V2ForwardReceiptReading
    /// 源端投递任务存储。
    let jobs: any V2ForwardDeliveryStatusReading

    /// 组合源归属的三类存储。
    ///
    /// - Parameters:
    ///   - exports: 转发导出存储。
    ///   - receipts: 回执查询存储。
    ///   - jobs: 投递任务存储。
    public init(exports: any V2ForwardExportPreparing, receipts: any V2ForwardReceiptReading, jobs: any V2ForwardDeliveryStatusReading) {
        self.exports = exports; self.receipts = receipts; self.jobs = jobs
    }
}

/// 跨归属转发的源端服务。
///
/// 前台只提交源端意图并读取不可变完成状态；目标侧的 I/O 由运行时持久化工作器独立于请求执行，
/// 因此前台调用不会等待跨归属网络往返。
public struct V2CrossOwnerForwardService: V2CrossOwnerForwarding {
    private let sources: [String: V2ForwardSourceEndpoint]
    private let now: @Sendable () -> Date
    /// 组合各源归属的存储端点。
    ///
    /// - Parameters:
    ///   - sources: 源分片标识到存储端点的映射。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Throws: 映射为空或含纯空白分片标识时抛出
    ///   ``V2ForwardDeliveryError/invalidConfiguration``。
    public init(sources: [String: V2ForwardSourceEndpoint], now: @escaping @Sendable () -> Date = Date.init) throws {
        guard !sources.isEmpty, sources.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw V2ForwardDeliveryError.invalidConfiguration }
        self.sources = sources; self.now = now
    }

    /// 提交一次跨归属转发并返回当前可见状态。
    ///
    /// 源端准备阶段的领域错误会被映射为稳定的错误码结果，而不是抛给调用方；容量不足同样按
    /// 未完成返回。若持久化回执已经是终态则直接返回；否则查询投递任务是否已暂停。
    ///
    /// - Parameters:
    ///   - actor: 发起转发的用户。
    ///   - operation: 转发的幂等操作标识。
    ///   - source: 源消息引用。
    ///   - sourceRoute: 源房间的已选定归属。
    ///   - target: 目标房间。
    ///   - targetRoute: 目标房间的已选定归属。
    /// - Returns: 终态结果或仍在等待的状态。
    /// - Throws: 源分片未配置时抛出 ``V2RoomShardStorageRegistryError/unknownShardID``；
    ///   回执处于非法中间态时抛出 ``V2ForwardExportError/corruptPersistenceState``。
    public func forward(actor: UserID, operation: MessageForwardOperationID, source: V2ForwardMessageReference,
                        sourceRoute: V2RoomShardRoute, target: RoomID, targetRoute: V2RoomShardRoute) async throws -> V2CrossOwnerForwardOutcome {
        guard let endpoint = sources[sourceRoute.shardID] else { throw V2RoomShardStorageRegistryError.unknownShardID }
        func failure(_ code: String) throws -> V2CrossOwnerForwardOutcome {
            .completed(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: code))
        }
        func terminal(_ result: V2ForwardImportOutcome) throws -> V2CrossOwnerForwardOutcome {
            switch result {
            case .accepted(let id, let sequence):
                return .completed(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: id, roomSequence: sequence, errorCode: nil))
            case .rejected(let code): return try failure(code)
            case .pending: throw V2ForwardExportError.corruptPersistenceState
            }
        }
        let export: V2ForwardExport
        do {
            if let result = try await endpoint.receipts.terminalStatus(actor: actor, operation: operation, source: source, target: target) {
                return try terminal(result)
            }
            switch try await endpoint.exports.prepareForDelivery(actorUserID: actor, operationID: operation, source: source,
                sourceRoute: sourceRoute, targetRoomID: target, targetRoute: targetRoute, now: now()) {
            case .export(let prepared): export = prepared
            case .terminal(let result): return try terminal(result)
            }
        } catch V2ForwardExportError.sourceUnavailable { return try failure("NOT_FOUND")
        } catch V2ForwardExportError.sourceChanged { return try failure("SOURCE_CHANGED")
        } catch V2ForwardExportError.mediaUnavailable { return try failure("MEDIA_UNAVAILABLE")
        } catch V2ForwardExportError.idempotencyConflict { return try failure("IDEMPOTENCY_CONFLICT")
        } catch V2ForwardExportError.invalidRequest { return try failure("INVALID_ARGUMENT")
        } catch V2ForwardExportError.capacityExceeded { return .pending(paused: false) }
        if let result = try await endpoint.receipts.status(exportID: export.intent.exportID) {
            return try terminal(result)
        }
        return .pending(paused: try await endpoint.jobs.isPaused(exportID: export.intent.exportID))
    }
}

import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

public struct V2ActorForwardSourceEndpoint: Sendable {
    let receipts: any V2ForwardReceiptReading
    let jobs: any V2ForwardDeliveryStatusReading

    public init(receipts: any V2ForwardReceiptReading,
                jobs: any V2ForwardDeliveryStatusReading) {
        self.receipts = receipts; self.jobs = jobs
    }
}

/// 源导出准备通过 RoomRef 进行；持久化投递仍由工作器负责，
/// 不会在目标 I/O 期间一直占用源房间轮次。
public struct V2ActorCrossOwnerForwardService: V2CrossOwnerForwarding {
    private let sources: [String: V2ActorForwardSourceEndpoint]
    private let sourceCommand: @Sendable (V2RoomForwardCommand, ContinuousClock.Instant) async throws -> V2RoomForwardResult
    private let deadline: @Sendable () -> ContinuousClock.Instant

    public init(sources: [String: V2ActorForwardSourceEndpoint],
                sourceCommand: @escaping @Sendable (V2RoomForwardCommand, ContinuousClock.Instant) async throws -> V2RoomForwardResult,
                deadline: @escaping @Sendable () -> ContinuousClock.Instant) throws {
        guard !sources.isEmpty,
              sources.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw V2ForwardDeliveryError.invalidConfiguration
        }
        self.sources = sources; self.sourceCommand = sourceCommand
        self.deadline = deadline
    }

    public func forward(actor: UserID, operation: MessageForwardOperationID,
                        source: V2ForwardMessageReference, sourceRoute: V2RoomShardRoute,
                        target: RoomID, targetRoute: V2RoomShardRoute) async throws -> V2CrossOwnerForwardOutcome {
        try await forward(actor: actor, operation: operation, source: source,
            sourceRoute: sourceRoute, target: target, targetRoute: targetRoute,
            deadline: deadline())
    }

    public func forward(actor: UserID, operation: MessageForwardOperationID,
                        source: V2ForwardMessageReference, sourceRoute: V2RoomShardRoute,
                        target: RoomID, targetRoute: V2RoomShardRoute,
                        deadline operationDeadline: ContinuousClock.Instant) async throws -> V2CrossOwnerForwardOutcome {
        guard ContinuousClock().now < operationDeadline else {
            throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
        }
        guard let endpoint = sources[sourceRoute.shardID] else {
            throw V2RoomShardStorageRegistryError.unknownShardID
        }
        if let prior = try await endpoint.receipts.terminalStatus(actor: actor,
            operation: operation, source: source, target: target) {
            return try completed(prior, source: source.messageID, target: target)
        }
        let request = V2ActorPrepareForwardExportWire(actorUserID: actor,
            operationID: operation, source: source, targetRoomID: target,
            targetShardID: targetRoute.shardID, targetEpoch: targetRoute.epoch)
        let export: V2ForwardExport
        do {
            switch try await sourceCommand(.prepareExport(request), operationDeadline) {
            case .preparedExport(let value): export = try value.toDomain()
            case .terminalExport(let value):
                return try completed(value.toDomain(), source: source.messageID, target: target)
            default: throw V2ForwardExportError.corruptPersistenceState
            }
        } catch V2ForwardExportError.sourceUnavailable {
            return try failed("NOT_FOUND", source: source.messageID, target: target)
        } catch V2ForwardExportError.sourceChanged {
            return try failed("SOURCE_CHANGED", source: source.messageID, target: target)
        } catch V2ForwardExportError.mediaUnavailable {
            return try failed("MEDIA_UNAVAILABLE", source: source.messageID, target: target)
        } catch V2ForwardExportError.idempotencyConflict {
            return try failed("IDEMPOTENCY_CONFLICT", source: source.messageID, target: target)
        } catch V2ForwardExportError.invalidRequest {
            return try failed("INVALID_ARGUMENT", source: source.messageID, target: target)
        } catch V2ForwardExportError.capacityExceeded {
            return .pending(paused: false)
        }
        if let result = try await endpoint.receipts.status(exportID: export.intent.exportID) {
            return try completed(result, source: source.messageID, target: target)
        }
        return .pending(paused: try await endpoint.jobs.isPaused(exportID: export.intent.exportID))
    }

    private func completed(_ value: V2ForwardImportOutcome,
                           source: MessageID, target: RoomID) throws -> V2CrossOwnerForwardOutcome {
        switch value {
        case .accepted(let id, let sequence):
            return .completed(try .init(sourceMessageID: source, targetRoomID: target,
                messageID: id, roomSequence: sequence, errorCode: nil))
        case .rejected(let code): return try failed(code, source: source, target: target)
        case .pending: throw V2ForwardExportError.corruptPersistenceState
        }
    }

    private func failed(_ code: String, source: MessageID,
                        target: RoomID) throws -> V2CrossOwnerForwardOutcome {
        .completed(try .init(sourceMessageID: source, targetRoomID: target,
            messageID: nil, roomSequence: nil, errorCode: code))
    }
}

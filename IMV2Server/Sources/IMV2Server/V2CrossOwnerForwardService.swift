import Foundation
import IMV2Core

public enum V2ForwardPendingError: Error, Equatable, Sendable { case pending, paused }

public enum V2CrossOwnerForwardOutcome: Sendable {
    case completed(V2ForwardMessageResult)
    case pending(paused: Bool)
}

public protocol V2CrossOwnerForwarding: Sendable {
    func forward(actor: UserID, operation: MessageForwardOperationID, source: V2ForwardMessageReference,
                 sourceRoute: V2RoomShardRoute, target: RoomID, targetRoute: V2RoomShardRoute) async throws -> V2CrossOwnerForwardOutcome
}

public struct V2ForwardSourceEndpoint: Sendable {
    let exports: PostgresV2ForwardExportStore
    let receipts: PostgresV2ForwardReceiptStore
    let jobs: PostgresV2ForwardDeliveryStore
    public init(exports: PostgresV2ForwardExportStore, receipts: PostgresV2ForwardReceiptStore, jobs: PostgresV2ForwardDeliveryStore) {
        self.exports = exports; self.receipts = receipts; self.jobs = jobs
    }
}

/// Foreground only commits source intent and reads immutable completion.
/// The runtime's durable worker performs target I/O independently of a request.
public struct V2CrossOwnerForwardService: V2CrossOwnerForwarding {
    private let sources: [String: V2ForwardSourceEndpoint]
    private let now: @Sendable () -> Date
    public init(sources: [String: V2ForwardSourceEndpoint], now: @escaping @Sendable () -> Date = Date.init) throws {
        guard !sources.isEmpty, sources.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw V2ForwardDeliveryError.invalidConfiguration }
        self.sources = sources; self.now = now
    }

    public func forward(actor: UserID, operation: MessageForwardOperationID, source: V2ForwardMessageReference,
                        sourceRoute: V2RoomShardRoute, target: RoomID, targetRoute: V2RoomShardRoute) async throws -> V2CrossOwnerForwardOutcome {
        guard let endpoint = sources[sourceRoute.shardID] else { throw V2RoomShardStorageRegistryError.unknownShardID }
        func failure(_ code: String) throws -> V2CrossOwnerForwardOutcome {
            .completed(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: code))
        }
        let export: V2ForwardExport
        do {
            export = try await endpoint.exports.prepare(actorUserID: actor, operationID: operation, source: source,
                sourceRoute: sourceRoute, targetRoomID: target, targetRoute: targetRoute, now: now())
        } catch V2ForwardExportError.sourceUnavailable { return try failure("NOT_FOUND")
        } catch V2ForwardExportError.sourceChanged { return try failure("SOURCE_CHANGED")
        } catch V2ForwardExportError.mediaUnavailable { return try failure("MEDIA_UNAVAILABLE")
        } catch V2ForwardExportError.idempotencyConflict { return try failure("IDEMPOTENCY_CONFLICT")
        } catch V2ForwardExportError.invalidRequest { return try failure("INVALID_ARGUMENT")
        } catch V2ForwardExportError.capacityExceeded { return .pending(paused: false) }
        if let result = try await endpoint.receipts.status(exportID: export.intent.exportID) {
            switch result {
            case .accepted(let id, let sequence):
                return .completed(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: id, roomSequence: sequence, errorCode: nil))
            case .rejected(let code): return try failure(code)
            case .pending: throw V2ForwardExportError.corruptPersistenceState
            }
        }
        return .pending(paused: try await endpoint.jobs.isPaused(exportID: export.intent.exportID))
    }
}

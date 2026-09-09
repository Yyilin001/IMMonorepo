import Foundation

public enum V2ForwardWorkReplayKind: String, Codable, Sendable { case delivery, media }

public struct V2ForwardWorkReplayCommand: Equatable, Sendable {
    public let operationID: UUID
    public let shardID: String
    public let kind: V2ForwardWorkReplayKind
    public let exportID: UUID
    public let ordinal: Int?
    public let reason: V2DurableWorkReplayReason

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

public enum V2ForwardWorkReplayError: Error, Equatable, Sendable {
    case invalidTarget, unknownShard, targetUnavailable, ownerChanged, idempotencyConflict, corruptPersistenceState
}

public protocol V2ForwardWorkReplayStore: Sendable {
    func replay(_ command: V2ForwardWorkReplayCommand, operatorPrincipal: String, now: Date) async throws -> V2DurableWorkReplayResult
}

/// The operator selects one configured owner, never a database URL or a scan.
public struct V2ForwardWorkOperatorReplayService: Sendable {
    private let stores: [String: any V2ForwardWorkReplayStore]
    private let principal: String
    private let now: @Sendable () -> Date

    public init(stores: [String: any V2ForwardWorkReplayStore], operatorPrincipal: String,
                now: @escaping @Sendable () -> Date = Date.init) throws {
        guard V2DurableWorkOperatorReplayService.isValidPrincipal(operatorPrincipal)
        else { throw V2ForwardWorkReplayError.invalidTarget }
        self.stores = stores; principal = operatorPrincipal; self.now = now
    }

    public func replay(_ command: V2ForwardWorkReplayCommand) async throws -> V2DurableWorkReplayResult {
        guard let store = stores[command.shardID] else { throw V2ForwardWorkReplayError.unknownShard }
        return try await store.replay(command, operatorPrincipal: principal, now: now())
    }
}

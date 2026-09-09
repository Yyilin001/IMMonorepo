import Foundation

public struct V2GroupInviteDirectoryImportCommand: Equatable, Sendable {
    public let operationID: UUID
    public let shardID: String
    public let ownerEpoch: Int64
    public let roomID: UUID
    public let afterInviteID: UUID?
    public let limit: Int
    public let reason: V2DurableWorkReplayReason

    public init(operationID: UUID, shardID: String, ownerEpoch: Int64, roomID: UUID,
                afterInviteID: UUID?, limit: Int, reason: V2DurableWorkReplayReason) throws {
        guard !shardID.isEmpty, shardID.utf8.count <= 128,
              shardID == shardID.trimmingCharacters(in: .whitespacesAndNewlines),
              ownerEpoch >= 0, (1...100).contains(limit)
        else { throw V2GroupInviteDirectoryImportError.invalidRequest }
        self.operationID = operationID; self.shardID = shardID; self.ownerEpoch = ownerEpoch
        self.roomID = roomID; self.afterInviteID = afterInviteID; self.limit = limit; self.reason = reason
    }
}

public enum V2GroupInviteDirectoryImportOutcome: String, Codable, Sendable { case applied, conflict }

public struct V2GroupInviteDirectoryImportResult: Equatable, Codable, Sendable {
    public let operationID: UUID
    public let outcome: V2GroupInviteDirectoryImportOutcome
    public let sourceCount: Int
    public let insertedCount: Int
    public let publishedCount: Int
    public let unchangedCount: Int
    public let nextCursor: UUID?
    public let conflictingInviteIDs: [UUID]
    public let wasIdempotent: Bool

    public init(operationID: UUID, outcome: V2GroupInviteDirectoryImportOutcome, sourceCount: Int,
                insertedCount: Int, publishedCount: Int, unchangedCount: Int, nextCursor: UUID?,
                conflictingInviteIDs: [UUID], wasIdempotent: Bool) {
        self.operationID = operationID; self.outcome = outcome; self.sourceCount = sourceCount
        self.insertedCount = insertedCount; self.publishedCount = publishedCount; self.unchangedCount = unchangedCount
        self.nextCursor = nextCursor; self.conflictingInviteIDs = conflictingInviteIDs; self.wasIdempotent = wasIdempotent
    }
}

public enum V2GroupInviteDirectoryImportError: Error, Equatable, Sendable {
    case invalidRequest, unknownShard, ownerChanged, idempotencyConflict, corruptPersistenceState
}

/// Operator principal is fixed by construction, never accepted from HTTP input.
public protocol V2GroupInviteDirectoryImporting: Sendable {
    func importPage(_ command: V2GroupInviteDirectoryImportCommand) async throws -> V2GroupInviteDirectoryImportResult
}

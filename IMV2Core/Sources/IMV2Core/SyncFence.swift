import Foundation

/// Opaque, server-issued cursor capability. Its contents are intentionally not
/// parsed outside the server capability boundary.
public struct V2SyncToken: Equatable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw V2CoreError.invalidIdentifier
        }
        self.rawValue = rawValue
    }
}

/// Opaque proof that scopes an ACK to one issued incremental range or snapshot.
public struct V2SyncReceipt: Equatable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw V2CoreError.invalidIdentifier
        }
        self.rawValue = rawValue
    }
}

public struct SyncPosition: Equatable, Sendable {
    public let generation: UInt64
    public let sequence: UInt64

    public init(generation: UInt64, sequence: UInt64) throws {
        guard generation > 0, generation <= UInt64(Int64.max) else {
            throw V2CoreError.invalidGeneration
        }
        guard sequence <= UInt64(Int64.max) else {
            throw V2RevisionValidationError.outOfRange
        }
        self.generation = generation
        self.sequence = sequence
    }
}

public struct PendingReset: Equatable, Sendable {
    public let snapshotID: SnapshotID
    public let basePosition: SyncPosition

    public init(snapshotID: SnapshotID, basePosition: SyncPosition) {
        self.snapshotID = snapshotID
        self.basePosition = basePosition
    }
}

public enum DeviceSyncState: Equatable, Sendable {
    case ready(SyncPosition)
    case resetPending(PendingReset)
}

public struct DeviceSyncCursor: Equatable, Sendable {
    public private(set) var state: DeviceSyncState

    public init(readyAt position: SyncPosition) {
        self.state = .ready(position)
    }

    public mutating func beginReset(_ pendingReset: PendingReset) throws {
        guard case .ready(let current) = state,
              pendingReset.basePosition.generation > current.generation
        else {
            throw DeviceSyncCursorError.invalidResetTransition
        }
        state = .resetPending(pendingReset)
    }

    public mutating func acknowledgeSnapshot(
        snapshotID: SnapshotID,
        basePosition: SyncPosition
    ) -> SnapshotAcknowledgementResult {
        guard case .resetPending(let pending) = state else {
            return .rejected(.noResetPending)
        }
        guard pending.snapshotID == snapshotID else {
            return .rejected(.snapshotMismatch)
        }
        guard pending.basePosition == basePosition else {
            return .rejected(.generationOrWatermarkMismatch)
        }
        state = .ready(basePosition)
        return .accepted(nextPosition: basePosition)
    }
}

public enum DeviceSyncCursorError: Error, Equatable, Sendable {
    case invalidResetTransition
}

public enum SnapshotAcknowledgementRejection: Equatable, Sendable {
    case noResetPending
    case snapshotMismatch
    case generationOrWatermarkMismatch
}

public enum SnapshotAcknowledgementResult: Equatable, Sendable {
    case accepted(nextPosition: SyncPosition)
    case rejected(SnapshotAcknowledgementRejection)
}

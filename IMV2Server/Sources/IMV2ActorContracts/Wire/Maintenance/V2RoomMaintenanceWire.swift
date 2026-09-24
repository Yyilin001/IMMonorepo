import Foundation
import IMV2Core

/// Maintenance is a service-only room turn. Its work is retried by scanning
/// durable state again, not by inventing a per-request operation identity.
public enum V2RoomMaintenanceCommand: Codable, Equatable, Sendable {
    case trimLog(V2ActorRoomLogTrimWire)
    case purgeBookkeeping(V2ActorRoomBookkeepingPurgeWire)

    public var roomID: RoomID {
        switch self {
        case .trimLog(let value): value.roomID
        case .purgeBookkeeping(let value): value.roomID
        }
    }

    public var replayPolicy: V2RoomReplayPolicy { .noAutomaticRetry }
}

public enum V2ActorRoomLogRetentionModeWire: String, Codable, Equatable, Sendable {
    case window, permanent
}

public struct V2ActorRoomLogTrimWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let mode: V2ActorRoomLogRetentionModeWire
    public let windowSeconds: TimeInterval

    public init(roomID: RoomID, mode: V2ActorRoomLogRetentionModeWire,
                windowSeconds: TimeInterval) {
        self.roomID = roomID
        self.mode = mode
        self.windowSeconds = windowSeconds
    }
}

public struct V2ActorRoomBookkeepingPurgeWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let retentionSeconds: TimeInterval
    public let idempotencyRetentionSeconds: TimeInterval
    public let rowLimit: Int

    public init(roomID: RoomID, retentionSeconds: TimeInterval,
                idempotencyRetentionSeconds: TimeInterval, rowLimit: Int) {
        self.roomID = roomID
        self.retentionSeconds = retentionSeconds
        self.idempotencyRetentionSeconds = idempotencyRetentionSeconds
        self.rowLimit = rowLimit
    }
}

public enum V2RoomMaintenanceResult: Codable, Equatable, Sendable {
    case logTrimmed(V2ActorRoomLogTrimResultWire)
    case bookkeepingPurged(V2ActorRoomBookkeepingPurgeResultWire)
}

public struct V2ActorRoomLogTrimResultWire: Codable, Equatable, Sendable {
    public let advancedFloor: Bool
    public let deletedEvents: Int

    public init(advancedFloor: Bool, deletedEvents: Int) {
        self.advancedFloor = advancedFloor
        self.deletedEvents = deletedEvents
    }
}

public struct V2ActorRoomBookkeepingPurgeResultWire: Codable, Equatable, Sendable {
    public let deletedReviewJobs: Int
    public let deletedOperationRows: Int

    public init(deletedReviewJobs: Int, deletedOperationRows: Int) {
        self.deletedReviewJobs = deletedReviewJobs
        self.deletedOperationRows = deletedOperationRows
    }
}

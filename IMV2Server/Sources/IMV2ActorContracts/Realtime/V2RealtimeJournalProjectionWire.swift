import Foundation
import IMV2Core

/// Stable database incarnation: journal sequences are never routing epochs.
public struct V2RealtimeJournalSource: Hashable, Codable, Sendable {
    public let sourceID: String
    public let incarnationID: UUID
    public let partitionID: Int
    public init(sourceID: String, incarnationID: UUID, partitionID: Int) {
        self.sourceID = sourceID; self.incarnationID = incarnationID; self.partitionID = partitionID
    }
}

public struct V2RealtimeJournalProjectionFence: Equatable, Codable, Sendable {
    public let publisherIncarnationID: UUID
    public let sourceLeaseEpoch: Int64
    public let sourceLeaseToken: UUID
    public let sourceLeaseExpiresAt: Date
    public let routingPartitionEpoch: Int64
    public let routingLeaseToken: UUID
    public let sessionID: UUID
    public let interestGeneration: Int64
    public let gatewayIncarnationID: UUID
    public init(publisherIncarnationID: UUID, sourceLeaseEpoch: Int64, sourceLeaseToken: UUID,
                sourceLeaseExpiresAt: Date, routingPartitionEpoch: Int64, routingLeaseToken: UUID,
                sessionID: UUID, interestGeneration: Int64, gatewayIncarnationID: UUID) {
        self.publisherIncarnationID = publisherIncarnationID; self.sourceLeaseEpoch = sourceLeaseEpoch
        self.sourceLeaseToken = sourceLeaseToken; self.sourceLeaseExpiresAt = sourceLeaseExpiresAt
        self.routingPartitionEpoch = routingPartitionEpoch; self.routingLeaseToken = routingLeaseToken
        self.sessionID = sessionID; self.interestGeneration = interestGeneration
        self.gatewayIncarnationID = gatewayIncarnationID
    }
    /// Deadline renewal may retain the same exact ownership generation.
    public func sameGeneration(as other: Self) -> Bool {
        publisherIncarnationID == other.publisherIncarnationID && sourceLeaseEpoch == other.sourceLeaseEpoch
            && sourceLeaseToken == other.sourceLeaseToken && routingPartitionEpoch == other.routingPartitionEpoch
            && routingLeaseToken == other.routingLeaseToken && sessionID == other.sessionID
            && interestGeneration == other.interestGeneration && gatewayIncarnationID == other.gatewayIncarnationID
    }
}

/// Owner snapshot for the viewers covered by this filtered interest generation.
/// Viewer join revisions and the room-wide permission version are independent.
public struct V2RealtimeJournalRoomAuthorization: Equatable, Codable, Sendable {
    public let roomID: RoomID
    public let ownerEpoch: UInt64
    public let permissionVersion: UInt64
    /// Independent owner control floor observed in the current-state snapshot;
    /// it can be ahead of the snapshot's published journal cut.
    public let controlVersion: UInt64
    public let viewerMembershipRevisions: [UserID: UInt64]
    public let highWatermark: UInt64
    public init(roomID: RoomID, ownerEpoch: UInt64, permissionVersion: UInt64, controlVersion: UInt64,
                viewerMembershipRevisions: [UserID: UInt64], highWatermark: UInt64) {
        self.roomID = roomID; self.ownerEpoch = ownerEpoch; self.permissionVersion = permissionVersion
        self.controlVersion = controlVersion
        self.viewerMembershipRevisions = viewerMembershipRevisions; self.highWatermark = highWatermark
    }
}

public enum V2RealtimeJournalProjectionChange: Equatable, Codable, Sendable {
    case authorization(V2RealtimeJournalRoomAuthorization)
    case head(roomID: RoomID, highWatermark: UInt64, ownerEpoch: UInt64, permissionVersion: UInt64)
    case invalidate(roomID: RoomID)
    case controlInvalidation(roomID: RoomID, ownerEpoch: UInt64, controlVersion: UInt64)
    /// Version/device-change indication only. The receiving Gateway must read
    /// authoritative source state before installing user/device authorization.
    case userControlInvalidation(userID: UserID, controlVersion: UInt64, deviceID: UUID?, membershipRoomID: RoomID? = nil)
}

public struct V2RealtimeJournalProjectionEntry: Equatable, Codable, Sendable {
    public let sequence: Int64
    public let change: V2RealtimeJournalProjectionChange
    public init(sequence: Int64, change: V2RealtimeJournalProjectionChange) {
        self.sequence = sequence; self.change = change
    }
}

/// Coalesced room heads are independent of the ordered control journal. Source
/// dirty-row revisions are acknowledged at the source, never used as sequences.
public struct V2RealtimeJournalRoomHead: Equatable, Codable, Sendable {
    public let roomID: RoomID
    public let highWatermark: UInt64
    public let ownerEpoch: UInt64
    public let controlVersion: UInt64
    public init(roomID: RoomID, highWatermark: UInt64, ownerEpoch: UInt64, controlVersion: UInt64) {
        self.roomID = roomID; self.highWatermark = highWatermark
        self.ownerEpoch = ownerEpoch; self.controlVersion = controlVersion
    }
}

public enum V2RealtimeJournalProjectionPayload: Equatable, Codable, Sendable {
    /// Requests a receiver-owned authoritative cold cut. No publisher grant or
    /// authorization snapshot is supplied; only actual installation may reply.
    case baseline(minimumCut: Int64)
    /// Every omitted sequence in this range was evaluated by the sender's
    /// exact interest generation. An empty range still advances the checkpoint.
    case changes(fromExclusive: Int64, throughInclusive: Int64, entries: [V2RealtimeJournalProjectionEntry])
    /// Complete cold owner authorization snapshot fenced at this journal cut.
    /// The sender must reconcile concurrent control mutations through the cut.
    case snapshot(cut: Int64, rooms: [V2RealtimeJournalRoomAuthorization])
    case heads([V2RealtimeJournalRoomHead])
}

public struct V2RealtimeJournalProjectionBatch: Equatable, Codable, Sendable {
    public let batchID: UUID
    public let source: V2RealtimeJournalSource
    public let fence: V2RealtimeJournalProjectionFence
    public let payload: V2RealtimeJournalProjectionPayload
    public init(batchID: UUID = UUID(), source: V2RealtimeJournalSource,
                fence: V2RealtimeJournalProjectionFence, payload: V2RealtimeJournalProjectionPayload) {
        self.batchID = batchID; self.source = source; self.fence = fence; self.payload = payload
    }
}

/// Actual local projection commit, independent of RPC queue admission and sockets.
public struct V2RealtimeJournalProjectionApplied: Equatable, Codable, Sendable {
    public let batchID: UUID
    public let source: V2RealtimeJournalSource
    public let fence: V2RealtimeJournalProjectionFence
    public let appliedThrough: Int64
    public let snapshotInstalled: Bool
    public init(batchID: UUID, source: V2RealtimeJournalSource, fence: V2RealtimeJournalProjectionFence,
                appliedThrough: Int64, snapshotInstalled: Bool) {
        self.batchID = batchID; self.source = source; self.fence = fence
        self.appliedThrough = appliedThrough; self.snapshotInstalled = snapshotInstalled
    }
}

/// Dirty H acknowledgement has no control-journal position to advance.
public struct V2RealtimeJournalHeadsApplied: Equatable, Codable, Sendable {
    public let batchID: UUID
    public let source: V2RealtimeJournalSource
    public let fence: V2RealtimeJournalProjectionFence
    public init(batchID: UUID, source: V2RealtimeJournalSource, fence: V2RealtimeJournalProjectionFence) {
        self.batchID = batchID; self.source = source; self.fence = fence
    }
}

public enum V2RealtimeJournalProjectionResult: Equatable, Codable, Sendable {
    case applied(V2RealtimeJournalProjectionApplied)
    case headsApplied(V2RealtimeJournalHeadsApplied)
    case stale
    case snapshotRequired
    case overloaded
    case invalid
}

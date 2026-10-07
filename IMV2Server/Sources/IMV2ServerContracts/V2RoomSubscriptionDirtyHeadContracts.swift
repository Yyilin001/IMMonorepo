import Foundation
import IMV2ActorContracts

/// A committed change receipt, not a new grant or a preallocated event cursor.
/// Completing it only clears this exact coalesced revision; latest H survives.
public struct V2RoomSubscriptionDirtyHead: Equatable, Sendable {
    public let activation: V2RoomActivationToken
    public let highWatermark: UInt64
    public let revision: Int64
    public let roomControlVersion: Int64
    public init(activation: V2RoomActivationToken, highWatermark: UInt64, revision: Int64, roomControlVersion: Int64) {
        self.activation = activation; self.highWatermark = highWatermark
        self.revision = revision; self.roomControlVersion = roomControlVersion
    }
}
public typealias V2RoomSubscriptionDirtyHeadAcknowledge = @Sendable ([V2RoomSubscriptionDirtyHead], ContinuousClock.Instant) async throws -> Void

public struct V2RoomSubscriptionDirtyCursor: Sendable {
    public let partitionID: Int
    public let roomID: UUID
    public init(partitionID: Int, roomID: UUID) { self.partitionID = partitionID; self.roomID = roomID }
}
public struct V2RoomSubscriptionDirtyPage: Sendable {
    public let changes: [V2RoomSubscriptionDirtyHead]
    public let nextCursor: V2RoomSubscriptionDirtyCursor?
    public init(changes: [V2RoomSubscriptionDirtyHead], nextCursor: V2RoomSubscriptionDirtyCursor?) { self.changes = changes; self.nextCursor = nextCursor }
}
public typealias V2RoomSubscriptionDirtyChanges = @Sendable (V2ActorHostIdentity, V2RoomSubscriptionDirtyCursor?, Int, ContinuousClock.Instant) async throws -> V2RoomSubscriptionDirtyPage

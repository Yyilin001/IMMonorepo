import Foundation

/// One authorized room observation. It has no list-ranking semantics.
/// A caller must obtain every field from the same owner-side read snapshot.
public struct V2RoomSynchronizationState: Equatable, Sendable {
    public let roomID: RoomID
    public let ownerEpoch: UInt64
    public let viewerMembershipRevision: UInt64
    public let head: UInt64
    public let trimmedThrough: UInt64
    public let readThrough: UInt64
    public let latestOwnMessageSequence: UInt64

    public var unreadCount: UInt64 {
        head - max(readThrough, latestOwnMessageSequence)
    }

    public init(roomID: RoomID, ownerEpoch: UInt64, viewerMembershipRevision: UInt64,
                head: UInt64, trimmedThrough: UInt64, readThrough: UInt64,
                latestOwnMessageSequence: UInt64) throws {
        guard [ownerEpoch, viewerMembershipRevision, head, trimmedThrough, readThrough,
               latestOwnMessageSequence].allSatisfy({ $0 <= UInt64(Int64.max) }),
              trimmedThrough <= head, readThrough <= head, latestOwnMessageSequence <= head
        else { throw V2RoomSynchronizationError.invalidState }
        self.roomID = roomID
        self.ownerEpoch = ownerEpoch
        self.viewerMembershipRevision = viewerMembershipRevision
        self.head = head
        self.trimmedThrough = trimmedThrough
        self.readThrough = readThrough
        self.latestOwnMessageSequence = latestOwnMessageSequence
    }

    /// Compare complete observations instead of independently merging their unread counts.
    /// Revocation and the account generation remain separate, higher-priority fences.
    public func disposition(replacing current: Self) throws -> V2RoomStateDisposition {
        guard roomID == current.roomID else { throw V2RoomSynchronizationError.roomMismatch }
        if self == current { return .unchanged }
        let incoming = [ownerEpoch, viewerMembershipRevision, head, trimmedThrough,
                        readThrough, latestOwnMessageSequence]
        let previous = [current.ownerEpoch, current.viewerMembershipRevision, current.head,
                        current.trimmedThrough, current.readThrough, current.latestOwnMessageSequence]
        if zip(incoming, previous).allSatisfy({ $0 >= $1 }) { return .advance }
        if zip(incoming, previous).allSatisfy({ $0 <= $1 }) { return .superseded }
        // Mixed observations can arise from concurrent reads or an owner transition.
        // Neither payload proves the missing combination; ask the owner again.
        return .reconcile
    }
}

public enum V2RoomStateDisposition: Equatable, Sendable {
    case unchanged
    case advance
    case superseded
    case reconcile
}

public enum V2RoomSynchronizationError: Error, Equatable, Sendable {
    case invalidState
    case roomMismatch
}

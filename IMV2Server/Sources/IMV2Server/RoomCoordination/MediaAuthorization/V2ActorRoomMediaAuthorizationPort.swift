import Foundation
import IMV2ActorContracts
import IMV2Core

/// Media control uses this port at both grant issuance and provider exchange.
/// Device authority and provider bytes remain with the control coordinator.
public struct V2ActorRoomMediaAuthorizationPort: Sendable {
    private let query: @Sendable (V2RoomMediaAuthorizationQuery, ContinuousClock.Instant) async throws -> V2RoomMediaAuthorizationResult

    public init(query: @escaping @Sendable (V2RoomMediaAuthorizationQuery, ContinuousClock.Instant) async throws -> V2RoomMediaAuthorizationResult) {
        self.query = query
    }

    public func capture(_ request: V2ActorMessageMediaVisibilityWire,
                        deadline: ContinuousClock.Instant) async throws -> V2ActorMessageMediaVisibilitySnapshotWire? {
        switch try await query(.messageVisibility(request), deadline) {
        case .visible(let snapshot):
            guard snapshot.roomID == request.roomID,
                  snapshot.messageID == request.messageID,
                  snapshot.mediaID == request.mediaID,
                  snapshot.membershipRevision <= UInt64(Int64.max),
                  snapshot.contentRevision > 0,
                  snapshot.contentRevision <= UInt64(Int64.max),
                  snapshot.mediaUpdatedAt.timeIntervalSince1970.isFinite else {
                throw V2RoomCallFailure.notAccepted(.invalidRequest)
            }
            return snapshot
        case .notVisible: return nil
        }
    }

    /// A stored grant never substitutes for a fresh room turn. Any change in
    /// membership/content/media generation invalidates the prior snapshot.
    public func recheck(_ snapshot: V2ActorMessageMediaVisibilitySnapshotWire,
                        actorUserID: UserID,
                        deadline: ContinuousClock.Instant) async throws -> Bool {
        let request = V2ActorMessageMediaVisibilityWire(roomID: snapshot.roomID,
            messageID: snapshot.messageID, mediaID: snapshot.mediaID,
            actorUserID: actorUserID)
        return try await capture(request, deadline: deadline) == snapshot
    }
}

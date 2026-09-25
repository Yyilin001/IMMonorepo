import Foundation
import IMV2ActorContracts
import IMV2Core

/// 媒体控制在授权签发和服务商交换时都使用此端口。
/// 设备权限与服务商字节数据仍由控制域协调者负责。
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

    /// 已存储的授权不能代替新的房间执行轮次。成员、内容或媒体代次
    /// 发生任何变化，都会使先前的快照失效。
    public func recheck(_ snapshot: V2ActorMessageMediaVisibilitySnapshotWire,
                        actorUserID: UserID,
                        deadline: ContinuousClock.Instant) async throws -> Bool {
        let request = V2ActorMessageMediaVisibilityWire(roomID: snapshot.roomID,
            messageID: snapshot.messageID, mediaID: snapshot.mediaID,
            actorUserID: actorUserID)
        return try await capture(request, deadline: deadline) == snapshot
    }
}

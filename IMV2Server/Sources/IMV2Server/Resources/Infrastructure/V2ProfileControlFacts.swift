import Foundation
import IMV2Core

struct V2ProfileControlSnapshot: Sendable {
    let rows: [V2ProfileControlFacts]; let observedAt: Date; let deviceExpiresAt: Date
}
struct V2ProfileControlFacts: Sendable, Equatable {
    let view: V2ProfileView?; let directRoomID: UUID?; let directRouteEpoch: Int64?; let directShardID: String?
    let relationshipAllowed: Bool; let relationshipUpdatedAt: Date?
    let contactAlias: V2ContactAlias?
    init(view: V2ProfileView?, directRoomID: UUID?, directRouteEpoch: Int64?, directShardID: String?,
         relationshipAllowed: Bool, relationshipUpdatedAt: Date?, contactAlias: V2ContactAlias? = nil) {
        self.view = view; self.directRoomID = directRoomID; self.directRouteEpoch = directRouteEpoch
        self.directShardID = directShardID; self.relationshipAllowed = relationshipAllowed
        self.relationshipUpdatedAt = relationshipUpdatedAt; self.contactAlias = contactAlias
    }
    func sameAuthorizationFacts(as other: Self) -> Bool { self == other }
}

import Foundation
import IMV2Core

struct V2ProfileControlSnapshot: Sendable {
    let rows: [V2ProfileControlFacts]; let observedAt: Date; let deviceExpiresAt: Date
}
struct V2ProfileControlFacts: Sendable, Equatable {
    let view: V2ProfileView?; let directRoomID: UUID?; let directRouteEpoch: Int64?; let directShardID: String?
    let relationshipAllowed: Bool; let relationshipUpdatedAt: Date?
    func sameAuthorizationFacts(as other: Self) -> Bool { self == other }
}

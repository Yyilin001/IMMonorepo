import IMV2ServerContracts
import Foundation
import IMV2Core

package struct V2ProfileControlSnapshot: Sendable {
    package let rows: [V2ProfileControlFacts]; package let observedAt: Date; package let deviceExpiresAt: Date
    package init(rows: [V2ProfileControlFacts], observedAt: Date, deviceExpiresAt: Date) {
        self.rows = rows; self.observedAt = observedAt; self.deviceExpiresAt = deviceExpiresAt
    }
}
package struct V2ProfileControlFacts: Sendable, Equatable {
    package let view: V2ProfileView?; package let directRoomID: UUID?; package let directRouteEpoch: Int64?; package let directShardID: String?
    package let relationshipAllowed: Bool; package let relationshipUpdatedAt: Date?
    package let contactAlias: V2ContactAlias?
    package init(view: V2ProfileView?, directRoomID: UUID?, directRouteEpoch: Int64?, directShardID: String?,
         relationshipAllowed: Bool, relationshipUpdatedAt: Date?, contactAlias: V2ContactAlias? = nil) {
        self.view = view; self.directRoomID = directRoomID; self.directRouteEpoch = directRouteEpoch
        self.directShardID = directShardID; self.relationshipAllowed = relationshipAllowed
        self.relationshipUpdatedAt = relationshipUpdatedAt; self.contactAlias = contactAlias
    }
    func sameAuthorizationFacts(as other: Self) -> Bool { self == other }
}

package struct V2ProfileControlRequest: Sendable {
    package let keys: [V2ProfileViewLookupKey]
    package let actor: UserID
    package let device: DeviceID

    package init(keys: [V2ProfileViewLookupKey], actor: UserID, device: DeviceID) {
        self.keys = keys; self.actor = actor; self.device = device
    }

    package func validate() throws {
        guard actor.uuidValue != nil, device.uuidValue != nil, !keys.isEmpty, keys.count <= 100,
              keys.allSatisfy({ $0.userID.uuidValue != nil })
        else { throw V2ProfileViewReadError.invalidRequest }
    }
}


package enum V2ProfileControlBatchError: Error, Equatable { case deadlineExceeded, closed, corruptResult }

package protocol V2ProfileControlReading: Sendable {
    func read(_ request: V2ProfileControlRequest, deadline: ContinuousClock.Instant) async throws -> V2ProfileControlSnapshot
    func close() async
}

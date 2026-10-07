import Foundation
import IMV2ActorContracts

/// Local immutable input created only inside the Host-approved pure-pull
/// callback. It carries no substitute for the PostgreSQL viewer/token fence.
package struct V2GrantedRoomLogPull: Sendable {
    package let id: UUID
    package let token: V2RoomActivationToken
    package let query: V2ActorRoomLogPullWire
    package let callDeadline: ContinuousClock.Instant

    package init(id: UUID = UUID(), token: V2RoomActivationToken,
                 query: V2ActorRoomLogPullWire, callDeadline: ContinuousClock.Instant) {
        self.id = id; self.token = token; self.query = query; self.callDeadline = callDeadline
    }
}

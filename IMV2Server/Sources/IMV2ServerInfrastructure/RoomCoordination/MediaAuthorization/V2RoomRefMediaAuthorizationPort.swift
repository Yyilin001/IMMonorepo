import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ActorContracts
import IMV2ActorRuntime

public extension V2ActorRoomMediaAuthorizationPort {
    init(directory: V2RoomDirectory) {
        self.init { query, deadline in
            let response = try await directory.room(query.roomID).call(.mediaAuthorization(query),
                principal: .user(query.actorUserID), deadline: deadline)
            guard case .mediaAuthorization(let value) = response else { throw V2RoomCallFailure.outcomeUnknown }
            return value
        }
    }
}

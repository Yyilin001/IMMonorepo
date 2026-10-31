import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ActorContracts
import IMV2ActorRuntime

public extension V2ActorRoomMediaAuthorizationPort {
    init(directory: V2RoomDirectory) {
        self.init { query, deadline in
            let principal: V2RoomClientPrincipal
            switch query {
            case .profileVisibilityCohort(let cohort):
                guard cohort.validatedTargetCount != nil else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
                principal = .service
            default:
                guard let actor = query.actorUserID else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
                principal = .user(actor)
            }
            let response = try await directory.room(query.roomID).call(.mediaAuthorization(query),
                principal: principal, deadline: deadline)
            guard case .mediaAuthorization(let value) = response else { throw V2RoomCallFailure.outcomeUnknown }
            return value
        }
    }
}

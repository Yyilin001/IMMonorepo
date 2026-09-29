import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import IMV2ActorContracts
import IMV2Core

extension V2ResourceProfilePresentationService {
    public init(controlDatabase: any Database, authorization: V2ActorRoomMediaAuthorizationPort,
                avatars: V2ResourceAvatarDelivery) {
        self.init(controlReads: V2ProfileControlBatcher(database: controlDatabase),
            avatars: { requests in try await avatars.authorizedAvatars(requests: requests, database: controlDatabase) },
            authorization: authorization)
    }
}

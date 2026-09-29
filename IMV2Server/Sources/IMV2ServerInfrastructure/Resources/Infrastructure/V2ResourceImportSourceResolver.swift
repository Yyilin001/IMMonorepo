import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core

public typealias V2AvatarImportAuthorization = @Sendable (V2ProfileViewLookupKey,MediaID,ResourceVariantID,UserID,DeviceID) async throws -> Void
public struct V2ResourceImportSourceAccess:Sendable {
    let database:any Database
    let recheck:@Sendable () async throws -> Void
}
public struct V2ResourceImportSourceResolver:Sendable {
    let control:any Database
    let rooms:any V2RoomShardRouting
    let owners:[String:any Database]
    let authorization:V2ActorRoomMediaAuthorizationPort
    let avatarAuthorization:V2AvatarImportAuthorization
    public init(controlDatabase:any Database,rooms:any V2RoomShardRouting,ownerDatabases:[String:any Database],
                authorization:V2ActorRoomMediaAuthorizationPort,avatarAuthorization:@escaping V2AvatarImportAuthorization) {
        control=controlDatabase;self.rooms=rooms;owners=ownerDatabases;self.authorization=authorization;self.avatarAuthorization=avatarAuthorization
    }
    func database(for source:V2ResourceImportSource) async throws -> any Database {
        switch source {
        case .avatar:return control
        case .message(let location,_,_):
            let route=try await rooms.route(for:location.roomID)
            guard let owner=owners[route.shardID] else { throw V2ResourceProviderError.configurationInvalid }
            return owner
        }
    }
    func authorize(_ source:V2ResourceImportSource,actor:UserID,device:DeviceID) async throws -> V2ResourceImportSourceAccess {
        switch source {
        case .avatar(let key,let mediaID,let variantID):
            try await avatarAuthorization(key,mediaID,variantID,actor,device)
            return .init(database:control,recheck:{try await avatarAuthorization(key,mediaID,variantID,actor,device)})
        case .message(let location,let mediaID,_):
            let route=try await rooms.route(for:location.roomID)
            guard let owner=owners[route.shardID],let snapshot=try await authorization.capture(
                .init(roomID:location.roomID,messageID:location.messageID,mediaID:mediaID,actorUserID:actor),deadline:.now + .seconds(10))
            else { throw V2MediaStoreError.downloadNotAuthorized }
            return .init(database:owner,recheck:{
                guard try await rooms.route(for:location.roomID)==route,
                      try await authorization.recheck(snapshot,actorUserID:actor,deadline:.now + .seconds(10)) else { throw V2MediaStoreError.downloadNotAuthorized }
            })
        }
    }
}

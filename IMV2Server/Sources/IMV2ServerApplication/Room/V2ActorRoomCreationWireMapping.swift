import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

extension V2ActorGroupCreationIntentWire {
    public init(domain: V2GroupRoomCreationIntent) {
        self.init(actorUserID: domain.actorUserID, operationID: domain.operationID, roomID: domain.roomID,
                  eventID: domain.eventID, roomShardID: domain.roomShardID, routeEpoch: domain.routeEpoch,
                  requestFingerprint: domain.requestFingerprint, audienceMemberCount: domain.audienceMemberCount,
                  state: domain.state == .prepared ? .prepared : .committed)
    }
    public func toDomain() throws -> V2GroupRoomCreationIntent {
        guard roomShardID == roomShardID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw V2GroupRoomCreationIntentStoreError.invalidIntent
        }
        return try .init(actorUserID: actorUserID, operationID: operationID, roomID: roomID, eventID: eventID,
                  roomShardID: roomShardID, routeEpoch: routeEpoch, requestFingerprint: requestFingerprint,
                  audienceMemberCount: audienceMemberCount,
                  state: state == .prepared ? .prepared : .committed)
    }
}

extension V2ActorGroupCreationManifestPageWire {
    public init(domain: V2GroupRoomCreationManifestPage) {
        self.init(pageNumber: domain.pageNumber, memberUserIDs: domain.memberUserIDs,
                  isFinal: domain.isFinal, digest: domain.digest)
    }
    public func toDomain() throws -> V2GroupRoomCreationManifestPage {
        let page = try V2GroupRoomCreationManifestPage(pageNumber: pageNumber, memberUserIDs: memberUserIDs, isFinal: isFinal)
        guard page.memberUserIDs == memberUserIDs, page.digest == digest else {
            throw V2GroupRoomCreationIntentStoreError.invalidIntent
        }
        return page
    }
}
extension V2ActorGroupCreationManifestSliceWire {
    public init(domain: V2GroupRoomCreationManifestSlice) {
        self.init(memberUserIDs: domain.memberUserIDs, hasMore: domain.hasMore)
    }
    public func toDomain() throws -> V2GroupRoomCreationManifestSlice {
        guard memberUserIDs.count <= V2GroupRoomCreationManifestPage.maximumMemberCount,
              Set(memberUserIDs).count == memberUserIDs.count else {
            throw V2GroupRoomCreationIntentStoreError.invalidIntent
        }
        return .init(memberUserIDs: memberUserIDs, hasMore: hasMore)
    }
}

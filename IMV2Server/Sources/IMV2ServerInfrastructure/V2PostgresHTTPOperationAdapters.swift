import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core

extension PostgresV2SocialRelationshipStore: V2SocialOperationHandling {
    public func loadSocialOperationSnapshot(actorUserID: UserID, targetUserID: UserID) async throws -> V2SocialOperationSnapshot {
        do { return try await socialOperationSnapshot(actorUserID: actorUserID, targetUserID: targetUserID) }
        catch V2SocialRelationshipStoreError.actorInactive { throw V2HTTPOperationError.actorInactive }
    }
}
extension PostgresV2AccountPreferenceOperationStore: V2AccountPreferenceOperationHandling {
    public func loadAccountPreferenceSnapshot(ownerUserID: UserID, kind: V2OperationKind) async throws -> V2AccountPreferenceSnapshot {
        do { return try await snapshot(ownerUserID: ownerUserID, kind: kind) }
        catch V2SocialRelationshipStoreError.actorInactive { throw V2HTTPOperationError.actorInactive }
    }
}
extension PostgresV2DirectRoomOperationStore: V2DirectRoomOperationHandling {}
extension PostgresV2GroupCreationOperationStore: V2GroupCreationOperationHandling {}

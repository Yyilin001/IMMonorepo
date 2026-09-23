import FluentKit
import Foundation
import IMV2Core

/// Keeps contact aliases in their configured store and routes group nicknames
/// to the selected room owner. The owner transaction validates the route again.
public struct V2RoutedProfilePresentationStore: V2ProfilePresentationManaging {
    private let aliases: any V2ProfilePresentationManaging
    private let router: any V2RoomShardRouting
    private let owners: any V2RoomShardStorageResolving
    private let now: @Sendable () -> Date

    public init(aliases: any V2ProfilePresentationManaging, router: any V2RoomShardRouting,
                owners: any V2RoomShardStorageResolving, now: @escaping @Sendable () -> Date = Date.init) {
        self.aliases = aliases
        self.router = router
        self.owners = owners
        self.now = now
    }

    public func contactAliases(ownerUserID: UserID, afterTargetUserID: UserID?, limit: Int) async throws -> V2ContactAliasPage {
        try await aliases.contactAliases(ownerUserID: ownerUserID, afterTargetUserID: afterTargetUserID, limit: limit)
    }

    public func updateContactAlias(ownerUserID: UserID, targetUserID: UserID, operationID: ContactAliasOperationID,
                                   expectedRevision: V2ProfileRevision?, remarkName: String?) async throws -> V2ContactAlias {
        try await aliases.updateContactAlias(ownerUserID: ownerUserID, targetUserID: targetUserID,
            operationID: operationID, expectedRevision: expectedRevision, remarkName: remarkName)
    }

    public func groupNicknames(actorUserID: UserID, roomID: RoomID, afterUserID: UserID?, limit: Int) async throws -> V2GroupNicknamePage {
        guard (1...500).contains(limit), roomID.uuidValue != nil else { throw V2ProfilePresentationError.invalidPresentation }
        return try await owner(roomID).groupNicknames(actorUserID: actorUserID, roomID: roomID, afterUserID: afterUserID, limit: limit)
    }

    public func updateOwnGroupNickname(actorUserID: UserID, roomID: RoomID, operationID: GroupNicknameOperationID,
                                       expectedRevision: V2ProfileRevision?, nickname: String?) async throws -> V2GroupMemberPresentation {
        guard roomID.uuidValue != nil else { throw V2ProfilePresentationError.invalidPresentation }
        return try await owner(roomID).updateOwnGroupNickname(actorUserID: actorUserID, roomID: roomID,
            operationID: operationID, expectedRevision: expectedRevision, nickname: nickname)
    }

    private func owner(_ roomID: RoomID) async throws -> PostgresV2ProfilePresentationStore {
        let route = try await router.route(for: roomID)
        let location = try owners.location(for: route.shardID)
        guard location.schema == "im_v2" else { throw V2RoomShardStorageRegistryError.invalidLocation }
        return .init(database: location.database, roomID: roomID, ownerRoute: route, now: now)
    }
}

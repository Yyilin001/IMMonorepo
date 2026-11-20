import Foundation
import IMV2Core
import IMV2ClientRuntime

/// Account-owned group directory, management queries and durable commands.
/// Confirmation windows/revisions retain the existing domain validation and recovery identity.
public final class V2GroupService: Sendable, V2ClientGroupInvitationManaging, V2ClientMembershipDirectoryTransport {
    public let accountID: UserID
    public let creation: V2GroupCreationService
    public let membership: V2GroupMembershipService
    public let capabilities: V2GroupCapabilityService
    public let invitations: V2GroupInvitationService
    public let administration: V2GroupAdministrationService
    private let store: GRDBV2LocalSyncStore
    private let transport: any V2ClientMembershipDirectoryTransport
    private let invitationReader: any V2ClientGroupInvitationManaging
    private let lifetime: V2DirectoryLifetime
    public init(accountID: UserID, store: GRDBV2LocalSyncStore,
                transport: any V2ClientMembershipDirectoryTransport, invitationReader: any V2ClientGroupInvitationManaging,
                creation: V2GroupCreationOperationService, membership: V2MembershipOperationService,
                capabilities: V2GroupCapabilityOperationService, invitations: V2InvitationOperationService,
                administration: V2MemberAdministrationOperationService,
                closeQueries: @escaping @Sendable () async -> Void = {}) {
        lifetime = .init(onClose: closeQueries)
        self.accountID = accountID; self.store = store; self.transport = transport; self.invitationReader = invitationReader
        self.creation = .init(service: creation, lifetime: lifetime)
        self.membership = .init(service: membership, lifetime: lifetime)
        self.capabilities = .init(service: capabilities, lifetime: lifetime)
        self.invitations = .init(service: invitations, lifetime: lifetime)
        self.administration = .init(service: administration, lifetime: lifetime)
    }
    public func page(matching query: String = "", after cursor: V2ClientGroupDirectoryCursor? = nil, limit: Int = 50) async throws -> V2ClientGroupDirectoryPage {
        try await lifetime.run { [store] in try await store.groupDirectoryPage(matching: query, after: cursor, limit: limit) }
    }
    public func listRoomMembers(roomID: RoomID, cursor: String?, pageSize: Int) async throws -> V2ClientRoomMembersPage {
        try await lifetime.run { [store, transport] in
            guard (1...100).contains(pageSize), try await store.roomAllowsLocalRead(roomID: roomID) else { throw V2DirectoryServiceError.invalidInput }
            let page = try await transport.listRoomMembers(roomID: roomID, cursor: cursor, pageSize: pageSize)
            guard page.roomID == roomID, page.nextCursor == nil || page.nextCursor != cursor,
                  try await store.roomAllowsLocalRead(roomID: roomID) else { throw V2DirectoryServiceError.invalidInput }
            return page
        }
    }
    public func announcement(in room: RoomID) async throws -> V2ClientGroupAnnouncement? {
        try await lifetime.run { [store] in try await store.groupAnnouncement(roomID: room) }
    }
    public func rolePolicy(in room: RoomID) async throws -> V2ClientGroupRolePolicyState {
        try await lifetime.run { [store] in try await store.groupRolePolicyState(roomID: room) }
    }
    public func retryRolePolicy(in room: RoomID) async throws -> V2ClientGroupRolePolicyState {
        try await lifetime.run { [store] in
            _ = try await store.resumeRolePolicyBaseline(roomID: room)
            return try await store.groupRolePolicyState(roomID: room)
        }
    }
    public func activeInvites(roomID: RoomID) async throws -> [V2GroupInviteLink] {
        try await lifetime.run { [invitationReader] in try await invitationReader.activeInvites(roomID: roomID) }
    }
    public func preview(secret: V2GroupInviteSecret) async throws -> V2GroupInvitePreview {
        try await lifetime.run { [invitationReader] in try await invitationReader.preview(secret: secret) }
    }
    public func pendingRequests(roomID: RoomID, cursor: String?, pageSize: Int) async throws -> V2ClientGroupJoinRequestPage {
        try await lifetime.run { [invitationReader] in try await invitationReader.pendingRequests(roomID: roomID, cursor: cursor, pageSize: pageSize) }
    }
    public func handlers() -> [V2OperationWorkDispatcher.Handler] {
        [.init(kind: .groupRoom) { [creation] in try await creation.execute($0) },
         .init(kind: .membership) { [membership] in try await membership.execute($0) }]
        + [V2OperationKind.pinnedMessage, .groupAnnouncement, .groupPermission, .groupRole, .groupOwnership, .groupDissolution].map { kind in
            .init(kind: kind) { [capabilities] in try await capabilities.execute($0) }
        } + [V2OperationKind.groupInvite, .groupJoinRequest, .groupJoinDecision].map { kind in
            .init(kind: kind) { [invitations] in try await invitations.execute($0) }
        } + [V2OperationKind.memberMute, .moderatedMemberRemoval].map { kind in
            .init(kind: kind) { [administration] in try await administration.execute($0) }
        }
    }
    public func close() async { await lifetime.close() }
}

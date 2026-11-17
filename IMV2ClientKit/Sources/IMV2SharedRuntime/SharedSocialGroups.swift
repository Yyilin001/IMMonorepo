import Foundation
import IMV2Core
import IMV2ClientRuntime

struct SharedContact: Encodable, Sendable { let userID: String; let state: String }
struct SharedIdentity: Encodable, Sendable { let userID: String; let handle: String; let name: String }
struct SharedWork: Encodable, Sendable {
    let id: String; let kind: String; let target: String; let status: String; let retryable: Bool; let roomID: String?
}
struct SharedMember: Encodable, Sendable { let userID: String; let role: String }
struct SharedRolePolicy: Encodable, Sendable { let role: String; let permissions: [String]; let revision: UInt64 }
struct SharedGroup: Encodable, Sendable {
    let roomID: String; let actorRole: String; let revision: UInt64; let members: [SharedMember]; let hasMore: Bool
    let announcement: String; let announcementRevision: UInt64; let policies: [SharedRolePolicy]
    let permissions: [String]; let policiesReady: Bool
}
struct SharedDirectory: Encodable, Sendable {
    let contacts: [SharedContact]; let scope: String; let hasMoreContacts: Bool; let firstContacts: Bool
    let groups: [SharedConversation]; let hasMoreGroups: Bool; let firstGroups: Bool
    let avatarEditor: SharedAvatarEditor?
    let profiles: [SharedProfile]; let selectedProfile: String?; let community: SharedCommunitySnapshot
    let identity: SharedIdentity?; let group: SharedGroup?; let works: [SharedWork]; let failure: String?
}

/// Account-owned adapters only. Durable domain services, revisions and receipts stay in Swift.
/// Discovery presentation is memory-only and expires independently of persisted command targets.
actor SharedSocialGroups {
    let avatars: SharedAvatars
    private let people: SharedPeople
    private let community: SharedCommunity
    private var contactsVisible = false
    private let account: UserID
    private let store: GRDBV2LocalSyncStore
    private let transport: V2ProtobufSyncTransport
    private let directory: V2HTTPPublicIdentityDirectory
    private let social: V2SocialOperationService
    private let direct: V2DirectRoomOperationService
    private let creation: V2GroupCreationOperationService
    private let membership: V2MembershipOperationService
    private let capability: V2GroupCapabilityOperationService
    private var tasks: [Task<Void, Never>] = []
    private var groupTasks: [Task<Void, Never>] = []
    private var socialRows: [SharedWork] = [], directRows: [SharedWork] = [], memberRows: [SharedWork] = [], capabilityRows: [SharedWork] = []
    private var lookup: V2PublicIdentityLookupSnapshot?
    private var memberPage: V2ClientRoomMembersPage?
    private var scope = "accepted"
    private var contactCursor: V2ClientRelationshipCursor?, nextContact: V2ClientRelationshipCursor?
    private var groupCursor: V2ClientGroupDirectoryCursor?, nextGroup: V2ClientGroupDirectoryCursor?
    private var failure: SharedFailure?

    init(storageScope: V2AccountStorageScope, installation: String, account: UserID, device: DeviceID, store: GRDBV2LocalSyncStore, transport: V2ProtobufSyncTransport, base: URL, http: V2SessionHTTPAuthorization, platform: SharedPlatform) async throws {
        self.account = account; self.store = store; self.transport = transport
        people = try SharedPeople(account: account, device: device, store: store, base: base, http: http, imageHTTP: platform.imageHTTP)
        community = try SharedCommunity(account: account, store: store, base: base, http: http, installation: installation, persistence: platform.securePersistence)
        let activation = UUID()
        directory = try .init(endpoint: base.appendingPathComponent("v2/public-identities/resolve"), actorUserID: account, credentials: http, transport: http)
        social = .init(accountID: account, store: store, client: try V2HTTPSocialOperationClient(baseURL: base, credentials: http, transport: http))
        direct = .init(accountID: account, store: store, client: try V2HTTPDirectRoomOperationClient(baseURL: base, credentials: http, transport: http))
        creation = .init(accountID: account, store: store, client: try V2HTTPGroupCreationOperationClient(baseURL: base, credentials: http, transport: http))
        membership = .init(accountID: account, activationID: activation, store: store, client: try V2HTTPMembershipOperationClient(baseURL: base, credentials: http, transport: http))
        capability = .init(accountID: account, activationID: activation, store: store, client: try V2HTTPGroupCapabilityOperationClient(baseURL: base, credentials: http, transport: http))
        let resources = try await V2ResourceCenter.make(scope: storageScope, store: store)
        do { avatars = try SharedAvatars(account: account, device: device, store: store, resources: resources, base: base, http: http, imageHTTP: platform.imageHTTP, uploader: platform.uploader)
             try await avatars.start() }
        catch { await resources.close(); throw error }

    }
    func handlers() async -> [V2OperationWorkDispatcher.Handler] {
        return [.init(kind: .relationship) { [social] in try await social.execute($0) },
         .init(kind: .userBlock) { [social] in try await social.execute($0) },
         .init(kind: .directRoom) { [direct] in try await direct.execute($0) },
         .init(kind: .groupRoom) { [creation] in try await creation.execute($0) },
         .init(kind: .membership) { [membership] in try await membership.execute($0) }]
        + [V2OperationKind.pinnedMessage, .groupAnnouncement, .groupPermission, .groupRole, .groupOwnership, .groupDissolution].map { kind in
            .init(kind: kind) { [capability] in try await capability.execute($0) }
        } + (await people.handlers()) + (await community.handlers()) + (await avatars.handlers())
    }
    func start() async {
        guard tasks.isEmpty else { return }
        await community.start()
        tasks = [Task { do { try await membership.runPreparation() } catch is CancellationError {} catch { failure = sharedFailure(error) } },
                 Task { do { try await capability.runPreparation() } catch is CancellationError {} catch { failure = sharedFailure(error) } },
                 Task { do { for try await rows in await social.updates() {
                     socialRows = rows.prefix(50).map { Self.work($0.work, target: $0.command.targetUserID.rawValue) }
                 } } catch is CancellationError {} catch { failure = sharedFailure(error) } },
                 Task { do { for try await rows in await direct.updates() {
                     directRows = rows.prefix(50).map { row in
                         var room: String?
                         if case .opened(let id, _) = row.receipt?.outcome { room = id.rawValue }
                         return Self.work(row.work, target: row.command.targetUserID.rawValue, room: room)
                     }
                 } } catch is CancellationError {} catch { failure = sharedFailure(error) } }]
    }
    func stop() async {
        await avatars.close(); await people.close(); await community.close()
        let all = tasks + groupTasks
        all.forEach { $0.cancel() }; for task in all { await task.value }
        tasks = []; groupTasks = []; lookup = nil; memberPage = nil
    }
    private static func work(_ value: V2OperationWork, target: String, room: String? = nil) -> SharedWork {
        .init(id: value.id.uuidString, kind: value.identity.kind.rawValue, target: target,
              status: value.execution.isTerminal ? value.execution.rawValue : value.scheduling.rawValue,
              retryable: !value.execution.isTerminal && value.scheduling == .needsAttention, roomID: room)
    }
    private func observeGroup(_ room: RoomID) async {
        groupTasks.forEach { $0.cancel() }; for task in groupTasks { await task.value }
        memberRows = []; capabilityRows = []
        groupTasks = [Task { do { for try await rows in await membership.updates(roomID: room) {
            memberRows = rows.prefix(50).map { row in
                row.work.map { Self.work($0, target: row.intent.targetUserID.rawValue) } ?? .init(id: row.id.uuidString, kind: "membership", target: row.intent.targetUserID.rawValue, status: String(describing: row.preparationState), retryable: false, roomID: nil)
            }
        } } catch is CancellationError {} catch { failure = sharedFailure(error) } },
        Task { do { for try await rows in await capability.updates(roomID: room) {
            capabilityRows = rows.prefix(50).map { row in
                row.work.map { Self.work($0, target: room.rawValue) } ?? .init(id: row.id.uuidString, kind: row.intent.action.kind.rawValue, target: room.rawValue, status: String(describing: row.preparationState), retryable: false, roomID: nil)
            }
        } } catch is CancellationError {} catch { failure = sharedFailure(error) } }]
    }
    func execute(_ request: SharedRequest) async throws {
        switch request.operation {
        case .openAvatarEditor:
            contactsVisible = false; await community.clear()
            try await avatars.open(room: request.roomID.map(RoomID.init))
        case .changeAvatar: try await avatars.change(request)
        case .avatarAction: try await avatars.action(request)
        case .contacts:
            guard let scope = request.scope, ["accepted", "incoming", "outgoing", "blocked"].contains(scope) else { throw SharedFailure.invalidInput }
            self.scope = scope; contactCursor = nil; contactsVisible = true
        case .contactsNext: contactCursor = nextContact
        case .groupsFirst: groupCursor = nil
        case .groupsNext: groupCursor = nextGroup
        case .lookupIdentity:
            lookup = nil
            guard let handle = request.text else { throw SharedFailure.invalidInput }
            lookup = try await directory.resolveForPresentation(handle: handle)
        case .clearDiscovery:
            lookup = nil; contactsVisible = false; await people.clearAll(); await community.clear(); await avatars.clear()
        case .socialAction:
            await people.clearAll()
            guard let raw = request.targetUserID, let action = request.action else { throw SharedFailure.invalidInput }
            let target = try UserID(raw)
            let command: V2SocialOperationAction
            if let relationship = V2RelationshipAction(rawValue: action) { command = .relationship(relationship) }
            else if let block = V2UserBlockAction(rawValue: action) { command = .userBlock(block) }
            else { throw SharedFailure.invalidInput }
            _ = try await social.enqueue(action: command, targetUserID: target)
        case .openDirect:
            guard let lookup, lookup.isValid(), lookup.identity.userID.rawValue == request.targetUserID else { throw SharedFailure.invalidInput }
            _ = try await direct.enqueue(publicIdentity: lookup.identity)
        case .createGroup:
            guard let title = request.text, let ids = request.members, ids.count <= 100 else { throw SharedFailure.invalidInput }
            _ = try await creation.enqueue(title: title, members: ids.map { try UserID($0) })
        case .profiles:
            guard let page = request.page, let ids = request.members else { throw SharedFailure.invalidInput }
            let context = try profileContext(request.scope ?? "relationship", roomID: request.roomID)
            try await people.show(page: page, ids: ids, context: context)
            await people.load(page: page)
        case .clearProfiles:
            guard let page = request.page else { throw SharedFailure.invalidInput }
            await people.clear(page: page)
        case .avatar:
            guard let id = request.targetUserID else { throw SharedFailure.invalidInput }
            let context = try profileContext(request.scope ?? "relationship", roomID: request.roomID)
            try await people.show(page: "avatar", ids: [id], context: context)
            await people.load(page: "avatar")
            try await people.loadAvatar(page: "avatar", userID: id)
        case .openProfile:
            lookup = nil
            let context = try profileContext(request.scope ?? "relationship", roomID: request.roomID)
            try await people.open(try UserID(request.targetUserID ?? ""), context: context)
        case .saveAlias: try await people.save(request)
        case .invitations, .invitationsNext, .previewInvite, .refreshInvite, .inviteAction, .muteMember:
            try await community.execute(request)
        case .openGroup, .groupMembersNext:
            contactsVisible = false
            guard let raw = request.roomID else { throw SharedFailure.invalidInput }
            let room = try RoomID(raw)
            guard try await store.roomAllowsLocalRead(roomID: room) else { throw SharedFailure.invalidInput }
            let cursor = request.operation == .groupMembersNext && memberPage?.roomID == room ? memberPage?.nextCursor : nil
            let page = try await transport.listRoomMembers(roomID: room, cursor: cursor, pageSize: 50)
            try Task.checkCancellation()
            if memberPage?.roomID != room { await observeGroup(room) }
            memberPage = page
        case .groupAction:
            guard let raw = request.roomID, let action = request.action, let revision = request.revision else { throw SharedFailure.invalidInput }
            let room = try RoomID(raw)
            // Use the explicitly confirmed revision; never fetch and silently replace it here.
            guard memberPage?.roomID == room, try await store.roomAllowsLocalRead(roomID: room) else { throw SharedFailure.invalidInput }
            if action == "add" || action == "remove" || action == "leave" {
                let target = action == "leave" ? account : try UserID(request.targetUserID ?? "")
                _ = try await membership.enqueue(targetUserID: target, confirmation: membership.confirmationWindow(roomID: room, action: action == "add" ? .add : .remove, expectedMembershipRevision: revision))
            } else {
                let command: V2GroupCapabilityAction
                switch action {
                case "announcement": command = .announcement(body: request.text ?? "", expectedRevision: revision)
                case "role":
                    guard let role = V2RoomMembershipRole(rawValue: request.role ?? ""), role != .owner else { throw SharedFailure.invalidInput }
                    command = .memberRole(targetUserID: try UserID(request.targetUserID ?? ""), role: role, expectedMembershipRevision: revision)
                case "transfer": command = .transferOwnership(targetUserID: try UserID(request.targetUserID ?? ""), expectedMembershipRevision: revision)
                case "dissolve": command = .dissolve(expectedMembershipRevision: revision)
                case "permissions":
                    guard let role = V2RoomMembershipRole(rawValue: request.role ?? ""), let values = request.permissions else { throw SharedFailure.invalidInput }
                    let permissions = try values.map { value -> V2GroupPermission in guard let permission = V2GroupPermission(rawValue: value) else { throw SharedFailure.invalidInput }; return permission }
                    command = .rolePermissions(role: role, permissions: Set(permissions), expectedRevision: revision)
                default: throw SharedFailure.invalidInput
                }
                _ = try await capability.enqueue(confirmation: capability.confirmationWindow(roomID: room, action: command))
            }
        case .discardDirectoryDraft:
            guard let id = UUID(uuidString: request.intentID ?? "") else { throw SharedFailure.invalidInput }
            if memberRows.contains(where: { $0.id == id.uuidString && $0.status == "paused" }) { try await membership.discardDraft(id: id) }
            else if capabilityRows.contains(where: { $0.id == id.uuidString && $0.status == "paused" }) { try await capability.discardDraft(id: id) }
            else if try await community.discard(id) {}
            else { throw SharedFailure.invalidInput }
        case .retryDirectoryWork:
            guard let id = UUID(uuidString: request.intentID ?? ""), let work = try await store.operationWork(id: id), work.identity.accountID == account else { throw SharedFailure.invalidInput }
            switch work.identity.kind {
            case .contactAlias: try await people.retry(id)
            case .groupInvite, .groupJoinRequest, .groupJoinDecision, .memberMute: try await community.retry(id, kind: work.identity.kind)
            case .relationship, .userBlock: try await social.resumeConfirmation(workID: id)
            case .directRoom: try await direct.resume(id: id)
            case .groupRoom: try await creation.resume(id: id)
            case .membership: try await membership.resumeConfirmation(id: id)
            case .groupAnnouncement, .groupPermission, .groupRole, .groupOwnership, .groupDissolution: try await capability.resumeConfirmation(id: id)
            default: throw SharedFailure.invalidInput
            }
        default: throw SharedFailure.invalidInput
        }
    }
    private func profileContext(_ scope: String, roomID: String?) throws -> V2ProfileViewContext {
        switch scope {
        case "relationship": return .relationship
        case "direct": return .directConversation
        case "room":
            guard let roomID else { throw SharedFailure.invalidInput }
            return .room(try RoomID(roomID))
        case "joinReview":
            guard let roomID else { throw SharedFailure.invalidInput }
            return .groupJoinReview(try RoomID(roomID))
        default: throw SharedFailure.invalidInput
        }
    }
    func snapshot() async throws -> SharedDirectory {
        let contacts: [SharedContact]
        if scope == "blocked" {
            // Block directory is bounded at the bridge; pagination uses the same stable target cursor.
            let rows = try await store.blocks().filter(\.isBlocked).sorted { $0.targetUserID.rawValue < $1.targetUserID.rawValue }
                .filter { contactCursor == nil || $0.targetUserID.rawValue > contactCursor!.targetUserID.rawValue }
            contacts = rows.prefix(50).map { .init(userID: $0.targetUserID.rawValue, state: "blocked") }
            nextContact = rows.count > 50 ? rows[49].mapCursor : nil
        } else {
            let page = try await store.relationshipPage(scope: scope == "incoming" ? .incomingRequests(currentUserID: account) : scope == "outgoing" ? .outgoingRequests(currentUserID: account) : .accepted, before: contactCursor, limit: 50)
            contacts = page.relationships.map { .init(userID: $0.targetUserID.rawValue, state: $0.state.rawValue) }; nextContact = page.nextCursor
        }
        let groups = try await store.groupDirectoryPage(after: groupCursor, limit: 50); nextGroup = groups.nextCursor
        var group: SharedGroup?
        if let page = memberPage, try await store.roomAllowsLocalRead(roomID: page.roomID) {
            let policy = try await store.groupRolePolicyState(roomID: page.roomID)
            let announcement = try await store.groupAnnouncement(roomID: page.roomID)
            let ready = policy.recovery == .ready
            let permissions = ready ? V2GroupPermission.allCases.filter { V2GroupPermissionDefaults.allows(role: page.actorRole, permission: $0, configured: policy.policies.first { $0.role == page.actorRole }?.permissions) }.map(\.rawValue) : []
            group = .init(roomID: page.roomID.rawValue, actorRole: page.actorRole.rawValue, revision: page.membershipRevision,
                members: page.members.map { .init(userID: $0.userID.rawValue, role: $0.role.rawValue) }, hasMore: page.nextCursor != nil,
                announcement: announcement?.body ?? "", announcementRevision: announcement?.revision ?? 0,
                policies: [V2RoomMembershipRole.admin, .member].map { role in
                    let configured = policy.policies.first { $0.role == role }
                    return .init(role: role.rawValue, permissions: (configured?.permissions ?? V2GroupPermissionDefaults.permissions(for: role)).map(\.rawValue).sorted(), revision: configured?.revision ?? 0)
                }, permissions: permissions, policiesReady: ready)
        }
        if lookup?.isValid() == false { lookup = nil }
        var works = socialRows + directRows + memberRows + capabilityRows
        if let latest = try await creation.latest() {
            var room: String?
            if case .created(let id, _, _, _) = latest.receipt?.outcome { room = id.rawValue }
            works.append(Self.work(latest.work, target: latest.intent.title, room: room))
        }
        if contactsVisible { try await people.showContacts(contacts.map(\.userID)) }
        let profiles = try await people.snapshot()
        let communitySnapshot = try await community.snapshot()
        works += communitySnapshot.works
        if let work = profiles.1 { works.append(work) }
        return .init(contacts: contacts, scope: scope, hasMoreContacts: nextContact != nil, firstContacts: contactCursor == nil,
            groups: groups.items.map { .init(id: $0.roomID.rawValue, title: $0.title, preview: "") }, hasMoreGroups: nextGroup != nil, firstGroups: groupCursor == nil,
            avatarEditor: try await avatars.snapshot(), profiles: profiles.0, selectedProfile: await people.selected?.rawValue, community: communitySnapshot, identity: lookup.map { .init(userID: $0.identity.userID.rawValue, handle: $0.identity.handle.rawValue, name: $0.identity.displayName) }, group: group, works: works, failure: failure?.rawValue)
    }
}
private extension V2ClientUserBlockProjection {
    var mapCursor: V2ClientRelationshipCursor { .init(updatedAt: updatedAt, targetUserID: targetUserID) }
}

import Foundation
import IMV2ClientRuntime

/// Native entry point for a standalone mobile host that owns its account session.
public final class V2MobileClient: Sendable {
    public struct Session: Sendable {
        public let state: String
        public let userID: String?
    }
    public struct Conversation: Sendable {
        public let id: String
        public let title: String
        public let preview: String
        public let unread: Int64
        public let updatedAt: Int64?
        public let isGroup: Bool
        public let peerID: String?
        public let isPinned: Bool
        public let isArchived: Bool
        public let muteUntil: Int64?
    }
    public struct Attachment: Sendable {
        public let id: String
        public let name: String
        public let contentType: String
        public let bytes: Int64

        fileprivate init(_ value: SharedAttachment) {
            id = value.id; name = value.name; contentType = value.contentType; bytes = value.bytes
        }
    }
    public struct Message: Sendable {
        public let id: String
        public let senderID: String
        public let text: String
        public let withdrawn: Bool
        public let hasMedia: Bool
        public let attachments: [Attachment]
        public let readByPeer: Bool
        public let replyToID: String?
        public let replyPreview: String?
        public let isForwarded: Bool
        public let revision: Int64?
        public let mutableRevision: Int64?
        public let preparedAttachments: Int64?
        public let totalAttachments: Int64?
        public let pendingStatus: String?
        public let createdAt: Int64?
    }
    public struct Window: Sendable {
        public let conversations: [Conversation]
        public let messages: [Message]
        public let hasOlder: Bool
        public let isLatest: Bool
    }
    public struct Profile: Sendable {
        public let page: String
        public let userID: String
        public let name: String
        public let handle: String
        public let alias: String?
        public let aliasRevision: UInt64?
        public let groupNickname: String?
        public let groupNicknameRevision: UInt64?
        public let remainingMilliseconds: Int64
        public let avatar: Data?
    }
    public struct AvatarEditor: Sendable {
        public let roomID: String?
        public let revision: UInt64
        public let canManage: Bool
        public let remainingMilliseconds: Int64
        public let hasAvatar: Bool
        public let name: String?
        public let handle: String?
        public let image: Data?
    }
    public struct AvatarImage: Sendable {
        public let data: Data
        public let remainingMilliseconds: Int64
    }
    public struct Readers: Sendable {
        public let roomID: String
        public let messageID: String
        public let users: [String]
        public let hasNext: Bool
        public let remainingMilliseconds: Int64
    }
    public struct Failure: Error, Sendable { public let code: String }

    private static let owners = V2Lock(initialState: Set<String>())
    private let runtime: SharedRuntime

    package init(accountURL: String, gatewayHost: String, gatewayPort: UInt16,
                 storage: URL, platform: SharedPlatform) throws {
        do {
            runtime = try SharedRuntime(.init(accountURL: accountURL, gatewayHost: gatewayHost,
                gatewayPort: gatewayPort, storageDirectory: storage.path), platform: platform)
        } catch { throw Failure(code: sharedFailure(error).rawValue) }
        guard Self.owners.withLock({ $0.insert(runtime.ownershipKey).inserted }) else { throw Failure(code: "busy") }
    }

    private func run(_ request: SharedRequest) async throws -> SharedSnapshot {
        do { return try await runtime.execute(request) }
        catch { throw Failure(code: sharedFailure(error).rawValue) }
    }
    private func session(_ request: SharedRequest) async throws -> Session {
        let value = try await run(request)
        return Session(state: value.state, userID: value.userID)
    }
    public func restore() async throws -> Session { try await session(.init(operation: .restore)) }
    public func signIn(account: String, password: String) async throws -> Session {
        try await session(.init(operation: .login, account: account, password: password))
    }
    public func register(account: String, password: String, publicHandle: String, displayName: String) async throws -> Session {
        try await session(.init(operation: .register, displayName: displayName, account: account,
                                password: password, publicHandle: publicHandle))
    }
    public func deviceSessions(cursor: String?) async throws -> DeviceSessions {
        let value = try await run(.init(operation: .deviceSessions, intentID: cursor))
        guard let page = value.deviceSessions else { throw Failure(code: "operationFailed") }
        return DeviceSessions(sessions: page.sessions.map {
            DeviceSession(deviceID: $0.deviceID, deviceName: $0.deviceName, platform: $0.platform,
                          createdAt: $0.createdAt, lastActiveAt: $0.lastActiveAt, isCurrentDevice: $0.isCurrentDevice)
        }, nextCursor: page.nextCursor)
    }
    public func revokeDevice(deviceID: String?, all: Bool) async throws {
        _ = try await run(.init(operation: .revokeDevice, targetUserID: deviceID, action: all ? "all" : "device"))
    }
    public func passwordLifecycle(account: String, action: String, currentPassword: String?,
                                  newPassword: String?, recoveryCode: String?) async throws {
        _ = try await run(.init(operation: .passwordLifecycle, account: account, password: currentPassword,
                                newPassword: newPassword, recoveryCode: recoveryCode, action: action))
    }
    public func connect() async throws -> Session { try await session(.init(operation: .connect)) }
    public func status() async throws -> Session { try await session(.init(operation: .snapshot)) }
    public func disconnect() async throws { _ = try await run(.init(operation: .disconnect)) }
    public func signOut() async throws { _ = try await run(.init(operation: .signOut)) }

    public func openWindow(roomID: String?, archived: Bool? = nil) async throws -> String {
        if let roomID { _ = try await run(.init(operation: .openConversation, roomID: roomID)) }
        let value = try await run(.init(operation: roomID == nil ? .openListWindow : .openTimelineWindow,
                                        archived: roomID == nil ? archived : nil, roomID: roomID))
        guard let id = value.windowID else { throw Failure(code: "operationFailed") }
        return id
    }
    public func setConversationState(roomID: String, isPinned: Bool?, isArchived: Bool?, muteUntil: Int64?) async throws {
        _ = try await run(.init(operation: .conversationState, archived: isArchived,
                                isPinned: isPinned, muteUntil: muteUntil, roomID: roomID))
    }
    public func nextUpdate(windowID: String) async throws -> Window {
        try await window(from: run(.init(operation: .watchWindow, windowID: windowID)))
    }
    public func locateMessage(roomID: String, messageID: String) async throws -> Window {
        try await window(from: run(.init(operation: .locateMessage, messageID: messageID, roomID: roomID)))
    }
    private func window(from value: SharedSnapshot) -> Window {
        let messages = (value.chat?.messages ?? []).map {
            Message(id: $0.id, senderID: $0.senderID, text: $0.text, withdrawn: $0.withdrawn, hasMedia: $0.hasMedia, attachments: $0.attachments.map(Attachment.init), readByPeer: $0.readByPeer, replyToID: $0.replyToID, replyPreview: $0.replyPreview ?? ($0.replyToID == nil ? nil : "引用消息"), isForwarded: $0.forwardedFromID != nil, revision: Int64(exactly: $0.revision), mutableRevision: $0.canMutate ? Int64(exactly: $0.revision) : nil, preparedAttachments: nil, totalAttachments: nil, pendingStatus: nil, createdAt: $0.createdAt)
        }
        return Window(conversations: value.conversations.map { Conversation(id: $0.id, title: $0.title, preview: $0.preview, unread: $0.unread, updatedAt: $0.updatedAt, isGroup: $0.isGroup, peerID: $0.peerID, isPinned: $0.isPinned, isArchived: $0.isArchived, muteUntil: $0.muteUntil) },
                      messages: messages + (value.chat?.pending ?? []).map {
                          Message(id: $0.id, senderID: value.userID ?? "", text: $0.text, withdrawn: false, hasMedia: false, attachments: [], readByPeer: false, replyToID: nil, replyPreview: nil, isForwarded: false, revision: nil, mutableRevision: nil, preparedAttachments: $0.preparedAttachments, totalAttachments: $0.totalAttachments, pendingStatus: $0.preparationStatus ?? $0.status, createdAt: $0.createdAt)
                      }, hasOlder: value.chat?.hasOlder ?? false, isLatest: value.chat?.isLatest ?? true)
    }
    public struct DirectoryEntry: Sendable {
        public let id: String
        public let title: String
        public let isGroup: Bool
    }

    public struct SearchHit: Sendable { public let id: String; public let roomID: String; public let text: String }
    public struct SearchPage: Sendable { public let status: String; public let hits: [SearchHit]; public let hasNext: Bool }
    public func searchMessages(roomID: String?, query: String, next: Bool) async throws -> SearchPage {
        let result = try await run(.init(operation: .searchMessages, roomID: roomID, text: query, action: next ? "next" : nil))
        guard let page = result.messaging?.search, page.roomID == roomID, page.query == query else { throw Failure(code: "invalidInput") }
        return .init(status: page.status, hits: page.hits.map { .init(id: $0.id, roomID: $0.roomID, text: $0.text) }, hasNext: page.hasNext)
    }
    public func clearMessageSearch() async throws { _ = try await run(.init(operation: .clearMessaging)) }
    public func messageReaders(roomID: String, messageID: String, next: Bool) async throws -> Readers {
        let value = try await run(.init(operation: .messageReaders, messageID: messageID,
                                        roomID: roomID, action: next ? "next" : "first"))
        guard let readers = value.messaging?.readers, readers.roomID == roomID, readers.messageID == messageID else {
            throw Failure(code: "operationFailed")
        }
        return Readers(roomID: readers.roomID, messageID: readers.messageID, users: readers.users,
                       hasNext: readers.hasNext, remainingMilliseconds: readers.remainingMilliseconds)
    }

    public func directory() async throws -> [DirectoryEntry] {
        try await directoryPage(nextGroups: nil).entries
    }
    public struct DirectoryPage: Sendable {
        public let entries: [DirectoryEntry]
        public let moreContacts: Bool
        public let moreGroups: Bool
    }
    public func directoryPage(nextGroups: Bool?, scope: String = "accepted") async throws -> DirectoryPage {
        let result: SharedSnapshot
        if let nextGroups {
            result = try await run(.init(operation: nextGroups ? .groupsNext : .contactsNext))
        } else {
            _ = try await run(.init(operation: .contacts, scope: scope))
            result = try await run(.init(operation: .groupsFirst))
        }
        guard let directory = result.directory else { throw Failure(code: "authenticationRequired") }
        let entries = directory.contacts.map { DirectoryEntry(id: $0.userID, title: $0.userID, isGroup: false) }
            + directory.groups.map { DirectoryEntry(id: $0.id, title: $0.title, isGroup: true) }
        return DirectoryPage(entries: entries, moreContacts: directory.hasMoreContacts, moreGroups: directory.hasMoreGroups)
    }
    public func resolveUserID(handle: String) async throws -> String {
        let result = try await run(.init(operation: .lookupIdentity, text: handle))
        guard let identity = result.directory?.identity else { throw Failure(code: "identityUnavailable") }
        return identity.userID
    }
    public func requestContact(handle: String) async throws {
        let userID = try await resolveUserID(handle: handle)
        try await socialAction(userID: userID, action: "request")
    }
    public func avatar(page: String, userID: String, context: String, roomID: String?) async throws -> AvatarImage? {
        let value = try await run(.init(operation: .avatar, roomID: roomID, scope: context, page: page, targetUserID: userID))
        guard let profile = value.directory?.profiles.first(where: { $0.page == page && $0.userID == userID }),
              let encoded = profile.avatar, let data = Data(base64Encoded: encoded) else { return nil }
        return AvatarImage(data: data, remainingMilliseconds: profile.remainingMilliseconds)
    }
    public func openAvatarEditor(roomID: String?) async throws -> AvatarEditor? {
        let value = try await run(.init(operation: .openAvatarEditor, roomID: roomID))
        guard let editor = value.directory?.avatarEditor else { return nil }
        return AvatarEditor(roomID: editor.roomID, revision: editor.revision, canManage: editor.canManage,
            remainingMilliseconds: editor.remainingMilliseconds, hasAvatar: editor.hasAvatar,
            name: editor.name, handle: editor.handle,
            image: editor.image.flatMap { Data(base64Encoded: $0) })
    }
    public func changeAvatar(roomID: String?, revision: UInt64, jpeg: Data?, width: Int?, height: Int?,
                             displayName: String?, action: String?) async throws {
        _ = try await run(.init(operation: .changeAvatar, image: jpeg?.base64EncodedString(),
            width: width, height: height, roomID: roomID, text: displayName, action: action, revision: revision))
    }
    public func profiles(page: String, context: String, roomID: String?, userIDs: [String]) async throws -> [Profile] {
        let value = try await run(.init(operation: .profiles, roomID: roomID, scope: context, page: page, members: userIDs))
        return profileList(value, page: page)
    }
    public func openProfile(userID: String, context: String = "relationship", roomID: String? = nil) async throws -> [Profile] {
        let value = try await run(.init(operation: .openProfile, roomID: roomID, scope: context, targetUserID: userID))
        return profileList(value, page: "selected")
    }
    public func saveAlias(userID: String, text: String?, revision: UInt64?) async throws {
        _ = try await run(.init(operation: .saveAlias, text: text, targetUserID: userID, revision: revision))
    }
    public func clearProfiles(page: String) async throws {
        _ = try await run(.init(operation: .clearProfiles, page: page))
    }
    private func profileList(_ value: SharedSnapshot, page: String) -> [Profile] {
        (value.directory?.profiles ?? []).filter { $0.page == page }.map {
            Profile(page: $0.page, userID: $0.userID, name: $0.name, handle: $0.handle, alias: $0.alias,
                    aliasRevision: $0.aliasRevision, groupNickname: $0.groupNickname,
                    groupNicknameRevision: $0.groupNicknameRevision,
                    remainingMilliseconds: $0.remainingMilliseconds,
                    avatar: $0.avatar.flatMap { Data(base64Encoded: $0) })
        }
    }
    public struct Invite: Sendable {
        public let id: String
        public let url: String
        public let expires: Int64
        public let used: Int
        public let maximum: Int
    }
    public struct JoinRequest: Sendable {
        public let id: String
        public let userID: String
        public let note: String
        public let state: String
    }
    public struct InvitePreview: Sendable {
        public let roomID: String
        public let title: String
        public let requestID: String?
        public let state: String?
        public let member: Bool
        public let canSubmit: Bool
        public let canCancel: Bool
    }
    public struct Community: Sendable {
        public let roomID: String?
        public let invites: [Invite]
        public let requests: [JoinRequest]
        public let hasMore: Bool
        public let preview: InvitePreview?
        public let failure: String?
    }
    public func invitations(roomID: String) async throws -> Community {
        try await community(try await run(.init(operation: .invitations, roomID: roomID)))
    }
    public func nextInvitations(roomID: String) async throws -> Community {
        try await community(try await run(.init(operation: .invitationsNext, roomID: roomID)))
    }
    public func previewInvite(text: String) async throws -> Community {
        try await community(try await run(.init(operation: .previewInvite, text: text)))
    }
    public func refreshInvite() async throws -> Community {
        try await community(try await run(.init(operation: .refreshInvite)))
    }
    public func inviteAction(roomID: String, revision: UInt64, action: String, intentID: String?, note: String?) async throws {
        _ = try await run(.init(operation: .inviteAction, roomID: roomID, text: note, intentID: intentID,
                                action: action, revision: revision))
    }
    public func submitJoin(note: String) async throws {
        _ = try await run(.init(operation: .inviteAction, text: note, action: "submit"))
    }
    public func cancelJoin(roomID: String) async throws {
        _ = try await run(.init(operation: .inviteAction, roomID: roomID, action: "cancel"))
    }
    public func muteMember(roomID: String, userID: String, revision: UInt64) async throws {
        _ = try await run(.init(operation: .muteMember, roomID: roomID, targetUserID: userID, revision: revision))
    }
    private func community(_ value: SharedSnapshot) throws -> Community {
        guard let community = value.directory?.community else { throw Failure(code: "authenticationRequired") }
        return Community(roomID: community.roomID,
            invites: community.invites.map { Invite(id: $0.id, url: $0.url, expires: $0.expires, used: $0.used, maximum: $0.maximum) },
            requests: community.requests.map { JoinRequest(id: $0.id, userID: $0.userID, note: $0.note, state: $0.state) },
            hasMore: community.hasMore,
            preview: community.preview.map { InvitePreview(roomID: $0.roomID, title: $0.title, requestID: $0.requestID,
                state: $0.state, member: $0.member, canSubmit: $0.canSubmit, canCancel: $0.canCancel) },
            failure: community.failure)
    }
    public struct DeviceSession: Sendable {
        public let deviceID: String
        public let deviceName: String
        public let platform: String
        public let createdAt: Int64
        public let lastActiveAt: Int64
        public let isCurrentDevice: Bool
    }
    public struct DeviceSessions: Sendable {
        public let sessions: [DeviceSession]
        public let nextCursor: String?
    }
    public struct GroupNickname: Sendable {
        public let roomID: String
        public let name: String?
        public let revision: UInt64?
    }
    public struct GroupPolicy: Sendable {
        public let role: String
        public let permissions: [String]
        public let revision: UInt64
    }
    public struct GroupPage: Sendable {
        public let announcement: String
        public let editableAnnouncementRevision: Int64?
        public let membershipRevision: Int64
        public let actorRole: String
        public let permissions: [String]
        public let members: [(userID: String, role: String)]
        public let policies: [GroupPolicy]
        public let policiesReady: Bool
        public let hasMore: Bool
    }
    public func changeMembership(roomID: String, revision: UInt64, action: String, target: String?, role: String?) async throws {
        _ = try await run(.init(operation: .groupAction, roomID: roomID, targetUserID: target, action: action, revision: revision, role: role))
    }
    public func updateAnnouncement(roomID: String, revision: UInt64, text: String) async throws {
        _ = try await run(.init(operation: .groupAction, roomID: roomID, text: text, action: "announcement", revision: revision))
    }
    public func groupMembers(roomID: String, next: Bool) async throws -> GroupPage {
        let result = try await run(.init(operation: next ? .groupMembersNext : .openGroup, roomID: roomID))
        guard let group = result.directory?.group, group.roomID == roomID else { throw Failure(code: "operationFailed") }
        guard let revision = Int64(exactly: group.revision) else { throw Failure(code: "operationFailed") }
        return GroupPage(announcement: group.announcement, editableAnnouncementRevision: group.permissions.contains("manage_announcements") ? Int64(exactly: group.announcementRevision) : nil, membershipRevision: revision, actorRole: group.actorRole, permissions: group.permissions, members: group.members.map { ($0.userID, $0.role) }, policies: group.policies.map { GroupPolicy(role: $0.role, permissions: $0.permissions, revision: $0.revision) }, policiesReady: group.policiesReady, hasMore: group.hasMore)
    }
    public func groupNickname(roomID: String) async throws -> GroupNickname? {
        let value = try await run(.init(operation: .groupNickname, roomID: roomID))
        guard let nickname = value.directory?.groupNickname else { return nil }
        return GroupNickname(roomID: nickname.roomID, name: nickname.name, revision: nickname.revision)
    }
    public func saveGroupNickname(roomID: String, name: String?, revision: UInt64?) async throws {
        _ = try await run(.init(operation: .saveGroupNickname, roomID: roomID, text: name, revision: revision))
    }
    public func updateGroupPermissions(roomID: String, revision: UInt64, role: String, permissions: [String]) async throws {
        _ = try await run(.init(operation: .groupAction, roomID: roomID, action: "permissions",
                                revision: revision, role: role, permissions: permissions))
    }
    public func moderateMemberRemoval(roomID: String, userID: String, revision: UInt64) async throws {
        _ = try await run(.init(operation: .moderateMemberRemoval, roomID: roomID, targetUserID: userID, revision: revision))
    }
    public func createGroup(title: String, members: [String]) async throws {
        _ = try await run(.init(operation: .createGroup, text: title, members: members))
    }
    public func socialAction(userID: String, action: String) async throws {
        _ = try await run(.init(operation: .socialAction, targetUserID: userID, action: action))
    }
    public func changeWindowPage(_ id: String, latest: Bool) async throws {
        _ = try await run(.init(operation: latest ? .resetWindow : .nextWindowPage, windowID: id))
    }
    public func closeWindow(_ id: String) async throws { _ = try await run(.init(operation: .closeWindow, windowID: id)) }
    public func cancelPendingSend(intentID: String) async throws {
        _ = try await run(.init(operation: .cancelAttachmentSend, intentID: intentID))
    }
    public func recoverSend(intentID: String, resend: Bool) async throws {
        _ = try await run(.init(operation: resend ? .resendUnsent : .retrySend, intentID: intentID))
    }
    public func sendText(roomID: String, text: String, replyToMessageID: String? = nil) async throws {
        _ = try await run(.init(operation: .openConversation, roomID: roomID))
        _ = try await run(.init(operation: .sendText, replyToMessageID: replyToMessageID, roomID: roomID, text: text))
    }
    public func sendAttachment(roomID: String, file: URL, name: String, contentType: String, text: String) async throws {
        guard file.isFileURL else { throw Failure(code: "invalidInput") }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let begin = try await run(.init(operation: .beginAttachment, displayName: name, contentType: contentType, roomID: roomID))
        do {
            guard let id = begin.resource?.importID else { throw Failure(code: "operationFailed") }
            var offset: Int64 = 0
            while let bytes = try input.read(upToCount: 65_536), !bytes.isEmpty {
                _ = try await run(.init(operation: .appendAttachment, data: bytes.base64EncodedString(), offset: offset, intentID: id))
                offset += Int64(bytes.count)
            }
            let finished = try await run(.init(operation: .finishAttachment, offset: offset, intentID: id))
            guard let assetID = finished.resource?.draft?.id else { throw Failure(code: "operationFailed") }
            _ = try await run(.init(operation: .sendAttachment, roomID: roomID, text: text, intentID: assetID))
        } catch {
            _ = try? await run(.init(operation: .clearResources))
            throw error
        }
    }
    public struct Transfer: Sendable {
        public let id: String
        public let name: String
        public let kind: String
        public let phase: String
        public let total: Int64?
        public let confirmed: Int64?
        public let actions: [String]
    }
    public func transfers() async throws -> [Transfer] {
        guard let resource = try await run(.init(operation: .snapshot)).resource else { throw Failure(code: "authenticationRequired") }
        return resource.transfers.map { Transfer(id: $0.id, name: $0.name, kind: $0.kind, phase: $0.phase, total: $0.bytes, confirmed: $0.confirmed, actions: $0.actions) }
    }
    public func transferAction(id: String, action: String) async throws {
        _ = try await run(.init(operation: .transferAction, intentID: id, action: action))
    }
    public func previewAttachment(roomID: String, messageID: String, mediaID: String) async throws -> (data: Data, remainingMilliseconds: Int64) {
        _ = try await run(.init(operation: .openResource, messageID: messageID, mediaID: mediaID, roomID: roomID))
        let result = try await run(.init(operation: .previewResource))
        guard let resource = result.resource, resource.roomID == roomID, resource.messageID == messageID,
              resource.selected?.id == mediaID, resource.remainingMilliseconds > 0,
              let encoded = resource.image, let data = Data(base64Encoded: encoded) else { throw Failure(code: "previewUnavailable") }
        return (data, resource.remainingMilliseconds)
    }
    public func exportAttachment(roomID: String, messageID: String, mediaID: String, destination: URL) async throws {
        let selected = try await run(.init(operation: .openResource, messageID: messageID, mediaID: mediaID, roomID: roomID))
        guard destination.isFileURL, let attachment = selected.resource?.selected, attachment.id == mediaID else { throw Failure(code: "invalidInput") }
        try Data().write(to: destination, options: .withoutOverwriting)
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            let begin = try await run(.init(operation: .beginResourceRead))
            guard let id = begin.resource?.readID else { throw Failure(code: "operationFailed") }
            var offset: Int64 = 0
            while true {
                try Task.checkCancellation()
                let result = try await run(.init(operation: .readResource, offset: offset, intentID: id))
                guard let encoded = result.resource?.chunk, let data = Data(base64Encoded: encoded) else { throw Failure(code: "operationFailed") }
                if data.isEmpty { break }
                offset += Int64(data.count)
                guard offset <= attachment.bytes else { throw Failure(code: "operationFailed") }
                try output.write(contentsOf: data)
            }
            guard offset == attachment.bytes else { throw Failure(code: "operationFailed") }
            try output.synchronize()
            _ = try await run(.init(operation: .endResourceRead))
        } catch {
            _ = try? await run(.init(operation: .endResourceRead))
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
    public func downloadAttachment(roomID: String, messageID: String, mediaID: String) async throws {
        _ = try await run(.init(operation: .openResource, messageID: messageID, mediaID: mediaID, roomID: roomID))
        _ = try await run(.init(operation: .downloadResource))
    }
    public func forwardMessage(roomID: String, messageID: String, revision: UInt64, targetRoomID: String) async throws {
        try await forwardMessage(roomID: roomID, messageID: messageID, revision: revision, targetRoomIDs: [targetRoomID])
    }
    public func forwardMessage(roomID: String, messageID: String, revision: UInt64, targetRoomIDs: [String]) async throws {
        _ = try await run(.init(operation: .forwardMessage, messageID: messageID, targetRoomIDs: targetRoomIDs,
                                roomID: roomID, revision: revision))
    }
    public func editMessage(roomID: String, messageID: String, revision: UInt64, text: String) async throws {
        _ = try await run(.init(operation: .messageAction, messageID: messageID, roomID: roomID,
                                text: text, action: "edit", revision: revision))
    }
    public func withdrawMessage(roomID: String, messageID: String, revision: UInt64) async throws {
        _ = try await run(.init(operation: .messageAction, messageID: messageID, roomID: roomID,
                                action: "withdraw", revision: revision))
    }
    public func close() async throws {
        _ = try await run(.init(operation: .close))
        _ = Self.owners.withLock { $0.remove(runtime.ownershipKey) }
    }
}

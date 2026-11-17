import Flutter
import IMV2SharedApple
import IMV2SharedRuntime

public final class ImFlutterSdkPlugin: NSObject, FlutterPlugin {
    private let host = MobileHost()
    public static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = ImFlutterSdkPlugin()
        registrar.publish(plugin)
        ImHostSetup.setUp(binaryMessenger: registrar.messenger(), api: plugin.host)
    }
    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        ImHostSetup.setUp(binaryMessenger: registrar.messenger(), api: nil)
        Task { try await host.close() }
    }
}

private actor MobileHost: ImHost {
    private var owner: V2MobileClient?
    private var tail: Task<Void, Never>?
    private var client: V2MobileClient {
        get throws {
            guard let owner else { throw PigeonError(code: "closed", message: nil, details: nil) }
            return owner
        }
    }
    // Serialize account mutations, allowing a window waiter to be woken by close.
    private func ordered<T>(_ action: @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task {
            await previous?.value
            do { return try await action() }
            catch let error as V2MobileClient.Failure {
                throw PigeonError(code: error.code, message: nil, details: nil)
            }
        }
        tail = Task { _ = await task.result }
        return try await task.value
    }
    func open(accountUrl: String, gatewayHost: String, gatewayPort: Int64) async throws {
        try await ordered { try await self.create(accountUrl, gatewayHost, gatewayPort) }
    }
    private func create(_ url: String, _ host: String, _ port: Int64) throws {
        guard owner == nil else { throw PigeonError(code: "busy", message: nil, details: nil) }
        guard let port = UInt16(exactly: port), port > 0 else {
            throw PigeonError(code: "invalidConfiguration", message: nil, details: nil)
        }
        owner = try .apple(accountURL: url, gatewayHost: host, gatewayPort: port)
    }
    func restore() async throws -> ImSession { try await ordered { try await self.client.restore().wire } }
    func signIn(account: String, password: String) async throws -> ImSession {
        try await ordered { try await self.client.signIn(account: account, password: password).wire }
    }
    func register(account: String, password: String, publicHandle: String, displayName: String) async throws -> ImSession {
        try await ordered { try await self.client.register(account: account, password: password,
            publicHandle: publicHandle, displayName: displayName).wire }
    }
    func privacy() async throws -> ImPrivacy? {
        try await ordered {
            guard let value = try await self.client.privacy() else { return nil }
            return ImPrivacy(allowsStrangerMessages: value.allowsStrangerMessages, allowsUserAdd: value.allowsUserAdd,
                             allowsDirectReadReceipts: value.allowsDirectReadReceipts,
                             allowsGroupReadReceipts: value.allowsGroupReadReceipts,
                             allowsOnlinePresence: value.allowsOnlinePresence,
                             allowsTypingIndicators: value.allowsTypingIndicators,
                             blockedUsers: value.blockedUsers)
        }
    }
    func setPrivacy(kind: String, flag1: Bool?, flag2: Bool?) async throws -> ImPrivacy? {
        try await ordered {
            guard let value = try await self.client.setPrivacy(kind: kind, flag1: flag1, flag2: flag2) else { return nil }
            return ImPrivacy(allowsStrangerMessages: value.allowsStrangerMessages, allowsUserAdd: value.allowsUserAdd,
                             allowsDirectReadReceipts: value.allowsDirectReadReceipts,
                             allowsGroupReadReceipts: value.allowsGroupReadReceipts,
                             allowsOnlinePresence: value.allowsOnlinePresence,
                             allowsTypingIndicators: value.allowsTypingIndicators,
                             blockedUsers: value.blockedUsers)
        }
    }
    func deviceSessions(cursor: String?) async throws -> ImDeviceSessions {
        try await ordered {
            let page = try await self.client.deviceSessions(cursor: cursor)
            return ImDeviceSessions(sessions: page.sessions.map {
                ImDeviceSession(deviceId: $0.deviceID, deviceName: $0.deviceName, platform: $0.platform,
                                createdAt: $0.createdAt, lastActiveAt: $0.lastActiveAt, isCurrentDevice: $0.isCurrentDevice)
            }, nextCursor: page.nextCursor)
        }
    }
    func revokeDevice(deviceId: String?, all: Bool) async throws {
        try await ordered { try await self.client.revokeDevice(deviceID: deviceId, all: all) }
    }
    func passwordLifecycle(account: String, action: String, currentPassword: String?, newPassword: String?, recoveryCode: String?) async throws {
        try await ordered {
            try await self.client.passwordLifecycle(account: account, action: action, currentPassword: currentPassword,
                                                    newPassword: newPassword, recoveryCode: recoveryCode)
        }
    }
    func connect() async throws -> ImSession { try await ordered { try await self.client.connect().wire } }
    func synchronize() async throws { try await ordered { try await self.client.synchronize() } }
    func status() async throws -> ImSession { try await ordered { try await self.client.status().wire } }
    func disconnect() async throws { try await ordered { try await self.client.disconnect() } }
    func openWindow(roomId: String?, archived: Bool) async throws -> String {
        try await ordered { try await self.client.openWindow(roomID: roomId, archived: archived) }
    }
    func setConversationState(roomId: String, isPinned: Bool?, isArchived: Bool?, muteUntil: Int64?) async throws {
        try await ordered {
            try await self.client.setConversationState(roomID: roomId, isPinned: isPinned,
                                                       isArchived: isArchived, muteUntil: muteUntil)
        }
    }
    func avatar(page: String, userId: String, context: String, roomId: String?) async throws -> ImAvatarImage? {
        guard let image = try await client.avatar(page: page, userID: userId, context: context, roomID: roomId) else {
            return nil
        }
        return ImAvatarImage(bytes: FlutterStandardTypedData(bytes: image.data),
                             remainingMilliseconds: image.remainingMilliseconds)
    }
    func openAvatarEditor(roomId: String?) async throws -> ImAvatarEditor? {
        try await ordered {
            guard let editor = try await self.client.openAvatarEditor(roomID: roomId) else { return nil }
            return ImAvatarEditor(roomId: editor.roomID, revision: Int64(clamping: editor.revision),
                                  canManage: editor.canManage, remainingMilliseconds: editor.remainingMilliseconds,
                                  hasAvatar: editor.hasAvatar, name: editor.name, handle: editor.handle,
                                  image: editor.image.map { FlutterStandardTypedData(bytes: $0) })
        }
    }
    func changeAvatar(roomId: String?, revision: Int64, jpeg: FlutterStandardTypedData?, width: Int64?,
                      height: Int64?, displayName: String?, action: String?) async throws {
        guard let expected = UInt64(exactly: revision) else { throw PigeonError(code: "invalidInput", message: nil, details: nil) }
        try await ordered {
            try await self.client.changeAvatar(roomID: roomId, revision: expected, jpeg: jpeg?.data,
                                               width: width.map(Int.init), height: height.map(Int.init),
                                               displayName: displayName, action: action)
        }
    }
    func nextUpdate(windowId: String) async throws -> WindowView {
        do {
            let view = try await client.nextUpdate(windowID: windowId)
            return windowView(view)
        } catch let failure as V2MobileClient.Failure {
            throw PigeonError(code: failure.code, message: nil, details: nil)
        }
    }
    func locateMessage(roomId: String, messageId: String) async throws -> WindowView {
        try await ordered { self.windowView(try await self.client.locateMessage(roomID: roomId, messageID: messageId)) }
    }
    private func windowView(_ view: V2MobileClient.Window) -> WindowView {
        return WindowView(conversations: view.conversations.map { .init(id: $0.id, title: $0.title, preview: $0.preview, unread: $0.unread, isGroup: $0.isGroup, isPinned: $0.isPinned, isArchived: $0.isArchived, updatedAt: $0.updatedAt, peerId: $0.peerID, muteUntil: $0.muteUntil) },
                              messages: view.messages.map { .init(id: $0.id, senderId: $0.senderID, text: $0.text, withdrawn: $0.withdrawn, hasMedia: $0.hasMedia, attachments: $0.attachments.map { Attachment(id: $0.id, name: $0.name, contentType: $0.contentType, bytes: $0.bytes) }, readByPeer: $0.readByPeer, isForwarded: $0.isForwarded, revision: $0.revision, mutableRevision: $0.mutableRevision, replyPreview: $0.replyPreview, pendingStatus: $0.pendingStatus, createdAt: $0.createdAt, preparedAttachments: $0.preparedAttachments, totalAttachments: $0.totalAttachments, replyToId: $0.replyToID, mentionSummary: $0.mentionSummary,
                    entities: $0.entities.map { ImEntity(kind: $0.kind, offset: Int64($0.offset), length: Int64($0.length), url: $0.url) },
                    roomSequence: $0.roomSequence, isPinned: $0.isPinned) }, hasOlder: view.hasOlder, isLatest: view.isLatest)
    }
    func directory(nextGroups: Bool?, scope: String) async throws -> DirectoryPage {
        try await ordered {
            let page = try await self.client.directoryPage(nextGroups: nextGroups, scope: scope)
            return DirectoryPage(entries: page.entries.map { DirectoryEntry(id: $0.id, title: $0.title, isGroup: $0.isGroup) },
                                 moreContacts: page.moreContacts, moreGroups: page.moreGroups)
        }
    }
    func profiles(page: String, context: String, roomId: String?, userIds: [String]) async throws -> [ImProfile] {
        try await ordered {
            try await self.client.profiles(page: page, context: context, roomID: roomId, userIDs: userIds)
                .map(Self.profile)
        }
    }
    func openProfile(userId: String, context: String, roomId: String?) async throws -> [ImProfile] {
        try await ordered {
            try await self.client.openProfile(userID: userId, context: context, roomID: roomId)
                .map(Self.profile)
        }
    }
    func saveAlias(userId: String, alias: String?, revision: Int64?) async throws {
        let expected = try revision.map { value -> UInt64 in
            guard let expected = UInt64(exactly: value) else { throw PigeonError(code: "invalidInput", message: nil, details: nil) }
            return expected
        }
        try await ordered { try await self.client.saveAlias(userID: userId, text: alias, revision: expected) }
    }
    func clearProfiles(page: String) async throws {
        try await ordered { try await self.client.clearProfiles(page: page) }
    }
    private static func profile(_ value: V2MobileClient.Profile) -> ImProfile {
        ImProfile(page: value.page, userId: value.userID, name: value.name, handle: value.handle,
                  alias: value.alias, aliasRevision: value.aliasRevision.map { Int64(clamping: $0) },
                  groupNickname: value.groupNickname,
                  groupNicknameRevision: value.groupNicknameRevision.map { Int64(clamping: $0) },
                  remainingMilliseconds: value.remainingMilliseconds,
                  avatar: value.avatar.map { FlutterStandardTypedData(bytes: $0) })
    }
    func resolveUserId(handle: String) async throws -> String {
        try await ordered { try await self.client.resolveUserID(handle: handle) }
    }
    func changeMembership(roomId: String, revision: Int64, action: String, target: String?, role: String?) async throws {
        guard let expected = UInt64(exactly: revision) else { throw PigeonError(code: "invalidInput", message: nil, details: nil) }
        try await ordered { try await self.client.changeMembership(roomID: roomId, revision: expected, action: action, target: target, role: role) }
    }
    func groupNickname(roomId: String) async throws -> ImGroupNickname? {
        try await ordered {
            guard let value = try await self.client.groupNickname(roomID: roomId) else { return nil }
            return ImGroupNickname(roomId: value.roomID, name: value.name,
                                   revision: value.revision.map { Int64(clamping: $0) })
        }
    }
    func saveGroupNickname(roomId: String, name: String?, revision: Int64?) async throws {
        let expected = try revision.map { value -> UInt64 in
            guard let expected = UInt64(exactly: value) else { throw PigeonError(code: "invalidInput", message: nil, details: nil) }
            return expected
        }
        try await ordered { try await self.client.saveGroupNickname(roomID: roomId, name: name, revision: expected) }
    }
    func updateGroupPermissions(roomId: String, revision: Int64, role: String, permissions: [String]) async throws {
        guard let expected = UInt64(exactly: revision) else { throw PigeonError(code: "invalidInput", message: nil, details: nil) }
        try await ordered { try await self.client.updateGroupPermissions(roomID: roomId, revision: expected, role: role, permissions: permissions) }
    }
    func moderateMemberRemoval(roomId: String, userId: String, revision: Int64) async throws {
        guard let expected = UInt64(exactly: revision) else { throw PigeonError(code: "invalidInput", message: nil, details: nil) }
        try await ordered { try await self.client.moderateMemberRemoval(roomID: roomId, userID: userId, revision: expected) }
    }
    func updateAnnouncement(roomId: String, revision: Int64, text: String) async throws {
        guard let expected = UInt64(exactly: revision) else { throw PigeonError(code: "invalidInput", message: nil, details: nil) }
        try await ordered { try await self.client.updateAnnouncement(roomID: roomId, revision: expected, text: text) }
    }
    func groupMembers(roomId: String, next: Bool) async throws -> GroupPage {
        try await ordered {
            let page = try await self.client.groupMembers(roomID: roomId, next: next)
            return GroupPage(announcement: page.announcement, editableAnnouncementRevision: page.editableAnnouncementRevision, membershipRevision: page.membershipRevision, actorRole: page.actorRole, permissions: page.permissions, members: page.members.map { GroupMember(userId: $0.userID, role: $0.role) }, policies: page.policies.map { ImGroupPolicy(role: $0.role, permissions: $0.permissions, revision: Int64(clamping: $0.revision)) }, policiesReady: page.policiesReady, hasMore: page.hasMore)
        }
    }
    func invitations(roomId: String) async throws -> ImCommunity {
        try await ordered { Self.community(try await self.client.invitations(roomID: roomId)) }
    }
    func nextInvitations(roomId: String) async throws -> ImCommunity {
        try await ordered { Self.community(try await self.client.nextInvitations(roomID: roomId)) }
    }
    func previewInvite(text: String) async throws -> ImCommunity {
        try await ordered { Self.community(try await self.client.previewInvite(text: text)) }
    }
    func refreshInvite() async throws -> ImCommunity {
        try await ordered { Self.community(try await self.client.refreshInvite()) }
    }
    func inviteAction(roomId: String, revision: Int64, action: String, intentId: String?, note: String?) async throws {
        guard let expected = UInt64(exactly: revision) else { throw PigeonError(code: "invalidInput", message: nil, details: nil) }
        try await ordered {
            try await self.client.inviteAction(roomID: roomId, revision: expected, action: action, intentID: intentId, note: note)
        }
    }
    func submitJoin(note: String) async throws { try await ordered { try await self.client.submitJoin(note: note) } }
    func cancelJoin(roomId: String) async throws { try await ordered { try await self.client.cancelJoin(roomID: roomId) } }
    func muteMember(roomId: String, userId: String, revision: Int64) async throws {
        guard let expected = UInt64(exactly: revision) else { throw PigeonError(code: "invalidInput", message: nil, details: nil) }
        try await ordered { try await self.client.muteMember(roomID: roomId, userID: userId, revision: expected) }
    }
    private static func community(_ value: V2MobileClient.Community) -> ImCommunity {
        ImCommunity(roomId: value.roomID,
                    invites: value.invites.map { ImInvite(id: $0.id, url: $0.url, expires: $0.expires, used: Int64($0.used), maximum: Int64($0.maximum)) },
                    requests: value.requests.map { ImJoinRequest(id: $0.id, userId: $0.userID, note: $0.note, state: $0.state) },
                    hasMore: value.hasMore,
                    preview: value.preview.map { ImInvitePreview(roomId: $0.roomID, title: $0.title, requestId: $0.requestID,
                                                                 state: $0.state, member: $0.member, canSubmit: $0.canSubmit, canCancel: $0.canCancel) },
                    failure: value.failure)
    }
    func createGroup(title: String, members: [String]) async throws {
        try await ordered { try await self.client.createGroup(title: title, members: members) }
    }
    func requestContact(handle: String) async throws {
        try await ordered { try await self.client.requestContact(handle: handle) }
    }
    func socialAction(userId: String, action: String) async throws {
        try await ordered { try await self.client.socialAction(userID: userId, action: action) }
    }
    func changeWindowPage(windowId: String, latest: Bool) async throws {
        try await ordered { try await self.client.changeWindowPage(windowId, latest: latest) }
    }
    func closeWindow(windowId: String) async throws { try await ordered { try await self.client.closeWindow(windowId) } }
    func cancelPendingSend(intentId: String) async throws {
        try await ordered { try await self.client.cancelPendingSend(intentID: intentId) }
    }
    func searchMessages(roomId: String?, query: String, next: Bool) async throws -> SearchPage {
        try await ordered {
            let page = try await self.client.searchMessages(roomID: roomId, query: query, next: next)
            return SearchPage(status: page.status, hits: page.hits.map { SearchHit(id: $0.id, roomId: $0.roomID, text: $0.text) }, hasNext: page.hasNext)
        }
    }
    func clearMessageSearch() async throws { try await ordered { try await self.client.clearMessageSearch() } }
    func favorites(next: Bool) async throws -> ImFavorites {
        try await ordered {
            let page = try await self.client.favorites(next: next)
            return ImFavorites(messages: page.messages.map {
                ImFavoriteMessage(id: $0.id, roomId: $0.roomID, roomTitle: $0.roomTitle, senderId: $0.senderID,
                                  text: $0.text, createdAt: $0.createdAt, attachmentNames: $0.attachmentNames)
            }, hasMore: page.hasMore)
        }
    }
    func moderateMessage(roomId: String, messageId: String) async throws {
        try await ordered { try await self.client.moderateMessage(roomID: roomId, messageID: messageId) }
    }
    func pinMessage(roomId: String, messageId: String, roomSequence: Int64, isPinned: Bool) async throws {
        guard let sequence = UInt64(exactly: roomSequence) else { throw PigeonError(code: "invalidInput", message: nil, details: nil) }
        try await ordered { try await self.client.pinMessage(roomID: roomId, messageID: messageId, roomSequence: sequence, isPinned: isPinned) }
    }
    func setFavorite(roomId: String, messageId: String, favorited: Bool) async throws {
        try await ordered { try await self.client.setFavorite(roomID: roomId, messageID: messageId, favorited: favorited) }
    }
    func messageReaders(roomId: String, messageId: String, next: Bool) async throws -> ImReaders {
        try await ordered {
            let value = try await self.client.messageReaders(roomID: roomId, messageID: messageId, next: next)
            return ImReaders(roomId: value.roomID, messageId: value.messageID, users: value.users,
                             hasNext: value.hasNext, remainingMilliseconds: value.remainingMilliseconds)
        }
    }
    func recoverSend(intentId: String, resend: Bool) async throws {
        try await ordered { try await self.client.recoverSend(intentID: intentId, resend: resend) }
    }
    func sendText(roomId: String, text: String, replyToMessageId: String?, mentions: [String]?) async throws {
        try await ordered { try await self.client.sendText(roomID: roomId, text: text,
            replyToMessageID: replyToMessageId, mentions: mentions ?? []) }
    }
    func sendAttachment(roomId: String, path: String, name: String, contentType: String, text: String) async throws {
        try await ordered { try await self.client.sendAttachment(roomID: roomId, file: URL(fileURLWithPath: path), name: name, contentType: contentType, text: text) }
    }
    func transfers() async throws -> [Transfer] {
        try await ordered { try await self.client.transfers().map { Transfer(id: $0.id, name: $0.name, kind: $0.kind, phase: $0.phase, total: $0.total, confirmed: $0.confirmed, actions: $0.actions) } }
    }
    func transferAction(id: String, action: String) async throws {
        try await ordered { try await self.client.transferAction(id: id, action: action) }
    }
    func previewAttachment(roomId: String, messageId: String, mediaId: String) async throws -> AttachmentPreview {
        try await ordered {
            let preview = try await self.client.previewAttachment(roomID: roomId, messageID: messageId, mediaID: mediaId)
            return AttachmentPreview(bytes: FlutterStandardTypedData(bytes: preview.data), remainingMilliseconds: preview.remainingMilliseconds)
        }
    }
    func exportAttachment(roomId: String, messageId: String, mediaId: String, destination: String) async throws {
        try await ordered { try await self.client.exportAttachment(roomID: roomId, messageID: messageId, mediaID: mediaId, destination: URL(fileURLWithPath: destination)) }
    }
    func downloadAttachment(roomId: String, messageId: String, mediaId: String) async throws {
        try await ordered { try await self.client.downloadAttachment(roomID: roomId, messageID: messageId, mediaID: mediaId) }
    }
    func forwardMessage(roomId: String, messageId: String, revision: Int64, targetRoomIds: [String]) async throws {
        guard let version = UInt64(exactly: revision) else { throw PigeonError(code: "invalidInput", message: nil, details: nil) }
        try await ordered { try await self.client.forwardMessage(roomID: roomId, messageID: messageId, revision: version, targetRoomIDs: targetRoomIds) }
    }
    func editMessage(roomId: String, messageId: String, revision: Int64, text: String) async throws {
        guard let version = UInt64(exactly: revision) else { throw PigeonError(code: "invalidInput", message: nil, details: nil) }
        try await ordered { try await self.client.editMessage(roomID: roomId, messageID: messageId, revision: version, text: text) }
    }
    func withdrawMessage(roomId: String, messageId: String, revision: Int64) async throws {
        guard let version = UInt64(exactly: revision) else { throw PigeonError(code: "invalidInput", message: nil, details: nil) }
        try await ordered { try await self.client.withdrawMessage(roomID: roomId, messageID: messageId, revision: version) }
    }
    func signOut() async throws { try await ordered { try await self.client.signOut() } }
    func close() async throws { try await ordered { try await self.releaseOwner() } }
    private func releaseOwner() async throws { try await owner?.close(); owner = nil }
}
private extension V2MobileClient.Session {
    var wire: ImSession { ImSession(state: state, userId: userID) }
}

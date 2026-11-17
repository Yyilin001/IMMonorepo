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
    func connect() async throws -> ImSession { try await ordered { try await self.client.connect().wire } }
    func status() async throws -> ImSession { try await ordered { try await self.client.status().wire } }
    func disconnect() async throws { try await ordered { try await self.client.disconnect() } }
    func openWindow(roomId: String?) async throws -> String {
        try await ordered { try await self.client.openWindow(roomID: roomId) }
    }
    func nextUpdate(windowId: String) async throws -> WindowView {
        do {
            let view = try await client.nextUpdate(windowID: windowId)
            return WindowView(conversations: view.conversations.map { .init(id: $0.id, title: $0.title, preview: $0.preview, unread: $0.unread, isGroup: $0.isGroup, updatedAt: $0.updatedAt, peerId: $0.peerID) },
                              messages: view.messages.map { .init(id: $0.id, senderId: $0.senderID, text: $0.text, withdrawn: $0.withdrawn, hasMedia: $0.hasMedia, attachments: $0.attachments.map { Attachment(id: $0.id, name: $0.name, contentType: $0.contentType, bytes: $0.bytes) }, readByPeer: $0.readByPeer, isForwarded: $0.isForwarded, revision: $0.revision, mutableRevision: $0.mutableRevision, replyPreview: $0.replyPreview, pendingStatus: $0.pendingStatus, createdAt: $0.createdAt) }, hasOlder: view.hasOlder, isLatest: view.isLatest)
        } catch let failure as V2MobileClient.Failure {
            throw PigeonError(code: failure.code, message: nil, details: nil)
        }
    }
    func directory(nextGroups: Bool?, scope: String) async throws -> DirectoryPage {
        try await ordered {
            let page = try await self.client.directoryPage(nextGroups: nextGroups, scope: scope)
            return DirectoryPage(entries: page.entries.map { DirectoryEntry(id: $0.id, title: $0.title, isGroup: $0.isGroup) },
                                 moreContacts: page.moreContacts, moreGroups: page.moreGroups)
        }
    }
    func resolveUserId(handle: String) async throws -> String {
        try await ordered { try await self.client.resolveUserID(handle: handle) }
    }
    func changeMembership(roomId: String, revision: Int64, action: String, target: String?, role: String?) async throws {
        guard let expected = UInt64(exactly: revision) else { throw PigeonError(code: "invalidInput", message: nil, details: nil) }
        try await ordered { try await self.client.changeMembership(roomID: roomId, revision: expected, action: action, target: target, role: role) }
    }
    func updateAnnouncement(roomId: String, revision: Int64, text: String) async throws {
        guard let expected = UInt64(exactly: revision) else { throw PigeonError(code: "invalidInput", message: nil, details: nil) }
        try await ordered { try await self.client.updateAnnouncement(roomID: roomId, revision: expected, text: text) }
    }
    func groupMembers(roomId: String, next: Bool) async throws -> GroupPage {
        try await ordered {
            let page = try await self.client.groupMembers(roomID: roomId, next: next)
            return GroupPage(announcement: page.announcement, editableAnnouncementRevision: page.editableAnnouncementRevision, membershipRevision: page.membershipRevision, actorRole: page.actorRole, permissions: page.permissions, members: page.members.map { GroupMember(userId: $0.userID, role: $0.role) }, hasMore: page.hasMore)
        }
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
    func recoverSend(intentId: String, resend: Bool) async throws {
        try await ordered { try await self.client.recoverSend(intentID: intentId, resend: resend) }
    }
    func sendText(roomId: String, text: String, replyToMessageId: String?) async throws { try await ordered { try await self.client.sendText(roomID: roomId, text: text, replyToMessageID: replyToMessageId) } }
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

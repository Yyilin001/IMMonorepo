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
        public let replyPreview: String?
        public let isForwarded: Bool
        public let revision: Int64?
        public let mutableRevision: Int64?
        public let pendingStatus: String?
        public let createdAt: Int64?
    }
    public struct Window: Sendable {
        public let conversations: [Conversation]
        public let messages: [Message]
        public let hasOlder: Bool
        public let isLatest: Bool
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
    public func connect() async throws -> Session { try await session(.init(operation: .connect)) }
    public func status() async throws -> Session { try await session(.init(operation: .snapshot)) }
    public func disconnect() async throws { _ = try await run(.init(operation: .disconnect)) }
    public func signOut() async throws { _ = try await run(.init(operation: .signOut)) }

    public func openWindow(roomID: String?) async throws -> String {
        if let roomID { _ = try await run(.init(operation: .openConversation, roomID: roomID)) }
        let value = try await run(.init(operation: roomID == nil ? .openListWindow : .openTimelineWindow, roomID: roomID))
        guard let id = value.windowID else { throw Failure(code: "operationFailed") }
        return id
    }
    public func nextUpdate(windowID: String) async throws -> Window {
        let value = try await run(.init(operation: .watchWindow, windowID: windowID))
        let messages = (value.chat?.messages ?? []).map {
            Message(id: $0.id, senderID: $0.senderID, text: $0.text, withdrawn: $0.withdrawn, hasMedia: $0.hasMedia, attachments: $0.attachments.map(Attachment.init), readByPeer: $0.readByPeer, replyPreview: $0.replyPreview ?? ($0.replyToID == nil ? nil : "引用消息"), isForwarded: $0.forwardedFromID != nil, revision: Int64(exactly: $0.revision), mutableRevision: $0.canMutate ? Int64(exactly: $0.revision) : nil, pendingStatus: nil, createdAt: $0.createdAt)
        }
        return Window(conversations: value.conversations.map { Conversation(id: $0.id, title: $0.title, preview: $0.preview, unread: $0.unread, updatedAt: $0.updatedAt, isGroup: $0.isGroup, peerID: $0.peerID) },
                      messages: messages + (value.chat?.pending ?? []).map {
                          Message(id: $0.id, senderID: value.userID ?? "", text: $0.text, withdrawn: false, hasMedia: false, attachments: [], readByPeer: false, replyPreview: nil, isForwarded: false, revision: nil, mutableRevision: nil, pendingStatus: $0.status, createdAt: nil)
                      }, hasOlder: value.chat?.hasOlder ?? false, isLatest: value.chat?.isLatest ?? true)
    }
    public struct DirectoryEntry: Sendable {
        public let id: String
        public let title: String
        public let isGroup: Bool
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
    public struct GroupPage: Sendable {
        public let announcement: String
        public let editableAnnouncementRevision: Int64?
        public let membershipRevision: Int64
        public let actorRole: String
        public let permissions: [String]
        public let members: [(userID: String, role: String)]
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
        return GroupPage(announcement: group.announcement, editableAnnouncementRevision: group.permissions.contains("manage_announcements") ? Int64(exactly: group.announcementRevision) : nil, membershipRevision: revision, actorRole: group.actorRole, permissions: group.permissions, members: group.members.map { ($0.userID, $0.role) }, hasMore: group.hasMore)
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

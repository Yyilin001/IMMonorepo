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
    public struct Message: Sendable {
        public let id: String
        public let senderID: String
        public let text: String
        public let withdrawn: Bool
        public let hasMedia: Bool
        public let readByPeer: Bool
        public let replyPreview: String?
        public let isForwarded: Bool
        public let pendingStatus: String?
        public let createdAt: Int64?
    }
    public struct Window: Sendable {
        public let conversations: [Conversation]
        public let messages: [Message]
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
            Message(id: $0.id, senderID: $0.senderID, text: $0.text, withdrawn: $0.withdrawn, hasMedia: $0.hasMedia, readByPeer: $0.readByPeer, replyPreview: $0.replyPreview ?? ($0.replyToID == nil ? nil : "引用消息"), isForwarded: $0.forwardedFromID != nil, pendingStatus: nil, createdAt: $0.createdAt)
        }
        return Window(conversations: value.conversations.map { Conversation(id: $0.id, title: $0.title, preview: $0.preview, unread: $0.unread, updatedAt: $0.updatedAt, isGroup: $0.isGroup, peerID: $0.peerID) },
                      messages: messages + (value.chat?.pending ?? []).map {
                          Message(id: $0.id, senderID: value.userID ?? "", text: $0.text, withdrawn: false, hasMedia: false, readByPeer: false, replyPreview: nil, isForwarded: false, pendingStatus: $0.status, createdAt: nil)
                      })
    }
    public struct DirectoryEntry: Sendable {
        public let id: String
        public let title: String
        public let isGroup: Bool
    }

    public func directory() async throws -> [DirectoryEntry] {
        let result = try await run(.init(operation: .contacts, scope: "accepted"))
        guard let directory = result.directory else { throw Failure(code: "authenticationRequired") }
        return directory.contacts.map { DirectoryEntry(id: $0.userID, title: $0.userID, isGroup: false) }
            + directory.groups.map { DirectoryEntry(id: $0.id, title: $0.title, isGroup: true) }
    }
    public func closeWindow(_ id: String) async throws { _ = try await run(.init(operation: .closeWindow, windowID: id)) }
    public func sendText(roomID: String, text: String, replyToMessageID: String? = nil) async throws {
        _ = try await run(.init(operation: .openConversation, roomID: roomID))
        _ = try await run(.init(operation: .sendText, replyToMessageID: replyToMessageID, roomID: roomID, text: text))
    }
    public func close() async throws {
        _ = try await run(.init(operation: .close))
        _ = Self.owners.withLock { $0.remove(runtime.ownershipKey) }
    }
}

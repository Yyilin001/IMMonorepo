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
                              messages: view.messages.map { .init(id: $0.id, senderId: $0.senderID, text: $0.text, withdrawn: $0.withdrawn, hasMedia: $0.hasMedia, readByPeer: $0.readByPeer, isForwarded: $0.isForwarded, replyPreview: $0.replyPreview, pendingStatus: $0.pendingStatus, createdAt: $0.createdAt) })
        } catch let failure as V2MobileClient.Failure {
            throw PigeonError(code: failure.code, message: nil, details: nil)
        }
    }
    func directory() async throws -> [DirectoryEntry] {
        try await ordered { try await self.client.directory().map { DirectoryEntry(id: $0.id, title: $0.title, isGroup: $0.isGroup) } }
    }
    func closeWindow(windowId: String) async throws { try await ordered { try await self.client.closeWindow(windowId) } }
    func sendText(roomId: String, text: String, replyToMessageId: String?) async throws { try await ordered { try await self.client.sendText(roomID: roomId, text: text, replyToMessageID: replyToMessageId) } }
    func signOut() async throws { try await ordered { try await self.client.signOut() } }
    func close() async throws { try await ordered { try await self.releaseOwner() } }
    private func releaseOwner() async throws { try await owner?.close(); owner = nil }
}
private extension V2MobileClient.Session {
    var wire: ImSession { ImSession(state: state, userId: userID) }
}

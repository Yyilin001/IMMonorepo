import Foundation
import IMV2Core
@testable import IMV2ClientKit
@testable import IMApp
import Testing

@MainActor @Suite("Local-first startup and background authentication", .serialized)
struct V2OfflineStartupTests {
    @Test("expired credentials show the normal local inbox before refresh completes")
    func unavailableNetworkRetainsLocalContent() async throws {
        let f = try await OfflineAppFixture.make()
        defer { f.removeFiles() }
        let restoring = Task { await f.app.restore() }
        try await waitUntil { f.app.conversationStore != nil }
        #expect(f.app.route == .signedIn(userID: f.credentials.userID.rawValue))
        #expect(f.app.offlinePresentation == nil)
        let conversations = try #require(f.app.conversationStore)
        #expect(conversations.items.map(\.id) == [f.room.rawValue])
        await f.refresh.waitForStart()
        await f.refresh.fail()
        await restoring.value
        #expect(f.app.route == .signedIn(userID: f.credentials.userID.rawValue))
        #expect(f.app.conversationStore === conversations)
        #expect(conversations.items.map(\.id) == [f.room.rawValue])
        await f.app.signOut()
    }

    @Test("local journal activation does not request fresh tokens")
    func localBootstrapDoesNotWaitForNetwork() async throws {
        let f = try await OfflineAppFixture.make()
        defer { f.removeFiles() }
        let local = try await f.bootstrap.openLocallyEstablishedSession(isLocalExitPending: { try await f.marker.isPending() })
        #expect(await f.refresh.calls == 0)
        #expect(local.identity.userID == f.credentials.userID)
        let intent = try V2SendIntent(id: UUID(), roomID: f.room, clientMessageID: .init(uuid: UUID()),
            text: "offline send", attachmentJobIDs: [])
        try await local.store.freezeSendIntent(intent)
        #expect(try await local.store.preparingSendIntents().map(\.id) == [intent.id])
        try await f.bootstrap.closeLocalStore(local.store)
    }

    @Test("pending exit, locked credentials and invalid installation still block local startup", arguments: ["exit", "credentials-locked", "binding-locked", "binding-mismatch"])
    func trustFailures(scenario: String) async throws {
        let f = try await OfflineAppFixture.make()
        defer { f.removeFiles() }
        let bytes = try Data(contentsOf: f.database)
        if scenario == "exit" { try await f.marker.markPending() }
        if scenario == "credentials-locked" { await f.store.setUnavailable(true) }
        if scenario == "binding-locked" { await f.binding.setUnavailable(true) }
        if scenario == "binding-mismatch" { await f.binding.replace(.init(value: UUID())) }
        await f.app.restore()
        #expect(f.app.accountAccessMode == .blocked && f.app.conversationStore == nil)
        #expect(await f.refresh.calls == 0)
        if scenario.contains("locked") { #expect(f.app.route == .protectedDataUnavailable) }
        if scenario == "binding-mismatch" { #expect(try Data(contentsOf: f.database) == bytes) }
    }

    @Test("background refresh keeps the same local navigation dependencies")
    func backgroundRefreshDoesNotReplaceLocalState() async throws {
        let f = try await OfflineAppFixture.make()
        defer { f.removeFiles() }
        let restoring = Task { await f.app.restore() }
        try await waitUntil { f.app.conversationStore != nil }
        let conversations = try #require(f.app.conversationStore)
        await f.refresh.waitForStart()
        await f.app.applicationDidEnterBackground()
        await f.refresh.succeed(f.successor)
        await restoring.value
        #expect(f.app.route == .signedIn(userID: f.credentials.userID.rawValue))
        #expect(f.app.conversationStore === conversations)
        await f.app.signOut()
    }

    @Test("sign-out withdraws local state even when its initiating task is cancelled")
    func userExitOutlivesItsViewTask() async throws {
        let f = try await OfflineAppFixture.make()
        defer { f.removeFiles() }
        let restoring = Task { await f.app.restore() }
        try await waitUntil { f.app.conversationStore != nil }
        await f.refresh.waitForStart()
        await f.refresh.fail()
        await restoring.value
        let task = Task { f.app.requestSignOut(); f.app.requestSignOut() }
        task.cancel()
        await task.value
        try await waitUntil { f.app.route == .signedOut }
        #expect(f.app.conversationStore == nil && f.app.accountAccessMode == .blocked)
        #expect(try await f.store.load() == nil)
    }

    @Test("replacement account fences the old local-first runtime")
    func replacementCannotRetainOldAccount() async throws {
        let f = try await OfflineAppFixture.make()
        defer { f.removeFiles() }
        let restoring = Task { await f.app.restore() }
        try await waitUntil { f.app.conversationStore != nil }
        await f.refresh.waitForStart()
        let replacement = try OfflineAppFixture.credentials(userID: .init(UUID().uuidString), deviceID: .init(UUID().uuidString), expires: .distantFuture)
        try await f.auth.establish(replacement)
        await f.refresh.succeed(f.successor)
        await restoring.value
        try await waitUntil { f.app.accountAccessMode == .blocked }
        #expect(f.app.conversationStore == nil)
    }

    @Test("a locally denied room is not restored by cached messages")
    func deniedRoomCannotDisplayHistory() async throws {
        let f = try await OfflineAppFixture.make(denyRoom: true)
        defer { f.removeFiles() }
        let restoring = Task { await f.app.restore() }
        try await waitUntil { f.app.conversationStore != nil }
        #expect(f.app.conversationStore?.items.isEmpty == true)
        await f.refresh.waitForStart()
        await f.refresh.fail()
        await restoring.value
        await f.app.signOut()
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !predicate() { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(5)) }
    }
}

@MainActor private struct OfflineAppFixture {
    let root: URL
    let database: URL
    let room: RoomID
    let credentials: V2AuthCredentials
    let successor: V2AuthCredentials
    let store: OfflineAppCredentialStore
    let binding: OfflineAppBindingStore
    let marker: OfflineAppExitMarker
    let refresh: OfflineAppRefresh
    let auth: V2AuthSession
    let bootstrap: V2ClientSessionBootstrapper
    let app: V2AppStore
    static func credentials(userID: UserID, deviceID: DeviceID, expires: Date) throws -> V2AuthCredentials {
        try .init(userID: userID, deviceID: deviceID, accessToken: "synthetic-access", accessTokenExpiresAt: expires,
            refreshCredential: "synthetic-refresh", revocationCredential: .generate(), revocationCredentialExpiresAt: .distantFuture)
    }
    static func make(failClose: Bool = false, denyRoom: Bool = false) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appending(path: "offline-app-" + UUID().uuidString)
        let url = root.appending(path: "V2.sqlite")
        let user = try UserID(UUID().uuidString), device = try DeviceID(UUID().uuidString), room = try RoomID(UUID().uuidString)
        let valid = try credentials(userID: user, deviceID: device, expires: .distantFuture)
        let expired = try V2AuthCredentials(userID: user, deviceID: device, accessToken: valid.accessToken, accessTokenExpiresAt: .distantPast,
            refreshCredential: valid.refreshCredential, revocationCredential: valid.revocationCredential, revocationCredentialExpiresAt: valid.revocationCredentialExpiresAt)
        let store = OfflineAppCredentialStore(valid)
        let binding = OfflineAppBindingStore()
        let refresh = OfflineAppRefresh()
        let first = V2AuthSession(credentialStore: store, transport: refresh)
        let initialBootstrap = V2ClientSessionBootstrapper(authSession: first, localStoreBootstrapper: .init(bindingStore: binding), databaseURL: url, accountStorageRoot: root.appending(path: "accounts"))
        let local = try await initialBootstrap.openEstablishedSession()
        let scope = try #require(try await initialBootstrap.storageScope(for: local))
        let peer = try V2PublicIdentity(userID: .init(UUID().uuidString), handle: .init("offline_peer"), displayName: "Cached name requires lease", accountKind: .regular)
        try await local.cacheDirectRoomIdentity(roomID: room, publicIdentity: peer, roomCreatedAt: Date(timeIntervalSince1970: 1))
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init(UUID().uuidString), projectionKind: "message", payload: JSONSerialization.data(withJSONObject: [
            "event_type": "message.accepted", "message_id": UUID().uuidString, "room_id": room.rawValue, "room_sequence": 1, "message_revision": 1,
            "sender_user_id": user.rawValue, "text": "saved text", "server_created_at_ms": 1_750_000_000_000
        ]))
        _ = try await local.apply(.init(generation: 1, records: [record], nextSyncToken: .init("seed"), receipt: .init("seed-receipt"), hasMore: false, capabilityProfile: "base"))
        if denyRoom { try await local.markRoomEventUnauthorized(roomID: room) }
        try await initialBootstrap.closeLocalStore(local)
        await store.replace(expired)
        let auth = V2AuthSession(credentialStore: store, transport: refresh)
        let marker = OfflineAppExitMarker()
        let closer = OfflineAppCloseBarrier(fail: failClose)
        let bootstrap = V2ClientSessionBootstrapper(authSession: auth, localStoreBootstrapper: .init(bindingStore: binding), databaseURL: url,
            accountStorageRoot: root.appending(path: "accounts"), beforeClosingLocalStore: { _ in try await closer.check() })
        let app = V2AppStore(localRestorationDependencies: .init(configuration: try .init(), authSession: auth, bootstrapper: bootstrap,
            exitMarker: marker, databaseURL: url, serviceIdentifier: "offline-fixture-" + UUID().uuidString))
        return .init(root: root, database: scope.database.primary, room: room, credentials: expired, successor: valid,
            store: store, binding: binding, marker: marker, refresh: refresh, auth: auth, bootstrap: bootstrap, app: app)
    }
    func removeFiles() { try? FileManager.default.removeItem(at: root) }
}
private actor OfflineAppCredentialStore: V2CredentialStore {
    var record: V2AuthCredentialRecord?
    var unavailable = false
    init(_ value: V2AuthCredentials) { record = .init(credentials: value) }
    func setUnavailable(_ value: Bool) { unavailable = value }
    func replace(_ value: V2AuthCredentials) { record = .init(credentials: value) }
    func load() throws -> V2AuthCredentialRecord? { if unavailable { throw V2CredentialStoreError.unavailable }; return record }
    func save(_ value: V2AuthCredentialRecord) { record = value }
    func delete() { record = nil }
}
private actor OfflineAppBindingStore: V2InstallationBindingStore {
    var binding: V2LocalInstallationBinding?
    var unavailable = false
    func setUnavailable(_ value: Bool) { unavailable = value }
    func replace(_ value: V2LocalInstallationBinding) { binding = value }
    func load() throws -> V2LocalInstallationBinding? { if unavailable { throw V2InstallationBindingStoreError.unavailable }; return binding }
    func save(_ value: V2LocalInstallationBinding) { binding = value }
    func delete() { binding = nil }
}
private actor OfflineAppExitMarker: V2PendingCredentialDeletionStoring {
    var pending = false
    func isPending() -> Bool { pending }
    func markPending() { pending = true }
    func clearPending() { pending = false }
}
private actor OfflineAppRefresh: V2AuthTransport {
    var calls = 0
    var operationIDs: [UUID] = []
    private var continuation: CheckedContinuation<V2AuthCredentials, any Error>?
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func refresh(_ request: V2RefreshRequest) async throws -> V2AuthCredentials {
        calls += 1; operationIDs.append(request.operationID)
        let ready = startWaiters.filter { calls >= $0.0 }
        startWaiters.removeAll { calls >= $0.0 }
        for waiter in ready { waiter.1.resume() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitForStart(count: Int = 1) async { if calls < count { await withCheckedContinuation { startWaiters.append((count, $0)) } } }
    func succeed(_ value: V2AuthCredentials) { continuation?.resume(returning: value); continuation = nil }
    func fail() { continuation?.resume(throwing: URLError(.notConnectedToInternet)); continuation = nil }
}
private actor OfflineAppCloseBarrier {
    var fail: Bool
    init(fail: Bool) { self.fail = fail }
    func check() throws { if fail { fail = false; throw V2ClientSessionBootstrapError.localStoreCloseFailed } }
}

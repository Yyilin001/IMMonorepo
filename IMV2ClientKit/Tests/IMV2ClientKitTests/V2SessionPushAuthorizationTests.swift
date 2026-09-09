import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Push authentication lifetime", .timeLimit(.minutes(1)))
struct V2SessionPushAuthorizationTests {
    private let endpoint = URL(string: "https://account.example/v2/push-endpoint")!

    @Test("same-device reauthentication cannot lend credentials to an old Push client")
    func replacedBeforeRequest() async throws {
        let f = try await Fixture.make()
        let old = try client(f)
        let next = try f.successor()
        try await f.session.establish(next)
        await #expect(throws: CancellationError.self) { try await old.intentEpoch(deviceID: f.credentials.deviceID) }
        #expect(await f.wire.requests.isEmpty)
        let current = try V2HTTPPushEndpointClient(endpoint: endpoint, session: f.session, epoch: await f.session.currentEpoch(), transport: f.wire)
        #expect(try await current.intentEpoch(deviceID: next.deviceID) == 0)
        #expect(await f.wire.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer successor-access")
    }

    @Test("late success, rejection and network error all belong to the old epoch", arguments: [204, 401, 503, -1])
    func replacedDuringRequest(status: Int) async throws {
        let f = try await Fixture.make()
        await f.wire.holdNext(status: status)
        let old = try client(f)
        let sending = Task { try await old.publishIntent(deviceID: f.credentials.deviceID, version: .init(epoch: 1, revision: 1), intent: .disabled) }
        try await wait { await f.wire.waiting }
        let next = try f.successor()
        try await f.session.establish(next)
        await f.wire.release()
        await #expect(throws: CancellationError.self) { try await sending.value }
        #expect(await f.store.record?.credentials == next)
        #expect(try await f.session.accessToken() == next.accessToken)
    }

    @Test("replacement during credential refresh prevents the old HTTP request")
    func replacedDuringRefresh() async throws {
        let f = try await Fixture.make(expired: true)
        await f.refresh.holdNext()
        let old = try client(f)
        let reading = Task { try await old.intentEpoch(deviceID: f.credentials.deviceID) }
        try await wait { await f.refresh.waiting }
        let next = try f.successor()
        try await f.session.establish(next)
        await f.refresh.release()
        await #expect(throws: CancellationError.self) { try await reading.value }
        #expect(await f.wire.requests.isEmpty)
        #expect(await f.store.record?.credentials == next)
    }

    @Test("refresh in the same epoch remains usable")
    func refreshRetainsLifetime() async throws {
        let f = try await Fixture.make(expired: true)
        #expect(try await client(f).intentEpoch(deviceID: f.credentials.deviceID) == 0)
        #expect(await f.session.currentEpoch() == f.epoch)
        #expect(await f.wire.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-access")
    }

    @Test("a transport ignoring cancellation cannot report a late successful write")
    func cancellationAfterHTTP() async throws {
        let f = try await Fixture.make()
        await f.wire.holdNext(status: 204)
        let bound = try client(f)
        let sending = Task { try await bound.publishIntent(deviceID: f.credentials.deviceID, version: .init(epoch: 1, revision: 1), intent: .disabled) }
        try await wait { await f.wire.waiting }
        sending.cancel()
        await f.wire.release()
        await #expect(throws: CancellationError.self) { try await sending.value }
        #expect(await f.session.currentEpoch() == f.epoch)
        #expect(await f.store.record?.credentials == f.credentials)
    }

    @Test("logout drains the interactive owner and confirms disable with its cleanup epoch")
    func cleanupAfterInvalidation() async throws {
        let f = try await Fixture.make()
        let binding = V2LocalInstallationBinding(value: UUID())
        let directory = FileManager.default.temporaryDirectory.appending(path: "push-auth-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootstrapper = V2LocalStoreBootstrapper(bindingStore: PushAuthBinding(binding: binding))
        let local = try await bootstrapper.open(databaseURL: directory.appending(path: "local.sqlite"), userID: f.credentials.userID)
        let scope = try V2PushIntentScope(userID: f.credentials.userID, deviceID: f.credentials.deviceID, installation: binding)
        let old = try await V2PushIntentReconciler.activate(store: local, transport: client(f), scope: scope, initialPreference: true)
        try await old.receiveToken(provider: .apns, environment: .development, value: "test-apns-token")
        #expect(try await old.flushOnce() == .advanced)
        #expect(try await old.flushOnce() == .advanced)
        await f.wire.holdNext(status: 204)
        let publishing = Task { try await old.flushOnce() }
        try await wait { await f.wire.waiting }
        let before = try await old.state()
        await f.session.invalidateOutstandingWork()
        let cleanupEpoch = await f.session.currentEpoch()
        let stopping = Task { await old.stop() }
        try await wait { await f.wire.cancelled }
        await f.wire.release()
        await stopping.value
        await #expect(throws: CancellationError.self) { try await publishing.value }
        #expect(try await old.state().acknowledgedRevision == before.acknowledgedRevision)
        #expect(await f.wire.enabled)
        let current = try V2HTTPPushEndpointClient(endpoint: endpoint, session: f.session, epoch: cleanupEpoch, transport: f.wire)
        let cleanup = try await V2PushIntentReconciler.activate(store: local, transport: current, scope: scope, initialPreference: false)
        try await cleanup.prepareSignOut()
        #expect(try await cleanup.flushOnce() == .advanced)
        let final = try await cleanup.state()
        #expect(final.preferenceEnabled && !final.desiredEnabled && !final.pending)
        #expect(final.revision > before.revision && final.epoch == before.epoch)
        #expect(await f.wire.enabled == false)
        #expect(await f.wire.revision == final.revision)
        #expect(await f.store.record?.credentials == f.credentials)
        await cleanup.stop()
        try await local.close()
    }

    private func client(_ f: Fixture) throws -> V2HTTPPushEndpointClient {
        try .init(endpoint: endpoint, session: f.session, epoch: f.epoch, transport: f.wire)
    }

    private func wait(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("bounded Push request wait expired")
        throw CancellationError()
    }

    private struct Fixture {
        let credentials: V2AuthCredentials
        let session: V2AuthSession
        let epoch: V2AuthSessionEpoch
        let store: PushAuthCredentialStore
        let refresh: PushAuthRefresh
        let wire: PushAuthWire
        static func make(expired: Bool = false) async throws -> Self {
            let credentials = try V2AuthCredentials(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), accessToken: "original-access", accessTokenExpiresAt: expired ? .distantPast : .distantFuture, refreshCredential: "original-refresh")
            let refreshed = try V2AuthCredentials(userID: credentials.userID, deviceID: credentials.deviceID, accessToken: "refreshed-access", accessTokenExpiresAt: .distantFuture, refreshCredential: "refreshed-refresh")
            let store = PushAuthCredentialStore(record: .init(credentials: credentials))
            let refresh = PushAuthRefresh(credentials: refreshed)
            let session = V2AuthSession(credentialStore: store, transport: refresh)
            _ = try await session.restoreState()
            return .init(credentials: credentials, session: session, epoch: await session.currentEpoch(), store: store, refresh: refresh, wire: PushAuthWire())
        }
        func successor() throws -> V2AuthCredentials {
            try .init(userID: credentials.userID, deviceID: credentials.deviceID, accessToken: "successor-access", accessTokenExpiresAt: .distantFuture, refreshCredential: "successor-refresh")
        }
    }
}

private actor PushAuthCredentialStore: V2CredentialStore {
    var record: V2AuthCredentialRecord?
    init(record: V2AuthCredentialRecord) { self.record = record }
    func load() -> V2AuthCredentialRecord? { record }
    func save(_ record: V2AuthCredentialRecord) { self.record = record }
    func delete() { record = nil }
}

private actor PushAuthRefresh: V2AuthTransport {
    let credentials: V2AuthCredentials
    private var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    init(credentials: V2AuthCredentials) { self.credentials = credentials }
    func holdNext() { hold = true }
    func release() { continuation?.resume(); continuation = nil }
    func refresh(_: V2RefreshRequest) async -> V2AuthCredentials {
        if hold { hold = false; await withCheckedContinuation { continuation = $0 } }
        return credentials
    }
}

private actor PushAuthWire: V2ClientPushEndpointHTTPTransport {
    var requests: [URLRequest] = []
    var enabled = false
    var revision: UInt64 = 0
    var cancelled = false
    private var epoch: UInt64 = 0
    private var heldStatus: Int?
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func holdNext(status: Int) { heldStatus = status }
    func release() { continuation?.resume(); continuation = nil }
    func markCancelled() { cancelled = true }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let status = heldStatus ?? (request.httpMethod == "PUT" ? 204 : 200)
        if heldStatus != nil {
            heldStatus = nil
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation = $0 }
            } onCancel: { Task { await self.markCancelled() } }
        }
        if status == -1 { throw URLError(.networkConnectionLost) }
        if request.httpMethod == "POST" { epoch += 1 }
        if request.httpMethod == "PUT", status == 204 {
            struct Intent: Decodable { let enabled: Bool; let revision: UInt64 }
            let intent = try JSONDecoder().decode(Intent.self, from: try #require(request.httpBody))
            enabled = intent.enabled; revision = intent.revision
        }
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (Data("{\"epoch\":\(epoch)}".utf8), response)
    }
}

private actor PushAuthBinding: V2InstallationBindingStore {
    let binding: V2LocalInstallationBinding
    init(binding: V2LocalInstallationBinding) { self.binding = binding }
    func load() -> V2LocalInstallationBinding? { binding }
    func save(_: V2LocalInstallationBinding) {}
    func delete() {}
}

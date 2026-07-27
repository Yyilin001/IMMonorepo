import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 auth session")
struct V2AuthSessionTests {
    @Test("cold-start pending operation is reused and atomically cleared after success")
    func reusesPendingOperation() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let old = try credentials(expiry: now.addingTimeInterval(-1), refresh: "test-refresh-predecessor")
        let successor = try credentials(expiry: now.addingTimeInterval(60), refresh: "test-refresh-successor")
        let store = InMemoryCredentialStore(record: .init(credentials: old, pendingRefreshOperationID: operationID))
        let transport = AuthTransportStub(result: .success(successor))
        let session = V2AuthSession(credentialStore: store, transport: transport, now: { now })

        let token = try await session.accessToken()

        #expect(token == successor.accessToken)
        #expect(await transport.requests() == [.init(userID: old.userID, deviceID: old.deviceID, refreshCredential: old.refreshCredential, operationID: operationID)])
        let stored = try #require(await store.record())
        #expect(stored.credentials == successor)
        #expect(stored.pendingRefreshOperationID == nil)
    }

    @Test("concurrent callers share one durable refresh operation")
    func sharesOneRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_100)
        let old = try credentials(expiry: now.addingTimeInterval(-1), refresh: "test-refresh-predecessor")
        let successor = try credentials(expiry: now.addingTimeInterval(60), refresh: "test-refresh-successor")
        let store = InMemoryCredentialStore(record: .init(credentials: old))
        let transport = BlockingAuthTransport(response: successor)
        let session = V2AuthSession(
            credentialStore: store,
            transport: transport,
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000202")! },
            now: { now }
        )

        let first = Task { try await session.refresh() }
        await transport.waitForFirstRequest()
        let second = Task { try await session.refresh() }
        await Task.yield()
        await transport.release()
        let firstValue = try await first.value
        let secondValue = try await second.value

        #expect(firstValue == successor)
        #expect(secondValue == successor)
        #expect(await transport.requestCount() == 1)
        #expect(await store.saveCount() == 2) // pending record, then successor record
    }

    @Test("temporary Keychain unavailability pauses without sending refresh or clearing credentials")
    func temporaryCredentialStoreFailureIsNotLogout() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_200)
        let store = InMemoryCredentialStore(loadFailure: .unavailable)
        let transport = AuthTransportStub(result: .failure(V2AuthTransportError.terminalRejection))
        let session = V2AuthSession(credentialStore: store, transport: transport, now: { now })

        await #expect(throws: V2AuthSessionError.credentialsUnavailable) {
            _ = try await session.accessToken()
        }
        #expect(await session.currentState() == .credentialsUnavailable)
        #expect(await transport.requests().isEmpty)
    }

    @Test("temporary Keychain unavailability can recover after protected data returns")
    func retryingCredentialStoreAccessReloadsThePreservedSession() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_250)
        let preserved = try credentials(expiry: now.addingTimeInterval(60), refresh: "test-refresh-preserved")
        let store = InMemoryCredentialStore(
            record: .init(credentials: preserved),
            loadFailure: .unavailable
        )
        let transport = AuthTransportStub(result: .failure(V2AuthTransportError.terminalRejection))
        let session = V2AuthSession(credentialStore: store, transport: transport, now: { now })

        await #expect(throws: V2AuthSessionError.credentialsUnavailable) {
            _ = try await session.accessToken()
        }
        await store.setLoadFailure(nil)
        await session.retryCredentialStoreAccess()

        #expect(try await session.accessToken() == preserved.accessToken)
        #expect(await session.currentState() == .authenticated(accessTokenExpiresAt: preserved.accessTokenExpiresAt))
        #expect(await transport.requests().isEmpty)
    }

    @Test("terminal refresh rejection clears the device credential")
    func terminalRejectionLogsOut() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_300)
        let store = InMemoryCredentialStore(record: .init(credentials: try credentials(expiry: now.addingTimeInterval(-1), refresh: "test-refresh-predecessor")))
        let transport = AuthTransportStub(result: .failure(V2AuthTransportError.terminalRejection))
        let session = V2AuthSession(credentialStore: store, transport: transport, now: { now })

        await #expect(throws: V2AuthSessionError.unauthenticated) {
            _ = try await session.accessToken()
        }
        #expect(await store.record() == nil)
        #expect(await session.currentState() == .unauthenticated)
    }

    @Test("trusted initial credentials become the sole durable session record")
    func establishesCredentialsThroughTheSessionBoundary() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_400)
        let established = try credentials(expiry: now.addingTimeInterval(60), refresh: "initial-refresh")
        let store = InMemoryCredentialStore()
        let transport = AuthTransportStub(result: .failure(V2AuthTransportError.terminalRejection))
        let session = V2AuthSession(credentialStore: store, transport: transport, now: { now })

        try await session.establish(established)

        #expect(try await session.accessToken() == established.accessToken)
        #expect(await store.record() == .init(credentials: established))
        #expect(await session.currentState() == .authenticated(accessTokenExpiresAt: established.accessTokenExpiresAt))
        #expect(await transport.requests().isEmpty)
    }

    @Test("a stale refresh cannot restore credentials after a new session is established")
    func staleRefreshCannotOverwriteEstablishedCredentials() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_500)
        let expired = try credentials(expiry: now.addingTimeInterval(-1), refresh: "old-refresh")
        let successor = try credentials(expiry: now.addingTimeInterval(60), refresh: "old-successor")
        let established = try V2AuthCredentials(
            userID: .init("00000000-0000-0000-0000-000000000205"),
            deviceID: .init("00000000-0000-0000-0000-000000000206"),
            accessToken: "new-access-token",
            accessTokenExpiresAt: now.addingTimeInterval(120),
            refreshCredential: "new-refresh"
        )
        let store = InMemoryCredentialStore(record: .init(credentials: expired))
        let transport = BlockingAuthTransport(response: successor)
        let session = V2AuthSession(credentialStore: store, transport: transport, now: { now })

        let refresh = Task { try await session.refresh() }
        await transport.waitForFirstRequest()
        try await session.establish(established)
        await transport.release()

        await #expect(throws: V2AuthSessionError.sessionInvalidated) {
            _ = try await refresh.value
        }
        #expect(await store.record() == .init(credentials: established))
        #expect(try await session.accessToken() == established.accessToken)
    }

    private func credentials(expiry: Date, refresh: String) throws -> V2AuthCredentials {
        try .init(
            userID: .init("00000000-0000-0000-0000-000000000203"),
            deviceID: .init("00000000-0000-0000-0000-000000000204"),
            accessToken: "test-access-token",
            accessTokenExpiresAt: expiry,
            refreshCredential: refresh
        )
    }
}

private actor InMemoryCredentialStore: V2CredentialStore {
    private var value: V2AuthCredentialRecord?
    private var loadFailure: V2CredentialStoreError?
    private var writes = 0

    init(record: V2AuthCredentialRecord? = nil, loadFailure: V2CredentialStoreError? = nil) {
        value = record
        self.loadFailure = loadFailure
    }

    func load() throws -> V2AuthCredentialRecord? {
        if let loadFailure { throw loadFailure }
        return value
    }
    func save(_ record: V2AuthCredentialRecord) { value = record; writes += 1 }
    func delete() { value = nil }
    func record() -> V2AuthCredentialRecord? { value }
    func saveCount() -> Int { writes }
    func setLoadFailure(_ failure: V2CredentialStoreError?) { loadFailure = failure }
}

private actor AuthTransportStub: V2AuthTransport {
    private let result: Result<V2AuthCredentials, Error>
    private var sent: [V2RefreshRequest] = []

    init(result: Result<V2AuthCredentials, Error>) { self.result = result }
    func refresh(_ request: V2RefreshRequest) throws -> V2AuthCredentials {
        sent.append(request)
        return try result.get()
    }
    func requests() -> [V2RefreshRequest] { sent }
}

private actor BlockingAuthTransport: V2AuthTransport {
    private let response: V2AuthCredentials
    private var sent: [V2RefreshRequest] = []
    private var firstRequestWaiter: CheckedContinuation<Void, Never>?
    private var responseWaiter: CheckedContinuation<Void, Never>?

    init(response: V2AuthCredentials) { self.response = response }

    func refresh(_ request: V2RefreshRequest) async throws -> V2AuthCredentials {
        sent.append(request)
        firstRequestWaiter?.resume()
        firstRequestWaiter = nil
        await withCheckedContinuation { responseWaiter = $0 }
        return response
    }

    func waitForFirstRequest() async {
        guard sent.isEmpty else { return }
        await withCheckedContinuation { firstRequestWaiter = $0 }
    }
    func release() { responseWaiter?.resume(); responseWaiter = nil }
    func requestCount() -> Int { sent.count }
}

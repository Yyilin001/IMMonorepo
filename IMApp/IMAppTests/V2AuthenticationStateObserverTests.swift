import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
@Suite("Account scoped authentication presentation", .timeLimit(.minutes(1)))
struct V2AuthenticationStateObserverTests {
    @Test("business HTTP rejection and real refresh decoding drive authentication presentation", arguments: [401, 403, 503])
    func httpRefreshDrivesPresentation(refreshStatus: Int) async throws {
        let credentials = try makeCredentials("http")
        let store = PresentationCredentialStore(credentials)
        let refresh = try V2HTTPDeviceCredentialAuthTransport(
            refreshEndpoint: URL(string: "https://account.example.test/v2/device-credentials/refresh")!,
            transport: PresentationHTTPTransport(status: refreshStatus)
        )
        let session = V2AuthSession(credentialStore: store, transport: refresh)
        _ = try await session.restoreState()
        let epoch = await session.currentEpoch()
        let observer = V2AuthenticationStateObserver()
        defer { observer.stop() }
        var changes: [V2AuthenticationStateObserver.Change] = []
        observer.start(session: session, epoch: epoch) { changes.append($0) }
        let authorization = V2SessionHTTPAuthorization(session: session, epoch: epoch, transport: PresentationHTTPTransport(status: 401))
        let client = try V2HTTPDeviceSessionClient(endpoint: URL(string: "https://account.example.test/v2/devices")!, credentials: authorization, transport: authorization)
        _ = try? await client.list(cursor: nil, pageSize: 10)
        if refreshStatus == 503 {
            #expect(await store.exists())
            #expect(await session.currentState() == .authenticated(accessTokenExpiresAt: credentials.accessTokenExpiresAt))
            #expect(changes.isEmpty)
        } else {
            try await wait { changes == [.authenticationRequired] }
            #expect(await session.currentState() == .unauthenticated)
            #expect(!(await store.exists()))
        }
    }

    @Test("a refresh outside the realtime runtime still reports reauthentication")
    func independentRefreshEndsPresentation() async throws {
        let credentials = try makeCredentials("a")
        let auth = V2AuthSession(credentialStore: PresentationCredentialStore(credentials), transport: PresentationRefresh(rejected: true, credentials: credentials))
        _ = try await auth.restoreState()
        let observer = V2AuthenticationStateObserver()
        defer { observer.stop() }
        var changes: [V2AuthenticationStateObserver.Change] = []
        observer.start(session: auth, epoch: await auth.currentEpoch()) { changes.append($0) }
        await #expect(throws: V2AuthSessionError.unauthenticated) { _ = try await auth.refresh() }
        try await wait { changes == [.authenticationRequired] }
    }

    @Test("protected-data failure pauses presentation and recovery can be observed again")
    func protectedDataDoesNotBecomeLogout() async throws {
        let credentials = try makeCredentials("a")
        let store = PresentationCredentialStore(credentials)
        let auth = V2AuthSession(credentialStore: store, transport: PresentationRefresh(credentials: credentials))
        _ = try await auth.restoreState()
        let observer = V2AuthenticationStateObserver()
        defer { observer.stop() }
        var changes: [V2AuthenticationStateObserver.Change] = []
        observer.start(session: auth, epoch: await auth.currentEpoch()) { changes.append($0) }
        await store.setSaveUnavailable(true)
        await #expect(throws: V2AuthSessionError.credentialsUnavailable) { _ = try await auth.refresh() }
        try await wait { changes == [.protectedDataUnavailable] }
        observer.stop()
        await store.setSaveUnavailable(false)
        await auth.retryCredentialStoreAccess()
        _ = try await auth.restoreState()
        observer.start(session: auth, epoch: await auth.currentEpoch()) { changes.append($0) }
        _ = try await auth.refresh()
        #expect(changes == [.protectedDataUnavailable])
        #expect(await store.exists())
    }

    @Test("a replacement observer never receives a queued terminal result for the old epoch")
    func observerReplacementRejectsOldQueuedResult() async throws {
        let a = try makeCredentials("a")
        let b = try makeCredentials("b")
        let auth = V2AuthSession(credentialStore: PresentationCredentialStore(a), transport: PresentationRefresh(credentials: a))
        _ = try await auth.restoreState()
        let oldEpoch = await auth.currentEpoch()
        try await auth.handleTerminalRejection()
        try await auth.establish(b)
        let newEpoch = await auth.currentEpoch()
        let observer = V2AuthenticationStateObserver()
        defer { observer.stop() }
        var oldChanges: [V2AuthenticationStateObserver.Change] = []
        var currentChanges: [V2AuthenticationStateObserver.Change] = []
        // Both starts run synchronously on MainActor, before either task can
        // resume. The cancelled old stream must not call the new handler.
        observer.start(session: auth, epoch: oldEpoch) { oldChanges.append($0) }
        observer.start(session: auth, epoch: newEpoch) { currentChanges.append($0) }
        try await auth.handleTerminalRejection()
        try await wait { currentChanges == [.authenticationRequired] }
        #expect(oldChanges.isEmpty)
    }

    @Test("terminal deletion failure has a distinct pending-cleanup destination")
    func terminalDeletionFailureIsNotOrdinaryProtectedData() async throws {
        let credentials = try makeCredentials("a")
        let store = PresentationCredentialStore(credentials, deleteUnavailable: true)
        let auth = V2AuthSession(credentialStore: store, transport: PresentationRefresh(credentials: credentials))
        _ = try await auth.restoreState()
        let epoch = await auth.currentEpoch()
        await #expect(throws: V2AuthSessionError.credentialsUnavailable) { try await auth.handleTerminalRejection() }
        let observer = V2AuthenticationStateObserver()
        defer { observer.stop() }
        var changes: [V2AuthenticationStateObserver.Change] = []
        observer.start(session: auth, epoch: epoch) { changes.append($0) }
        try await wait { changes == [.credentialDeletionPending] }
    }

    private func makeCredentials(_ account: String) throws -> V2AuthCredentials {
        try .init(userID: .init(account), deviceID: .init(account + "-device"), accessToken: "test-access",
                  accessTokenExpiresAt: .distantFuture, refreshCredential: "test-refresh")
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !predicate(), clock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(predicate())
    }
}
private actor PresentationCredentialStore: V2CredentialStore {
    private var record: V2AuthCredentialRecord?
    private var saveUnavailable = false
    private let deleteUnavailable: Bool
    init(_ credentials: V2AuthCredentials, deleteUnavailable: Bool = false) {
        record = .init(credentials: credentials); self.deleteUnavailable = deleteUnavailable
    }
    func load() -> V2AuthCredentialRecord? { record }
    func save(_ value: V2AuthCredentialRecord) throws {
        if saveUnavailable { throw V2CredentialStoreError.unavailable }
        record = value
    }
    func delete() throws {
        if deleteUnavailable { throw V2CredentialStoreError.unavailable }
        record = nil
    }
    func setSaveUnavailable(_ value: Bool) { saveUnavailable = value }
    func exists() -> Bool { record != nil }
}
private actor PresentationRefresh: V2AuthTransport {
    let rejected: Bool
    let credentials: V2AuthCredentials
    init(rejected: Bool = false, credentials: V2AuthCredentials) { self.rejected = rejected; self.credentials = credentials }
    func refresh(_ request: V2RefreshRequest) throws -> V2AuthCredentials {
        if rejected { throw V2AuthTransportError.terminalRejection }
        return credentials
    }
}

private struct PresentationHTTPTransport: V2AuthHTTPTransport {
    let status: Int
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        return (Data(), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])))
    }
}

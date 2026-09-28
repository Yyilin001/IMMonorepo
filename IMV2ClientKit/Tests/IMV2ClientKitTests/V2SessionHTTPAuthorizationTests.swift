import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Session scoped HTTP authorization", .timeLimit(.minutes(1)))
struct V2SessionHTTPAuthorizationTests {
    @Test("HTTP unauthorized plus terminal refresh ends the owning session")
    func terminalHTTPRefresh() async throws {
        let credentials = try makeCredentials()
        let store = HTTPAuthorizationCredentialStore(credentials)
        let refreshHTTP = HTTPAuthorizationTransport(status: 401)
        let refresh = try V2HTTPDeviceCredentialAuthTransport(refreshEndpoint: URL(string: "https://account.example.test/v2/device-credentials/refresh")!, transport: refreshHTTP)
        let session = V2AuthSession(credentialStore: store, transport: refresh)
        _ = try await session.restoreState()
        let edge = HTTPAuthorizationTransport(status: 401)
        let authorization = V2SessionHTTPAuthorization(session: session, epoch: await session.currentEpoch(), transport: edge)
        let client = try V2HTTPDeviceSessionClient(endpoint: URL(string: "https://account.example.test/v2/devices")!, credentials: authorization, transport: authorization)
        _ = try? await client.list(cursor: nil, pageSize: 10)
        #expect(await session.currentState() == .unauthenticated)
        #expect(await store.current() == nil)
        #expect(await refreshHTTP.count() == 1)
        #expect(await edge.count() == 1)
    }

    @Test("business status codes do not revoke credentials", arguments: [200, 403, 404, 409, 429, 503])
    func nonterminalStatuses(status: Int) async throws {
        let old = try makeCredentials()
        let store = HTTPAuthorizationCredentialStore(old)
        let refresh = HTTPAuthorizationTransport(status: 401)
        let session = V2AuthSession(credentialStore: store, transport: try refreshTransport(refresh))
        _ = try await session.restoreState()
        let edge = HTTPAuthorizationTransport(status: status)
        let authorization = V2SessionHTTPAuthorization(session: session, epoch: await session.currentEpoch(), transport: edge)
        let result = try await authorization.data(for: request(old))
        #expect(result.1.statusCode == status)
        #expect(await refresh.count() == 0)
        #expect(await store.current()?.credentials == old)
    }

    @Test("successful refresh preserves application retry ownership")
    func successfulRefreshDoesNotReplayWrite() async throws {
        let old = try makeCredentials()
        let successor = try makeCredentials(token: "successor")
        let store = HTTPAuthorizationCredentialStore(old)
        let refresh = HTTPAuthorizationTransport(status: 200, body: try refreshBody(successor))
        let session = V2AuthSession(credentialStore: store, transport: try refreshTransport(refresh))
        _ = try await session.restoreState()
        let edge = HTTPAuthorizationTransport(status: 401)
        let authorization = V2SessionHTTPAuthorization(session: session, epoch: await session.currentEpoch(), transport: edge)
        let original = try request(old)
        #expect(try await authorization.data(for: original).1.statusCode == 401)
        #expect(await store.current()?.credentials == successor)
        #expect(await refresh.count() == 1)
        #expect(await edge.count() == 1)
        // A late response using the predecessor token cannot rotate again.
        #expect(try await authorization.data(for: original).1.statusCode == 401)
        #expect(await refresh.count() == 1)
        #expect(await store.current()?.credentials == successor)
        #expect(try await authorization.deviceSessionCredentials().accessToken == "successor")
    }

    @Test("transport and refresh failures preserve credentials", arguments: ["network", "refresh-503", "refresh-invalid", "locked", "cancelled"])
    func retryableFailures(scenario: String) async throws {
        let old = try makeCredentials()
        let store = HTTPAuthorizationCredentialStore(old)
        let refresh = HTTPAuthorizationTransport(status: scenario == "refresh-503" ? 503 : 200)
        let session = V2AuthSession(credentialStore: store, transport: try refreshTransport(refresh))
        _ = try await session.restoreState()
        if scenario == "locked" { await store.setSaveUnavailable(true) }
        let edge = HTTPAuthorizationTransport(status: 401, failure: scenario == "network" ? .network : scenario == "cancelled" ? .cancelled : nil)
        let authorization = V2SessionHTTPAuthorization(session: session, epoch: await session.currentEpoch(), transport: edge)
        await #expect(throws: (any Error).self) { try await authorization.data(for: request(old)) }
        #expect(await store.current()?.credentials == old)
        #expect(await session.currentState() != .unauthenticated)
        #expect(await refresh.count() == (["network", "locked", "cancelled"].contains(scenario) ? 0 : 1))
        if scenario == "locked" { #expect(await session.currentState() == .credentialsUnavailable) }
    }

    @Test("old HTTP success and errors cannot escape into a replacement login", arguments: [200, 401, 403, -1])
    func replacementFencesLateResponse(status: Int) async throws {
        let old = try makeCredentials()
        let successor = try makeCredentials(account: "replacement", token: "new-account")
        let store = HTTPAuthorizationCredentialStore(old)
        let refresh = HTTPAuthorizationTransport(status: 401)
        let session = V2AuthSession(credentialStore: store, transport: try refreshTransport(refresh))
        _ = try await session.restoreState()
        let edge = HTTPAuthorizationTransport(status: status, blocked: true, failure: status == -1 ? .network : nil)
        let authorization = V2SessionHTTPAuthorization(session: session, epoch: await session.currentEpoch(), transport: edge)
        let task = Task { try await authorization.data(for: request(old)) }
        await edge.waitForRequest()
        try await session.establish(successor)
        await edge.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: CancellationError.self) { try await authorization.pushEndpointCredentials() }
        await #expect(throws: CancellationError.self) { try await authorization.mediaEdgeCredentials() }
        await #expect(throws: CancellationError.self) { try await authorization.data(for: request(old)) }
        #expect(await store.current()?.credentials == successor)
        #expect(await refresh.count() == 0)
        #expect(await edge.count() == 1)
    }

    @Test("cancellation before a late 401 does not start refresh")
    func cancellationFencesLateUnauthorized() async throws {
        let old = try makeCredentials()
        let store = HTTPAuthorizationCredentialStore(old)
        let refresh = HTTPAuthorizationTransport(status: 401)
        let session = V2AuthSession(credentialStore: store, transport: try refreshTransport(refresh))
        _ = try await session.restoreState()
        let edge = HTTPAuthorizationTransport(status: 401, blocked: true)
        let authorization = V2SessionHTTPAuthorization(session: session, epoch: await session.currentEpoch(), transport: edge)
        let task = Task { try await authorization.data(for: request(old)) }
        await edge.waitForRequest()
        task.cancel()
        await edge.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await refresh.count() == 0)
        #expect(await store.current()?.credentials == old)
    }

    @Test("concurrent HTTP failures share the existing refresh flight")
    func concurrentHTTPRefresh() async throws {
        let old = try makeCredentials()
        let successor = try makeCredentials(token: "successor")
        let store = HTTPAuthorizationCredentialStore(old)
        let refresh = HTTPAuthorizationTransport(status: 200, body: try refreshBody(successor), blocked: true)
        let session = V2AuthSession(credentialStore: store, transport: try refreshTransport(refresh))
        _ = try await session.restoreState()
        let edge = HTTPAuthorizationTransport(status: 401)
        let authorization = V2SessionHTTPAuthorization(session: session, epoch: await session.currentEpoch(), transport: edge)
        let original = try request(old)
        let first = Task { try await authorization.data(for: original) }
        await refresh.waitForRequest()
        let second = Task { try await authorization.data(for: original) }
        await edge.waitForRequest(count: 2)
        await refresh.release()
        #expect(try await first.value.1.statusCode == 401)
        #expect(try await second.value.1.statusCode == 401)
        #expect(await refresh.count() == 1)
        #expect(await store.current()?.credentials == successor)
    }

    @Test("URLSession cancellation remains cancellation at both HTTP boundaries", arguments: [false, true])
    func urlSessionCancellation(refreshing: Bool) async throws {
        let old = try makeCredentials()
        let store = HTTPAuthorizationCredentialStore(old)
        let refresh = HTTPAuthorizationTransport(status: 200, failure: .urlCancelled)
        let session = V2AuthSession(credentialStore: store, transport: try refreshTransport(refresh))
        _ = try await session.restoreState()
        let edge = HTTPAuthorizationTransport(status: 401, failure: refreshing ? nil : .urlCancelled)
        let authorization = V2SessionHTTPAuthorization(session: session, epoch: await session.currentEpoch(), transport: edge)
        await #expect(throws: CancellationError.self) { try await authorization.data(for: request(old)) }
        #expect(await store.current()?.credentials == old)
        #expect(await session.currentState() != .unauthenticated)
    }

    @Test("real builder carries local deadline through request copies without wire headers")
    func builderDeadlineMetadata() async throws {
        let old = try makeCredentials()
        let session = V2AuthSession(credentialStore: HTTPAuthorizationCredentialStore(old), transport: try refreshTransport(HTTPAuthorizationTransport(status: 401)))
        _ = try await session.restoreState()
        let edge = HTTPAuthorizationTransport(status: 200)
        let authorization = V2SessionHTTPAuthorization(session: session, epoch: await session.currentEpoch(), transport: edge)
        let client = try V2HTTPDeviceSessionClient(endpoint: URL(string: "https://account.example.test/v2/devices")!, credentials: authorization, transport: authorization)
        _ = try? await client.list(cursor: nil, pageSize: 10)
        let observed = await edge.deadlineObservation()
        #expect(observed.0 != nil)
        #expect(observed.0 == observed.1)
        #expect(observed.2.keys.allSatisfy { !$0.lowercased().contains("deadline") })
        var copy = try request(old)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        V2HTTPRequestDeadline.attach(deadline, to: &copy)
        copy = (copy as NSURLRequest).copy() as! URLRequest
        copy.httpBody = Data("changed body".utf8)
        copy.setValue("value", forHTTPHeaderField: "X-Copy-Test")
        #expect(V2HTTPRequestDeadline.deadline(for: copy) == deadline)
    }

    @Test("short HTTP deadline drains real shared refresh without shortening another subscriber")
    func physicalRefreshUsesIndependentBudget() async throws {
        let old = try makeCredentials()
        let successor = try makeCredentials(token: "successor")
        HTTPDeadlineProtocol.state.reset(body: try refreshBody(successor))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPDeadlineProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }
        let scheduler = V2AccountWorkScheduler(configuration: .init(ordinaryLimit: 1))
        let executor = V2HTTPExecutor(session: urlSession, scheduler: scheduler)
        let refresh = try V2HTTPDeviceCredentialAuthTransport(refreshEndpoint: URL(string: "https://account.example.test/refresh")!,
            transport: V2URLSessionAuthHTTPTransport(executor: executor, workContext: .init(service: "authentication", kind: .authentication)))
        let session = V2AuthSession(credentialStore: HTTPAuthorizationCredentialStore(old), transport: refresh)
        _ = try await session.restoreState()
        let authorization = V2SessionHTTPAuthorization(session: session, epoch: await session.currentEpoch(),
            transport: V2URLSessionAuthHTTPTransport(executor: executor), scheduler: scheduler)
        var original = try request(old)
        V2HTTPRequestDeadline.attach(.now.advanced(by: .milliseconds(500)), to: &original)
        let boundRequest = original
        let returned = HTTPDeadlineReturnFlag()
        let short = Task {
            defer { Task { await returned.finish() } }
            return try await authorization.data(for: boundRequest)
        }
        let startLimit = ContinuousClock.now.advanced(by: .seconds(2))
        while !HTTPDeadlineProtocol.state.started {
            try #require(ContinuousClock.now < startLimit)
            await Task.yield()
        }
        let independent = Task { try await session.refresh() }
        try await Task.sleep(for: .milliseconds(600))
        #expect(await scheduler.snapshot().active == 1)
        #expect(await !returned.finished)
        #expect(HTTPDeadlineProtocol.state.stops == 0)
        HTTPDeadlineProtocol.state.release()
        await #expect(throws: V2HTTPFailure(kind: .deadlineExceeded, service: "account", certainty: .outcomeUnknown)) { try await short.value }
        #expect(try await independent.value == successor)
        #expect(await scheduler.snapshot().active == 0)
        #expect(HTTPDeadlineProtocol.state.refreshes == 1)
        #expect(HTTPDeadlineProtocol.state.businessRequests == 1)
    }

    @Test("initial expired credential timeout retains auth slot until real rotation drains")
    func initialCredentialsIncludeDeadline() async throws {
        let old = try V2AuthCredentials(userID: .init("test-user"), deviceID: .init("test-device"),
            accessToken: "expired", accessTokenExpiresAt: .distantPast, refreshCredential: "test-refresh")
        let successor = try makeCredentials(token: "successor")
        HTTPDeadlineProtocol.state.reset(body: try refreshBody(successor))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPDeadlineProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }
        let scheduler = V2AccountWorkScheduler(configuration: .init(ordinaryLimit: 1))
        let executor = V2HTTPExecutor(session: urlSession, scheduler: scheduler)
        let refresh = try V2HTTPDeviceCredentialAuthTransport(refreshEndpoint: URL(string: "https://account.example.test/refresh")!,
            transport: V2URLSessionAuthHTTPTransport(executor: executor, workContext: .init(service: "authentication", kind: .authentication)))
        let session = V2AuthSession(credentialStore: HTTPAuthorizationCredentialStore(old), transport: refresh)
        _ = try await session.restoreState()
        let authorization = V2SessionHTTPAuthorization(session: session, epoch: await session.currentEpoch(), scheduler: scheduler, requestTimeout: 0.5)
        let returned = HTTPDeadlineReturnFlag()
        let short = Task {
            defer { Task { await returned.finish() } }
            return try await authorization.deviceSessionCredentials()
        }
        let startLimit = ContinuousClock.now.advanced(by: .seconds(2))
        while !HTTPDeadlineProtocol.state.started {
            try #require(ContinuousClock.now < startLimit)
            await Task.yield()
        }
        let independent = Task { try await session.refresh() }
        try await Task.sleep(for: .milliseconds(600))
        #expect(await scheduler.snapshot().active == 1)
        #expect(await !returned.finished)
        #expect(HTTPDeadlineProtocol.state.stops == 0)
        HTTPDeadlineProtocol.state.release()
        await #expect(throws: V2HTTPFailure(kind: .deadlineExceeded, service: "authentication", certainty: .notStarted)) { try await short.value }
        #expect(try await independent.value == successor)
        #expect(await scheduler.snapshot().active == 0)
        #expect(HTTPDeadlineProtocol.state.refreshes == 1)
        #expect(HTTPDeadlineProtocol.state.businessRequests == 0)
    }

    private func refreshTransport(_ transport: HTTPAuthorizationTransport) throws -> V2HTTPDeviceCredentialAuthTransport {
        try .init(refreshEndpoint: URL(string: "https://account.example.test/v2/device-credentials/refresh")!, transport: transport)
    }

    @Test("every concurrent refresh waiter receives the retryable failure", arguments: [503, 200])
    func concurrentRefreshFailures(status: Int) async throws {
        let old = try makeCredentials()
        let store = HTTPAuthorizationCredentialStore(old)
        let refresh = HTTPAuthorizationTransport(status: status)
        let session = V2AuthSession(credentialStore: store, transport: try refreshTransport(refresh))
        _ = try await session.restoreState()
        let expected: V2HTTPAuthTransportError = status == 503 ? .serverStatus(503) : .invalidResponse
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    await #expect(throws: expected) { try await session.refresh() }
                }
            }
            await group.waitForAll()
        }
        #expect(await store.current()?.credentials == old)
        #expect(await store.current()?.pendingRefreshOperationID != nil)
        #expect(await session.currentState() == .authenticated(accessTokenExpiresAt: old.accessTokenExpiresAt))
    }

    @Test("refresh after a failed pending save persists its operation before HTTP")
    func retriesPendingSaveBeforeHTTP() async throws {
        let old = try makeCredentials()
        let successor = try makeCredentials(token: "successor")
        let store = HTTPAuthorizationCredentialStore(old)
        let refresh = HTTPAuthorizationTransport(status: 200, body: try refreshBody(successor), blocked: true)
        let session = V2AuthSession(credentialStore: store, transport: try refreshTransport(refresh))
        _ = try await session.restoreState()
        await store.setSaveUnavailable(true)
        await #expect(throws: V2AuthSessionError.credentialsUnavailable) { try await session.refresh() }
        #expect(await refresh.count() == 0)
        #expect(await store.current()?.pendingRefreshOperationID == nil)
        await store.setSaveUnavailable(false)
        await session.retryCredentialStoreAccess()
        let retry = Task { try await session.refresh() }
        await refresh.waitForRequest()
        #expect(await store.current()?.pendingRefreshOperationID != nil)
        await refresh.release()
        #expect(try await retry.value == successor)
        #expect(await store.current()?.pendingRefreshOperationID == nil)
    }

    private func request(_ credentials: V2AuthCredentials) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://account.example.test/v2/devices/revoke")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"operation_id":"test-operation"}"#.utf8)
        request.setValue("Bearer " + credentials.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(credentials.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        return request
    }

    private func refreshBody(_ credentials: V2AuthCredentials) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["userID": credentials.userID.rawValue, "deviceID": credentials.deviceID.rawValue, "accessToken": credentials.accessToken, "accessTokenExpiresAtMilliseconds": Int64(credentials.accessTokenExpiresAt.timeIntervalSince1970 * 1000), "refreshCredential": credentials.refreshCredential, "revocationCredential": credentials.revocationCredential.rawValue, "revocationCredentialExpiresAtMilliseconds": Int64(credentials.revocationCredentialExpiresAt.timeIntervalSince1970 * 1000)])
    }

    private func makeCredentials(account: String = "test", token: String = "test-access") throws -> V2AuthCredentials {
        try .init(userID: .init(account + "-user"), deviceID: .init(account + "-device"), accessToken: token, accessTokenExpiresAt: .distantFuture, refreshCredential: "test-refresh")
    }
}

private actor HTTPAuthorizationCredentialStore: V2CredentialStore {
    private var record: V2AuthCredentialRecord?
    init(_ credentials: V2AuthCredentials) { record = .init(credentials: credentials) }
    func load() -> V2AuthCredentialRecord? { record }
    private var saveUnavailable = false
    func setSaveUnavailable(_ value: Bool) { saveUnavailable = value }
    func save(_ value: V2AuthCredentialRecord) throws {
        if saveUnavailable { throw V2CredentialStoreError.unavailable }
        record = value
    }
    func delete() { record = nil }
    func current() -> V2AuthCredentialRecord? { record }
}

private actor HTTPAuthorizationTransport: V2AuthHTTPTransport, V2ClientDeviceSessionHTTPTransport {
    enum Failure { case network, cancelled, urlCancelled }
    private let status: Int
    private let body: Data
    private let failure: Failure?
    private var blocked: Bool
    private var observedDeadline: ContinuousClock.Instant?
    private var observedScope: ContinuousClock.Instant?
    private var observedHeaders: [String: String] = [:]
    private var requests = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    init(status: Int, body: Data = Data(), blocked: Bool = false, failure: Failure? = nil) {
        self.status = status; self.body = body; self.blocked = blocked; self.failure = failure
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        observedDeadline = V2HTTPRequestDeadline.deadline(for: request)
        observedScope = V2HTTPRequestDeadline.current
        observedHeaders = request.allHTTPHeaderFields ?? [:]
        requests += 1
        let ready = waiters.filter { requests >= $0.0 }
        waiters.removeAll { requests >= $0.0 }
        for item in ready { item.1.resume() }
        if blocked { await withCheckedContinuation { releaseWaiters.append($0) } }
        if let failure {
            switch failure { case .network: throw URLError(.notConnectedToInternet); case .cancelled: throw CancellationError(); case .urlCancelled: throw URLError(.cancelled) }
        }
        let url = try #require(request.url)
        return (body, try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])))
    }
    func deadlineObservation() -> (ContinuousClock.Instant?, ContinuousClock.Instant?, [String: String]) { (observedDeadline, observedScope, observedHeaders) }
    func count() -> Int { requests }
    func waitForRequest(count: Int = 1) async {
        if requests >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func release() {
        blocked = false
        let pending = releaseWaiters; releaseWaiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor HTTPDeadlineReturnFlag {
    var finished = false
    func finish() { finished = true }
}
private final class HTTPDeadlineProtocol: URLProtocol, @unchecked Sendable {
    static let state = State()
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [HTTPDeadlineProtocol] = []
        private var body = Data()
        private var refreshCount = 0
        private var businessCount = 0
        private var stopCount = 0
        var started: Bool { lock.withLock { !pending.isEmpty } }
        var stops: Int { lock.withLock { stopCount } }
        var refreshes: Int { lock.withLock { refreshCount } }
        var businessRequests: Int { lock.withLock { businessCount } }
        func reset(body: Data) { lock.withLock { self.body = body; pending = []; refreshCount = 0; businessCount = 0; stopCount = 0 } }
        func receive(_ request: HTTPDeadlineProtocol) {
            if request.request.url?.path == "/refresh" { lock.withLock { pending.append(request); refreshCount += 1 } }
            else { lock.withLock { businessCount += 1 }; request.deliver(status: 401, body: Data()) }
        }
        func stop() { lock.withLock { stopCount += 1 } }
        func release() {
            let delivery = lock.withLock { let value = (pending, body); pending = []; return value }
            for request in delivery.0 { request.deliver(status: 200, body: delivery.1) }
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.state.receive(self) }
    override func stopLoading() { if request.url?.path == "/refresh" { Self.state.stop() } }
    func deliver(status: Int, body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

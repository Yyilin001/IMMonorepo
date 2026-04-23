import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

private actor RestoreGate {
    private var hasStarted = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuations: [CheckedContinuation<Void, Never>] = []
    private var isResumed = false

    func markStarted() {
        hasStarted = true
        startContinuation?.resume()
        startContinuation = nil
    }

    func waitUntilStarted() async {
        guard !hasStarted else {
            return
        }

        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func waitForResume() async {
        guard !isResumed else {
            return
        }

        await withCheckedContinuation { continuation in
            resumeContinuations.append(continuation)
        }
    }

    func resume() {
        isResumed = true
        let continuations = resumeContinuations
        resumeContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private actor IMGapSyncCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    func currentValue() -> Int {
        value
    }
}

private actor IMRequestCounter {
    private var counts: [String: Int] = [:]

    func increment(_ key: String) {
        counts[key, default: 0] += 1
    }

    func count(for key: String) -> Int {
        counts[key, default: 0]
    }
}

private actor IMReadSequenceRecorder {
    private var sequences: [UInt64] = []

    func record(_ sequence: UInt64) {
        sequences.append(sequence)
    }

    func allSequences() -> [UInt64] {
        sequences
    }
}

private actor IMConversationMutationState {
    private var didMutate = false

    func markMutated() {
        didMutate = true
    }

    func isMutated() -> Bool {
        didMutate
    }
}

private actor IMSummarySequenceState {
    private var latestServerSequence: Int

    init(latestServerSequence: Int = 1) {
        self.latestServerSequence = latestServerSequence
    }

    func setLatestServerSequence(_ sequence: Int) {
        latestServerSequence = sequence
    }

    func currentLatestServerSequence() -> Int {
        latestServerSequence
    }
}

private final class AuthManagerBackgroundTransferMonitor: BackgroundTransferMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [BackgroundTransferSnapshot]
    private var continuations: [UUID: AsyncStream<BackgroundTransferSnapshot>.Continuation] = [:]

    init(initialSnapshots: [BackgroundTransferSnapshot] = []) {
        self.snapshots = initialSnapshots
    }

    func currentSnapshots() -> [BackgroundTransferSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots
    }

    func updates() -> AsyncStream<BackgroundTransferSnapshot> {
        AsyncStream { continuation in
            let identifier = UUID()
            lock.lock()
            continuations[identifier] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations.removeValue(forKey: identifier)
                self?.lock.unlock()
            }
        }
    }

    func cancelTransfer(sessionIdentifier: String, taskIdentifier: Int) async {
        removeSnapshot(sessionIdentifier: sessionIdentifier, taskIdentifier: taskIdentifier)
    }

    private func removeSnapshot(sessionIdentifier: String, taskIdentifier: Int) {
        lock.lock()
        snapshots.removeAll {
            $0.sessionIdentifier == sessionIdentifier && $0.taskIdentifier == taskIdentifier
        }
        lock.unlock()
    }

    func emit(_ snapshot: BackgroundTransferSnapshot) {
        let isActive: Bool
        switch snapshot.state {
        case .running, .waitingForConnectivity:
            isActive = true
        case .completed, .cancelled, .failed:
            isActive = false
        }

        lock.lock()
        if isActive {
            snapshots.removeAll { $0.id == snapshot.id }
            snapshots.append(snapshot)
        } else {
            snapshots.removeAll { $0.id == snapshot.id }
        }
        let currentContinuations = Array(continuations.values)
        lock.unlock()

        currentContinuations.forEach { $0.yield(snapshot) }
    }
}

private actor IMConnectionTestHarness {
    private var continuation: AsyncThrowingStream<IMTCPConnectionEvent, Error>.Continuation?
    private var disconnectCount = 0
    private var sentLines: [String] = []
    private var sendAttemptCount = 0
    private let sendDelayNanoseconds: UInt64
    private let failingSendNumbers: Set<Int>

    init(sendDelayNanoseconds: UInt64 = 0, failingSendNumbers: Set<Int> = []) {
        self.sendDelayNanoseconds = sendDelayNanoseconds
        self.failingSendNumbers = failingSendNumbers
    }

    func makeConnection() -> IMTCPConnection {
        let events = AsyncThrowingStream<IMTCPConnectionEvent, Error> { continuation in
            self.continuation = continuation
        }

        return IMTCPConnection(
            authentication: IMTCPAuthAcceptedPayload(
                connectionID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
                userID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                sessionID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
                heartbeatIntervalSeconds: 30,
                serverTime: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            events: events,
            sendLine: { line in
                try await self.record(line)
            },
            disconnectHandler: {
                await self.disconnect()
            }
        )
    }

    func yield(_ event: IMTCPConnectionEvent) {
        continuation?.yield(event)
    }

    func disconnections() -> Int {
        disconnectCount
    }

    func recordedLines() -> [String] {
        sentLines
    }

    private func disconnect() {
        disconnectCount += 1
        continuation?.finish()
        continuation = nil
    }

    private func record(_ line: String) async throws {
        if sendDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: sendDelayNanoseconds)
        }
        sendAttemptCount += 1
        if failingSendNumbers.contains(sendAttemptCount) {
            throw URLError(.notConnectedToInternet)
        }
        sentLines.append(line)
    }
}

@MainActor
struct AuthManagerTests {
    private nonisolated static let user = AuthUser(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        email: "manager@example.com"
    )

    @Test func loadSessionsMarksServerOfflineWhenConnectivityFails() async {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/auth/sessions"):
                throw URLError(.notConnectedToInternet)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(transport: transport)
        await manager.login(email: Self.user.email, password: "password123")
        await manager.loadSessions()

        #expect(manager.serverStatus == .offline(message: "当前无法连接服务器。"))
        #expect(manager.currentUser?.id == Self.user.id)
    }

    @Test func restoreSessionDoesNotOverrideNewerLogin() async throws {
        let harness = IMConnectionTestHarness()
        let tokenStore = InMemoryTokenStore()
        try tokenStore.save("refresh-1", for: "refresh_token")

        let restoredUser = AuthUser(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            email: "restored@example.com"
        )
        let gate = RestoreGate()
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/refresh"):
                await gate.markStarted()
                await gate.waitForResume()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: restoredUser,
                        accessToken: "restore-access",
                        refreshToken: "restore-refresh"
                    )
                )
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "login-access",
                        refreshToken: "login-refresh"
                    )
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: wrapWithDefaultIMResponses(transport)),
            tokenStore: tokenStore,
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: true
        )

        await gate.waitUntilStarted()
        await manager.login(email: Self.user.email, password: "password123")
        await gate.resume()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(manager.phase == .signedIn(Self.user))
        #expect(manager.currentUser?.email == Self.user.email)
    }

    @Test func loadSessionsSignsOutWhenSessionIsRevoked() async {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/auth/sessions"):
                let body = try HTTPFixtures.jsonBody(ErrorEnvelope(reason: "当前登录已失效。"))
                return HTTPFixtures.response(statusCode: 401, body: body)
            case ("POST", "/api/auth/refresh"):
                let body = try HTTPFixtures.jsonBody(ErrorEnvelope(reason: "当前登录已失效。"))
                return HTTPFixtures.response(statusCode: 401, body: body)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(transport: transport)
        await manager.login(email: Self.user.email, password: "password123")
        await manager.loadSessions()

        #expect(manager.phase == .signedOut(message: "当前登录已失效。"))
        #expect(manager.serverStatus == .unknown)
        #expect(manager.currentUser == nil)
        #expect(manager.sessions.isEmpty)
    }

    @Test func reloadProfileMarksServerOfflineWhenConnectivityFails() async {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/me"):
                throw URLError(.notConnectedToInternet)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(transport: transport)
        await manager.login(email: Self.user.email, password: "password123")
        await manager.reloadProfile()

        #expect(manager.serverStatus == .offline(message: "当前无法连接服务器。"))
        #expect(manager.currentUser?.id == Self.user.id)
    }

    @Test func signOutOtherDeviceClearsLocalSessionWhenForbidden() async {
        let targetSessionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("DELETE", "/api/auth/sessions/\(targetSessionID.uuidString)"):
                let body = try HTTPFixtures.jsonBody(ErrorEnvelope(reason: "当前设备已被撤销。"))
                return HTTPFixtures.response(statusCode: 403, body: body)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(transport: transport)
        await manager.login(email: Self.user.email, password: "password123")
        await manager.signOut(sessionID: targetSessionID, isCurrent: false)

        #expect(manager.phase == .signedOut(message: "当前设备已被撤销。"))
        #expect(manager.serverStatus == .unknown)
        #expect(manager.currentUser == nil)
    }

    @Test func loginMarksServerOfflineWhenConnectivityFails() async {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                throw URLError(.notConnectedToInternet)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(transport: transport)
        await manager.login(email: Self.user.email, password: "password123")

        #expect(manager.phase == .signedOut(message: "当前无法连接服务器。"))
        #expect(manager.serverStatus == .offline(message: "当前无法连接服务器。"))
    }

    @Test func registerMarksServerOfflineWhenConnectivityFails() async {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/register"):
                throw URLError(.notConnectedToInternet)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(transport: transport)
        await manager.register(email: Self.user.email, password: "password123")

        #expect(manager.phase == .signedOut(message: "当前无法连接服务器。"))
        #expect(manager.serverStatus == .offline(message: "当前无法连接服务器。"))
    }

    @Test func recoveredBackgroundUnauthorizedFailureClearsSession() async {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let snapshot = BackgroundTransferSnapshot(
            sessionIdentifier: "tests.background.download",
            taskIdentifier: 12,
            kind: .download,
            state: .running,
            progress: nil,
            destinationURL: FileManager.default.temporaryDirectory.appending(path: "restored.bin")
        )
        let monitor = AuthManagerBackgroundTransferMonitor(initialSnapshots: [snapshot])
        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: wrapWithDefaultIMResponses(transport)),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            backgroundTransferMonitor: monitor,
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        monitor.emit(
            BackgroundTransferSnapshot(
                sessionIdentifier: snapshot.sessionIdentifier,
                taskIdentifier: snapshot.taskIdentifier,
                kind: .download,
                state: .failed(
                    BackgroundTransferSnapshot.Failure(
                        error: APIError.unauthorized("当前登录已失效。")
                    )
                ),
                progress: nil,
                destinationURL: snapshot.destinationURL
            )
        )
        try? await Task.sleep(for: .milliseconds(50))

        #expect(manager.phase == .signedOut(message: "当前登录已失效。"))
        #expect(manager.serverStatus == .unknown)
        #expect(manager.currentUser == nil)
    }

    @Test func loginAutoConnectsIMAndLogoutDisconnectsConnection() async throws {
        let harness = IMConnectionTestHarness()
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("DELETE", "/api/auth/sessions/current"):
                return HTTPFixtures.response(statusCode: 200)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: wrapWithDefaultIMResponses(transport)),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run { manager.imConnectionStatus == .connected }
        }

        await manager.logout()
        try await Self.waitUntil {
            await MainActor.run { manager.phase == .signedOut(message: nil) }
        }

        #expect(await harness.disconnections() == 1)
        #expect(manager.imConnectionStatus == .disconnected)
    }

    @Test func kickClearsLocalSession() async throws {
        let harness = IMConnectionTestHarness()
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: wrapWithDefaultIMResponses(transport)),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run { manager.imConnectionStatus == .connected }
        }

        await harness.yield(
            .kick(IMTCPKickPayload(reason: .sessionRevoked, message: "当前登录已失效。"))
        )
        try await Self.waitUntil {
            await MainActor.run { manager.phase == .signedOut(message: "当前登录已失效。") }
        }

        #expect(manager.currentUser == nil)
        #expect(manager.imConnectionStatus == .disconnected)
    }

    @Test func incomingMessageUpdatesConversationStoreAndSendsDeliveryAck() async throws {
        let harness = IMConnectionTestHarness()
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: wrapWithDefaultIMResponses(transport)),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run { manager.imConnectionStatus == .connected }
        }

        let requestID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        await harness.yield(
            .message(
                requestID: requestID,
                payload: IMTCPMessagePayload(
                    clientMessageID: nil,
                    messageID: "srv-msg-1",
                    conversationID: "conv-42",
                    senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    serverSequence: 99,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_000_999),
                    kind: "text",
                    body: ["text": "hello from server"]
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 1
            }
        }

        let conversation = manager.imConversationStore.selectedConversation
        #expect(conversation?.id == "conv-42")
        #expect(conversation?.messages.first?.text == "hello from server")
        #expect(conversation?.messages.first?.direction == .incoming)
        #expect(conversation?.messages.first?.serverSequence == 99)
        #expect(conversation?.messages.first?.createdAt == Date(timeIntervalSince1970: 1_700_000_999))

        let ackLine = try await Self.requireRecordedLine(at: 0, from: harness)
        let ackPacket = try Self.decode(IMTCPPacketEnvelope<IMTCPAckPayload>.self, from: ackLine)
        #expect(ackPacket.type == .ack)
        #expect(ackPacket.requestID == requestID)
        #expect(ackPacket.payload.messageID == "srv-msg-1")
        #expect(ackPacket.payload.conversationID == "conv-42")
        #expect(ackPacket.payload.status == "received")
    }

    @Test func incomingMessagesThrottleMarkReadToHighestSequence() async throws {
        let harness = IMConnectionTestHarness()
        let readRecorder = IMReadSequenceRecorder()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                let payload = try JSONDecoder().decode(
                    IMConversationReadRequestBody.self,
                    from: request.httpBody ?? Data()
                )
                await readRecorder.record(payload.readSequence)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        IMConversationReadResponseBody(
                            conversationID: conversationID,
                            lastReadSequence: Int(payload.readSequence),
                            unreadCount: 0
                        )
                    )
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run { manager.imConnectionStatus == .connected }
        }

        await harness.yield(
            .message(
                requestID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                payload: IMTCPMessagePayload(
                    clientMessageID: nil,
                    messageID: "srv-msg-1",
                    conversationID: conversationID.uuidString,
                    senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    serverSequence: 99,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_000_999),
                    kind: "text",
                    body: ["text": "hello from server 1"]
                )
            )
        )
        await harness.yield(
            .message(
                requestID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                payload: IMTCPMessagePayload(
                    clientMessageID: nil,
                    messageID: "srv-msg-2",
                    conversationID: conversationID.uuidString,
                    senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    serverSequence: 100,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_001_000),
                    kind: "text",
                    body: ["text": "hello from server 2"]
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 2
            }
        }
        try await Self.waitUntil {
            await readRecorder.allSequences() == [100]
        }

        #expect(await readRecorder.allSequences() == [100])
    }

    @Test func sendIMTextWritesTCPPacketAndAckMarksMessageSent() async throws {
        let harness = IMConnectionTestHarness()
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            }
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run { manager.imConnectionStatus == .connected }
        }

        let didSend = await manager.sendIMText("hello client", to: "conv-local")
        #expect(didSend)

        let messageLine = try await Self.requireRecordedLine(at: 0, from: harness)
        let messagePacket = try Self.decode(IMTCPPacketEnvelope<IMTCPMessagePayload>.self, from: messageLine)
        #expect(messagePacket.type == .message)
        #expect(messagePacket.payload.conversationID == "conv-local")
        #expect(messagePacket.payload.senderUserID == nil)
        #expect(messagePacket.payload.serverSequence == nil)
        #expect(messagePacket.payload.serverTimestamp == nil)
        #expect(messagePacket.payload.body["text"] == "hello client")

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.first?.deliveryState == .sending
            }
        }

        await harness.yield(
            .ack(
                requestID: messagePacket.requestID,
                payload: IMTCPAckPayload(
                    messageID: "srv-msg-9001",
                    conversationID: "conv-local",
                    status: "accepted"
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.first?.deliveryState == .sent
            }
        }

        await harness.yield(
            .message(
                requestID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                payload: IMTCPMessagePayload(
                    clientMessageID: messagePacket.payload.clientMessageID,
                    messageID: "srv-msg-9001",
                    conversationID: "conv-local",
                    senderUserID: Self.user.id,
                    serverSequence: 100,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_001_000),
                    kind: "text",
                    body: ["text": "hello client"]
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 1
                    && manager.imConversationStore.selectedConversation?.messages.first?.serverSequence == 100
            }
        }

        let sentMessage = manager.imConversationStore.selectedConversation?.messages.first
        #expect(sentMessage?.direction == .outgoing)
        #expect(sentMessage?.serverMessageID == "srv-msg-9001")
        #expect(sentMessage?.serverSequence == 100)
        #expect(sentMessage?.createdAt == Date(timeIntervalSince1970: 1_700_001_000))
    }

    @Test func sendIMTextQueuesWhenTCPConnectionIsUnavailable() async throws {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                throw URLError(.notConnectedToInternet)
            }
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                if case .signedIn = manager.phase {
                    return true
                }
                return false
            }
        }

        let didSend = await manager.sendIMText("queued while offline", to: "conv-local")

        #expect(didSend)
        let message = try #require(manager.imConversationStore.selectedConversation?.messages.first)
        #expect(message.text == "queued while offline")
        #expect(message.deliveryState == .queued(message: "等待 IM 长连接恢复后发送。"))
    }

    @Test func sendIMTextSendFailureLeavesMessageUnknown() async throws {
        let harness = IMConnectionTestHarness(failingSendNumbers: [1])
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            }
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run { manager.imConnectionStatus == .connected }
        }

        let didSend = await manager.sendIMText("lost ack", to: "conv-local")

        #expect(!didSend)
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.first?.deliveryState
                    == .unknown(message: "发送状态未确认，请重试。")
            }
        }
        let message = try #require(manager.imConversationStore.selectedConversation?.messages.first)
        #expect(manager.imConversationStore.isRetryableFailure(message))
        #expect(manager.imConversationStore.queueSummary(for: "conv-local").retryableIssueCount == 1)
    }

    @Test func cancelQueuedIMTextMessageRemovesOfflineQueuedMessage() async throws {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                throw URLError(.notConnectedToInternet)
            }
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                if case .signedIn = manager.phase {
                    return true
                }
                return false
            }
        }

        let didSend = await manager.sendIMText("cancel me", to: "conv-local")
        let message = try #require(manager.imConversationStore.selectedConversation?.messages.first)
        let didCancel = manager.cancelQueuedIMTextMessage(localMessageID: message.id, in: "conv-local")

        #expect(didSend)
        #expect(didCancel)
        #expect(manager.imConversationStore.selectedConversation?.messages.isEmpty == true)
        #expect(!manager.imConversationStore.queueSummary(for: "conv-local").hasPendingWork)
    }

    @Test func loginFlushesRestoredQueuedMessagesAfterGapSync() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let cache = InMemoryIMConversationCache()
        await cache.seed(
            IMConversationCacheSnapshot(
                conversations: [
                    IMCachedConversationState(
                        id: conversationIDString,
                        title: "缓存会话",
                        kind: .direct,
                        memberCount: 2,
                        memberUserIDs: [Self.user.id],
                        messages: [
                            IMCachedMessageState(
                                id: "queued-client-1",
                                conversationID: conversationIDString,
                                clientMessageID: "queued-client-1",
                                serverMessageID: nil,
                                senderUserID: Self.user.id,
                                serverSequence: nil,
                                kind: "text",
                                text: "恢复后发送",
                                direction: .outgoing,
                                createdAt: Date(timeIntervalSince1970: 1_700_100_000),
                                deliveryState: .queued(message: "等待 IM 长连接恢复后发送。")
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: "恢复后发送",
                        hasMoreHistory: false,
                        latestSyncedServerSequence: nil,
                        oldestLoadedServerSequence: nil,
                        serverLastReadSequence: 0,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                    )
                ],
                selectedConversationID: conversationIDString,
                lastSummaryRefreshAt: nil
            ),
            for: Self.user.id
        )

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        [
                            IMConversationSummaryResponseBody(
                                id: conversationID,
                                title: "服务端会话",
                                kind: IMConversationKind.direct.rawValue,
                                memberCount: 2,
                                memberUserIDs: [Self.user.id],
                                lastMessage: nil,
                                createdAt: Date(timeIntervalSince1970: 1_700_090_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                            )
                        ]
                    )
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            imConversationCache: IMConversationCacheHandler(cache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        let messageLine = try await Self.requireRecordedLine(at: 0, from: harness)
        let messagePacket = try Self.decode(IMTCPPacketEnvelope<IMTCPMessagePayload>.self, from: messageLine)
        #expect(messagePacket.type == .message)
        #expect(messagePacket.payload.conversationID == conversationIDString)
        #expect(messagePacket.payload.clientMessageID == "queued-client-1")
        #expect(messagePacket.payload.body["text"] == "恢复后发送")
    }

    @Test func queuedFlushPublishesProgressAndClearsWhenFinished() async throws {
        let harness = IMConnectionTestHarness(sendDelayNanoseconds: 200_000_000)
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let cache = InMemoryIMConversationCache()
        await cache.seed(
            IMConversationCacheSnapshot(
                conversations: [
                    IMCachedConversationState(
                        id: conversationIDString,
                        title: "缓存会话",
                        kind: .direct,
                        memberCount: 2,
                        memberUserIDs: [Self.user.id],
                        messages: [
                            IMCachedMessageState(
                                id: "queued-client-1",
                                conversationID: conversationIDString,
                                clientMessageID: "queued-client-1",
                                serverMessageID: nil,
                                senderUserID: Self.user.id,
                                serverSequence: nil,
                                kind: "text",
                                text: "恢复后发送",
                                direction: .outgoing,
                                createdAt: Date(timeIntervalSince1970: 1_700_100_000),
                                deliveryState: .queued(message: "等待 IM 长连接恢复后发送。")
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: "恢复后发送",
                        hasMoreHistory: false,
                        latestSyncedServerSequence: nil,
                        oldestLoadedServerSequence: nil,
                        serverLastReadSequence: 0,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                    )
                ],
                selectedConversationID: conversationIDString,
                lastSummaryRefreshAt: nil
            ),
            for: Self.user.id
        )

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        [
                            IMConversationSummaryResponseBody(
                                id: conversationID,
                                title: "服务端会话",
                                kind: IMConversationKind.direct.rawValue,
                                memberCount: 2,
                                memberUserIDs: [Self.user.id],
                                lastMessage: nil,
                                createdAt: Date(timeIntervalSince1970: 1_700_090_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                            )
                        ]
                    )
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            imConversationCache: IMConversationCacheHandler(cache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.isFlushingQueuedIMTextMessages
            }
        }
        _ = try await Self.requireRecordedLine(at: 0, from: harness)
        try await Self.waitUntil {
            await MainActor.run {
                !manager.isFlushingQueuedIMTextMessages
            }
        }
    }

    @Test func queuedFlushFailureMakesInFlightUnknownAndLeavesUnsentQueued() async throws {
        let harness = IMConnectionTestHarness(failingSendNumbers: [1])
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let cache = InMemoryIMConversationCache()
        await cache.seed(
            IMConversationCacheSnapshot(
                conversations: [
                    IMCachedConversationState(
                        id: conversationIDString,
                        title: "缓存会话",
                        kind: .direct,
                        memberCount: 2,
                        memberUserIDs: [Self.user.id],
                        messages: [
                            IMCachedMessageState(
                                id: "queued-client-1",
                                conversationID: conversationIDString,
                                clientMessageID: "queued-client-1",
                                serverMessageID: nil,
                                senderUserID: Self.user.id,
                                serverSequence: nil,
                                kind: "text",
                                text: "第一条",
                                direction: .outgoing,
                                createdAt: Date(timeIntervalSince1970: 1_700_100_000),
                                deliveryState: .queued(message: "等待 IM 长连接恢复后发送。")
                            ),
                            IMCachedMessageState(
                                id: "queued-client-2",
                                conversationID: conversationIDString,
                                clientMessageID: "queued-client-2",
                                serverMessageID: nil,
                                senderUserID: Self.user.id,
                                serverSequence: nil,
                                kind: "text",
                                text: "第二条",
                                direction: .outgoing,
                                createdAt: Date(timeIntervalSince1970: 1_700_100_001),
                                deliveryState: .queued(message: "等待 IM 长连接恢复后发送。")
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: "第二条",
                        hasMoreHistory: false,
                        latestSyncedServerSequence: nil,
                        oldestLoadedServerSequence: nil,
                        serverLastReadSequence: 0,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 1_700_100_001)
                    )
                ],
                selectedConversationID: conversationIDString,
                lastSummaryRefreshAt: nil
            ),
            for: Self.user.id
        )

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        [
                            IMConversationSummaryResponseBody(
                                id: conversationID,
                                title: "服务端会话",
                                kind: IMConversationKind.direct.rawValue,
                                memberCount: 2,
                                memberUserIDs: [Self.user.id],
                                lastMessage: nil,
                                createdAt: Date(timeIntervalSince1970: 1_700_090_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                            )
                        ]
                    )
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            imConversationCache: IMConversationCacheHandler(cache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.map(\.deliveryState) == [
                    .unknown(message: "发送状态未确认，请重试。"),
                    .queued(message: "等待 IM 长连接恢复后发送。")
                ]
            }
        }
        let summary = manager.imConversationStore.queueSummary(for: conversationIDString)
        #expect(summary.queuedCount == 1)
        #expect(summary.retryableIssueCount == 1)
    }

    @Test func loginLoadsServerConversationListAndHistory() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(conversationID: conversationID)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.id == conversationID.uuidString
                    && manager.imConversationStore.selectedConversation?.messages.count == 1
            }
        }

        let conversation = manager.imConversationStore.selectedConversation
        #expect(conversation?.title == "服务端会话")
        #expect(conversation?.members.map(\.email) == ["manager@example.com", "peer@example.com"])
        #expect(conversation?.messages.first?.text == "来自历史接口")
    }

    @Test func addIMConversationMembersRefreshesSummaryAndMembers() async throws {
        let mutationState = IMConversationMutationState()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                let summary = IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "服务端群聊",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: await mutationState.isMutated() ? 3 : 2,
                    memberUserIDs: [Self.user.id],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
                )
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody([summary])
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                let members = await mutationState.isMutated()
                    ? [
                        IMConversationMemberResponseBody(id: Self.user.id, email: Self.user.email),
                        IMConversationMemberResponseBody(
                            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                            email: "peer@example.com"
                        ),
                        IMConversationMemberResponseBody(
                            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                            email: "new@example.com"
                        )
                    ]
                    : [
                        IMConversationMemberResponseBody(id: Self.user.id, email: Self.user.email),
                        IMConversationMemberResponseBody(
                            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                            email: "peer@example.com"
                        )
                    ]
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(members)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/members"):
                let payload = try JSONDecoder().decode(
                    IMConversationMemberUpdateRequestBody.self,
                    from: request.httpBody ?? Data()
                )
                #expect(payload.memberEmails == ["new@example.com"])
                await mutationState.markMutated()
                let updatedSummary = IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "服务端群聊",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 3,
                    memberUserIDs: [Self.user.id],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_001_100)
                )
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(updatedSummary)
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.id == conversationID.uuidString
                    && manager.imConversationStore.selectedConversation?.memberCount == 2
                    && manager.imConversationStore.selectedConversation?.members.count == 2
            }
        }

        let didAdd = await manager.addIMConversationMembers(
            to: conversationID.uuidString,
            memberEmails: ["  NEW@example.com  ", "new@example.com"]
        )

        #expect(didAdd)
        #expect(manager.imConversationStore.selectedConversation?.kind == .group)
        #expect(manager.imConversationStore.selectedConversation?.memberCount == 3)
        #expect(manager.imConversationStore.selectedConversation?.members.map(\.email) == [
            "manager@example.com",
            "peer@example.com",
            "new@example.com"
        ])
    }

    @Test func leaveIMConversationRemovesCurrentConversationAndFallsBackToListSelection() async throws {
        let mutationState = IMConversationMutationState()
        let currentConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let fallbackConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                let summaries = await mutationState.isMutated()
                    ? [
                        IMConversationSummaryResponseBody(
                            id: fallbackConversationID,
                            title: "剩余会话",
                            kind: IMConversationKind.direct.rawValue,
                            memberCount: 2,
                            memberUserIDs: [Self.user.id],
                            lastMessage: nil,
                            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                            updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
                        )
                    ]
                    : [
                        IMConversationSummaryResponseBody(
                            id: currentConversationID,
                            title: "当前群聊",
                            kind: IMConversationKind.group.rawValue,
                            memberCount: 3,
                            memberUserIDs: [Self.user.id],
                            lastMessage: nil,
                            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                            updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
                        ),
                        IMConversationSummaryResponseBody(
                            id: fallbackConversationID,
                            title: "剩余会话",
                            kind: IMConversationKind.direct.rawValue,
                            memberCount: 2,
                            memberUserIDs: [Self.user.id],
                            lastMessage: nil,
                            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                            updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
                        )
                    ]
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(summaries)
                )
            case ("GET", "/api/im/conversations/\(currentConversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(currentConversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("POST", "/api/im/conversations/\(currentConversationID.uuidString)/leave"):
                await mutationState.markMutated()
                return HTTPFixtures.response(statusCode: 200, body: Data())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == currentConversationID.uuidString
                    && manager.imConversationStore.conversations.count == 2
            }
        }

        let didLeave = await manager.leaveIMConversation(currentConversationID.uuidString)

        #expect(didLeave)
        #expect(manager.imConversationStore.conversations.count == 1)
        #expect(manager.imConversationStore.conversations.first?.id == fallbackConversationID.uuidString)
        #expect(manager.imConversationStore.selectedConversationID == fallbackConversationID.uuidString)
    }

    @Test func conversationRemovedForSelfEventRemovesCurrentSelectionWithoutSummaryRefresh() async throws {
        let harness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let currentConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let fallbackConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                await requestCounter.increment("conversations")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        [
                            IMConversationSummaryResponseBody(
                                id: currentConversationID,
                                title: "Current",
                                memberUserIDs: [Self.user.id],
                                lastMessage: nil,
                                createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                                updatedAt: Date(timeIntervalSince1970: 1_700_300_001)
                            ),
                            IMConversationSummaryResponseBody(
                                id: fallbackConversationID,
                                title: "Fallback",
                                memberUserIDs: [Self.user.id],
                                lastMessage: nil,
                                createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_300_000)
                            )
                        ]
                    )
                )
            case ("GET", "/api/im/conversations/\(currentConversationID.uuidString)/members", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationMembersBody())
            case ("GET", "/api/im/conversations/\(currentConversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: currentConversationID)
                )
            case ("POST", "/api/im/conversations/\(currentConversationID.uuidString)/read", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(currentConversationID.uuidString)/messages/since", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == currentConversationID.uuidString
                    && manager.imConnectionStatus == .connected
            }
        }

        let initialConversationRequests = await requestCounter.count(for: "conversations")
        await harness.yield(
            .conversationEvent(
                requestID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
                payload: IMTCPConversationEventPayload(
                    eventType: .conversationRemovedForSelf,
                    conversation: IMConversationSummaryResponseBody(
                        id: currentConversationID,
                        title: "Current",
                        memberUserIDs: [Self.user.id],
                        lastMessage: nil,
                        createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                        updatedAt: Date(timeIntervalSince1970: 1_700_300_001)
                    ),
                    actorUserID: Self.user.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_400_000)
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == fallbackConversationID.uuidString
                    && manager.imConversationStore.conversations.count == 1
            }
        }

        #expect(await requestCounter.count(for: "conversations") == initialConversationRequests)
        #expect(manager.imConversationStore.conversations.first?.id == fallbackConversationID.uuidString)
    }

    @Test func reconnectIMConnectionSyncsConversationGap() async throws {
        let harness = IMConnectionTestHarness()
        let gapCounter = IMGapSyncCounter()
        let summarySequenceState = IMSummarySequenceState()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        latestServerSequence: await summarySequenceState.currentLatestServerSequence()
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since", "afterSequence=1&limit=100"):
                await gapCounter.increment()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesSinceBody(conversationID: conversationID)
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        await summarySequenceState.setLatestServerSequence(1)
        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 1
                    && manager.imConnectionStatus == .connected
            }
        }

        await summarySequenceState.setLatestServerSequence(2)
        await manager.reconnectIMConnection()
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 2
                    && manager.imConversationStore.selectedConversation?.messages.last?.text == "来自补洞接口"
                    && manager.imConnectionStatus == .connected
            }
        }

        #expect(await gapCounter.currentValue() >= 1)
    }

    @Test func openIMConversationSyncsGapForLoadedConversation() async throws {
        let harness = IMConnectionTestHarness()
        let gapCounter = IMGapSyncCounter()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(conversationID: conversationID)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since", "afterSequence=1&limit=100"):
                await gapCounter.increment()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesSinceBody(conversationID: conversationID)
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 1
            }
        }

        await manager.openIMConversation(conversationID.uuidString)
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 2
                    && manager.imConversationStore.selectedConversation?.messages.last?.text == "来自补洞接口"
            }
        }

        #expect(await gapCounter.currentValue() >= 1)
    }

    @Test func gapSyncFailureDoesNotClearLoadedMessages() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(conversationID: conversationID)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since", "afterSequence=1&limit=100"):
                throw URLError(.timedOut)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 1
            }
        }

        await manager.openIMConversation(conversationID.uuidString)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(manager.phase == .signedIn(Self.user))
        #expect(manager.currentUser?.id == Self.user.id)
        #expect(manager.imConversationStore.selectedConversation?.messages.count == 1)
        #expect(manager.imConversationStore.selectedConversation?.messages.first?.text == "来自历史接口")
        #expect(manager.imConversationStore.statusMessage == "请求超时，请稍后重试。")
        #expect(manager.serverStatus == .offline(message: "请求超时，请稍后重试。"))
    }

    @Test func reconnectIMConnectionLoopsGapSyncUntilFullyCaughtUp() async throws {
        let harness = IMConnectionTestHarness()
        let gapCounter = IMGapSyncCounter()
        let summarySequenceState = IMSummarySequenceState()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        latestServerSequence: await summarySequenceState.currentLatestServerSequence()
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since", "afterSequence=1&limit=100"):
                await gapCounter.increment()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesSincePageBody(
                        conversationID: conversationID,
                        messages: [
                            IMConversationMessageResponseBody(
                                id: UUID(uuidString: "ffffffff-1111-2222-3333-eeeeeeeeeeee")!,
                                conversationID: conversationID,
                                senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                                clientMessageID: "client-gap-2",
                                serverSequence: 2,
                                kind: "text",
                                body: ["text": "gap-2"],
                                createdAt: Date(timeIntervalSince1970: 1_700_001_100)
                            )
                        ],
                        hasMore: true,
                        nextAfterSequence: 2
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since", "afterSequence=2&limit=100"):
                await gapCounter.increment()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesSincePageBody(
                        conversationID: conversationID,
                        messages: [
                            IMConversationMessageResponseBody(
                                id: UUID(uuidString: "aaaaaaaa-9999-2222-3333-eeeeeeeeeeee")!,
                                conversationID: conversationID,
                                senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                                clientMessageID: "client-gap-3",
                                serverSequence: 3,
                                kind: "text",
                                body: ["text": "gap-3"],
                                createdAt: Date(timeIntervalSince1970: 1_700_001_200)
                            )
                        ],
                        hasMore: false,
                        nextAfterSequence: 3
                    )
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        await summarySequenceState.setLatestServerSequence(1)
        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.map(\.text) == ["来自历史接口"]
                    && manager.imConnectionStatus == .connected
            }
        }
        await summarySequenceState.setLatestServerSequence(3)
        await manager.reconnectIMConnection()
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.map(\.text) == ["来自历史接口", "gap-2", "gap-3"]
            }
        }

        #expect(await gapCounter.currentValue() >= 2)
        #expect(manager.imConversationStore.selectedConversation?.messages.map(\.serverSequence) == [1, 2, 3])
    }

    @Test func reconnectIMConnectionSkipsGapSyncWhenSummarySequenceIsNotAhead() async throws {
        let harness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                await requestCounter.increment("conversations")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(conversationID: conversationID)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members", _):
                await requestCounter.increment("members")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages", _):
                await requestCounter.increment("messages")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read", _):
                await requestCounter.increment("markRead")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since", "afterSequence=1&limit=100"):
                await requestCounter.increment("messagesSince")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.emptyMessagesSinceBody()
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 1
                    && manager.imConnectionStatus == .connected
            }
        }
        try await Self.waitUntil {
            await requestCounter.count(for: "markRead") >= 1
        }

        let initialConversationRequests = await requestCounter.count(for: "conversations")
        let initialMemberRequests = await requestCounter.count(for: "members")
        let initialMessageRequests = await requestCounter.count(for: "messages")
        let initialMarkReadRequests = await requestCounter.count(for: "markRead")

        await manager.reconnectIMConnection()
        try await Self.waitUntil {
            let isConnected = await MainActor.run { manager.imConnectionStatus == .connected }
            let didRefreshSummaries = await requestCounter.count(for: "conversations") > initialConversationRequests
            return isConnected && didRefreshSummaries
        }

        #expect(await requestCounter.count(for: "messagesSince") == 0)
        #expect(await requestCounter.count(for: "markRead") == initialMarkReadRequests)
        #expect(await requestCounter.count(for: "members") == initialMemberRequests)
        #expect(await requestCounter.count(for: "messages") == initialMessageRequests)
    }

    @Test func loginBootstrapAppliesServerUnreadCountToBackgroundConversationSummary() async throws {
        let harness = IMConnectionTestHarness()
        let selectedConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let backgroundConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        [
                            IMConversationSummaryResponseBody(
                                id: selectedConversationID,
                                title: "selected",
                                memberUserIDs: [Self.user.id],
                                lastMessage: IMMessagePreviewResponseBody(
                                    id: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!,
                                    senderUserID: Self.user.id,
                                    serverSequence: 1,
                                    kind: "text",
                                    body: ["text": "selected preview"],
                                    createdAt: Date(timeIntervalSince1970: 1_700_001_000)
                                ),
                                lastReadSequence: 1,
                                unreadCount: 0,
                                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_001_600)
                            ),
                            IMConversationSummaryResponseBody(
                                id: backgroundConversationID,
                                title: "background",
                                memberUserIDs: [Self.user.id],
                                lastMessage: IMMessagePreviewResponseBody(
                                    id: UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!,
                                    senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                                    serverSequence: 8,
                                    kind: "text",
                                    body: ["text": "background preview"],
                                    createdAt: Date(timeIntervalSince1970: 1_700_001_500)
                                ),
                                lastReadSequence: 5,
                                unreadCount: 3,
                                createdAt: Date(timeIntervalSince1970: 1_700_000_500),
                                updatedAt: Date(timeIntervalSince1970: 1_700_001_500)
                            )
                        ]
                    )
                )
            case ("GET", "/api/im/conversations/\(selectedConversationID.uuidString)/members", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.emptyMembersBody()
                )
            case ("GET", "/api/im/conversations/\(selectedConversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.emptyMessagesBody()
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.conversations.count == 2
                    && manager.imConversationStore.conversations.first(where: { $0.id == backgroundConversationID.uuidString })?.serverUnreadCount == 3
            }
        }

        let backgroundConversation = manager.imConversationStore.conversations.first {
            $0.id == backgroundConversationID.uuidString
        }
        #expect(backgroundConversation?.serverLastReadSequence == 5)
        #expect(backgroundConversation?.serverUnreadCount == 3)
        #expect(backgroundConversation?.unreadCount == 3)
    }

    @Test func loginRestoresCachedConversationBeforeNetworkRefreshAndThenAppliesServerSummary() async throws {
        let harness = IMConnectionTestHarness()
        let gate = RestoreGate()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let cache = InMemoryIMConversationCache()

        await cache.seed(
            IMConversationCacheSnapshot(
                conversations: [
                    IMCachedConversationState(
                        id: conversationIDString,
                        title: "缓存会话",
                        kind: .group,
                        memberCount: 2,
                        memberUserIDs: [Self.user.id],
                        messages: [
                            IMCachedMessageState(
                                id: "cached-message-1",
                                conversationID: conversationIDString,
                                clientMessageID: "cached-client-1",
                                serverMessageID: "cached-server-1",
                                senderUserID: Self.user.id,
                                serverSequence: 7,
                                kind: "text",
                                text: "来自缓存",
                                direction: .outgoing,
                                createdAt: Date(timeIntervalSince1970: 1_700_100_000),
                                deliveryState: .sent
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: "来自缓存",
                        hasMoreHistory: true,
                        latestSyncedServerSequence: 7,
                        oldestLoadedServerSequence: 7,
                        serverLastReadSequence: 7,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                    )
                ],
                selectedConversationID: conversationIDString,
                lastSummaryRefreshAt: Date(timeIntervalSince1970: 1_700_100_100)
            ),
            for: Self.user.id
        )

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                await gate.markStarted()
                await gate.waitForResume()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        [
                            IMConversationSummaryResponseBody(
                                id: conversationID,
                                title: "服务端会话",
                                kind: IMConversationKind.direct.rawValue,
                                memberCount: 3,
                                memberUserIDs: [Self.user.id],
                                lastMessage: IMMessagePreviewResponseBody(
                                    id: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!,
                                    senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                                    serverSequence: 8,
                                    kind: "text",
                                    body: ["text": "服务端预览"],
                                    createdAt: Date(timeIntervalSince1970: 1_700_100_200)
                                ),
                                lastReadSequence: 7,
                                unreadCount: 1,
                                createdAt: Date(timeIntervalSince1970: 1_700_090_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_100_200)
                            )
                        ]
                    )
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            imConversationCache: IMConversationCacheHandler(cache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        await gate.waitUntilStarted()
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.title == "缓存会话"
                    && manager.imConversationStore.selectedConversation?.messages.map { $0.text } == ["来自缓存"]
                    && manager.imConversationStore.latestLoadedServerSequence(for: conversationIDString) == 7
            }
        }

        await gate.resume()
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.title == "服务端会话"
                    && manager.imConversationStore.selectedConversation?.kind == .direct
                    && manager.imConversationStore.selectedConversation?.memberCount == 3
                    && manager.imConversationStore.selectedConversation?.serverUnreadCount == 1
            }
        }

        #expect(manager.imConversationStore.selectedConversationID == conversationIDString)
        #expect(manager.imConversationStore.selectedConversation?.messages.map { $0.text } == ["来自缓存"])
        #expect(manager.imConversationStore.hasLoadedMessages(for: conversationIDString))
        #expect(manager.imConversationStore.latestLoadedServerSequence(for: conversationIDString) == 7)
        #expect(manager.imConversationStore.oldestLoadedServerSequence(for: conversationIDString) == 7)
    }

    @Test func loginContinuesWithNetworkBootstrapWhenConversationCacheLoadFails() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        [
                            IMConversationSummaryResponseBody(
                                id: conversationID,
                                title: "网络会话",
                                kind: IMConversationKind.group.rawValue,
                                memberCount: 2,
                                memberUserIDs: [Self.user.id],
                                lastMessage: nil,
                                createdAt: Date(timeIntervalSince1970: 1_700_090_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                            )
                        ]
                    )
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            imConversationCache: IMConversationCacheHandler(FailingLoadIMConversationCache()),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.title == "网络会话"
                    && manager.imConversationStore.selectedConversationID == conversationID.uuidString
            }
        }

        #expect(manager.imConversationStore.conversations.count == 1)
    }

    private func makeManager(
        transport: MockHTTPTransport,
        openIMConnection: (@Sendable () async throws -> IMTCPConnection)? = nil,
        imConversationCache: IMConversationCacheHandler = IMConversationCacheHandler(NoopIMConversationCache()),
        wrapDefaultIMResponses: Bool = true
    ) -> AuthManager {
        return AuthManager(
            httpClient: HTTPClient(
                baseURL: HTTPFixtures.baseURL,
                transport: wrapDefaultIMResponses ? wrapWithDefaultIMResponses(transport) : transport
            ),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: openIMConnection,
            imConversationCache: imConversationCache,
            shouldRestoreSession: false
        )
    }

    private func wrapWithDefaultIMResponses(_ transport: MockHTTPTransport) -> MockHTTPTransport {
        MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/members") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/messages/since") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/messages") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("POST", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/read") == true:
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            default:
                return try await transport.send(request)
            }
        }
    }

    private nonisolated static func authResponseBody() throws -> Data {
        try authResponseBody(
            user: user,
            accessToken: "access-1",
            refreshToken: "refresh-1"
        )
    }

    private nonisolated static func authResponseBody(
        user: AuthUser,
        accessToken: String,
        refreshToken: String
    ) throws -> Data {
        try HTTPFixtures.jsonBody(
            AuthResponseBody(
                accessToken: accessToken,
                expiresIn: 600,
                refreshToken: refreshToken,
                refreshExpiresIn: 30 * 24 * 60 * 60,
                user: user
            )
        )
    }

    private nonisolated static func emptyConversationsBody() throws -> Data {
        try HTTPFixtures.jsonBody([IMConversationSummaryResponseBody]())
    }

    private nonisolated static func emptyMessagesBody() throws -> Data {
        try HTTPFixtures.jsonBody([IMConversationMessageResponseBody]())
    }

    private nonisolated static func emptyMessagesSinceBody() throws -> Data {
        try HTTPFixtures.jsonBody(
            IMConversationMessagesSinceResponseBody(
                messages: [],
                hasMore: false,
                nextAfterSequence: nil
            )
        )
    }

    private nonisolated static func emptyMembersBody() throws -> Data {
        try HTTPFixtures.jsonBody([IMConversationMemberResponseBody]())
    }

    private nonisolated static func imConversationReadBody(
        conversationID: UUID,
        lastReadSequence: Int,
        unreadCount: Int = 0
    ) throws -> Data {
        try HTTPFixtures.jsonBody(
            IMConversationReadResponseBody(
                conversationID: conversationID,
                lastReadSequence: lastReadSequence,
                unreadCount: unreadCount
            )
        )
    }

    private nonisolated static func imConversationReadBody(for request: URLRequest) throws -> Data {
        guard let path = request.url?.path else {
            throw URLError(.badURL)
        }

        let components = path.split(separator: "/")
        guard
            let conversationsIndex = components.firstIndex(of: "conversations"),
            components.indices.contains(components.index(after: conversationsIndex)),
            let conversationID = UUID(uuidString: String(components[components.index(after: conversationsIndex)]))
        else {
            throw URLError(.badURL)
        }

        let payload = try JSONDecoder().decode(
            IMConversationReadRequestBody.self,
            from: request.httpBody ?? Data()
        )
        return try imConversationReadBody(
            conversationID: conversationID,
            lastReadSequence: Int(payload.readSequence)
        )
    }

    private nonisolated static func imConversationsBody(
        conversationID: UUID,
        latestServerSequence: Int = 1
    ) throws -> Data {
        try HTTPFixtures.jsonBody(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "服务端会话",
                    memberUserIDs: [user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!,
                        senderUserID: user.id,
                        serverSequence: latestServerSequence,
                        kind: "text",
                        body: ["text": latestServerSequence == 1 ? "来自历史接口" : "服务端摘要更新"],
                        createdAt: Date(timeIntervalSince1970: 1_700_001_000 + Double(latestServerSequence - 1))
                    ),
                    lastReadSequence: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_001_000 + Double(latestServerSequence - 1))
                )
            ]
        )
    }

    private nonisolated static func imMessagesBody(conversationID: UUID) throws -> Data {
        try HTTPFixtures.jsonBody(
            [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!,
                    conversationID: conversationID,
                    senderUserID: user.id,
                    clientMessageID: "client-history-1",
                    serverSequence: 1,
                    kind: "text",
                    body: ["text": "来自历史接口"],
                    createdAt: Date(timeIntervalSince1970: 1_700_001_000)
                )
            ]
        )
    }

    private nonisolated static func imMessagesSinceBody(conversationID: UUID) throws -> Data {
        try imMessagesSincePageBody(
            conversationID: conversationID,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "ffffffff-1111-2222-3333-eeeeeeeeeeee")!,
                    conversationID: conversationID,
                    senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    clientMessageID: "client-gap-2",
                    serverSequence: 2,
                    kind: "text",
                    body: ["text": "来自补洞接口"],
                    createdAt: Date(timeIntervalSince1970: 1_700_001_100)
                )
            ],
            hasMore: false,
            nextAfterSequence: 2
        )
    }

    private nonisolated static func imMessagesSincePageBody(
        conversationID: UUID,
        messages: [IMConversationMessageResponseBody],
        hasMore: Bool,
        nextAfterSequence: Int?
    ) throws -> Data {
        _ = conversationID
        return try HTTPFixtures.jsonBody(
            IMConversationMessagesSinceResponseBody(
                messages: messages,
                hasMore: hasMore,
                nextAfterSequence: nextAfterSequence
            )
        )
    }

    private nonisolated static func imConversationMembersBody() throws -> Data {
        try HTTPFixtures.jsonBody(
            [
                IMConversationMemberResponseBody(
                    id: user.id,
                    email: user.email
                ),
                IMConversationMemberResponseBody(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    email: "peer@example.com"
                )
            ]
        )
    }

    private nonisolated static func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<50 {
            if await predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        Issue.record("等待状态变化超时。")
        throw IMTCPClientError.connectionClosed
    }

    private nonisolated static func requireRecordedLine(
        at index: Int,
        from harness: IMConnectionTestHarness
    ) async throws -> String {
        for _ in 0..<50 {
            let lines = await harness.recordedLines()
            if lines.indices.contains(index) {
                return lines[index]
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        Issue.record("等待第 \(index) 条 IM 发送数据超时。")
        throw IMTCPClientError.connectionClosed
    }

    private nonisolated static func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(line.utf8))
    }
}

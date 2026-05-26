import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

@Suite(.serialized)
@MainActor
struct AuthManagerTests {
    nonisolated static let user = AuthUser(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        email: "manager@example.com"
    )

    @Test func loginSuccessSetsOnlineAuthRouteState() async {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = makeManager(transport: transport)
        await manager.login(email: Self.user.email, password: "password123")

        #expect(manager.sessionStore.authRouteState == .signedIn(Self.user, availability: .online))
        #expect(manager.sessionStore.authOperationState == .idle)
        #expect(manager.sessionStore.authNotice == nil)
    }

    @Test func registerSuccessSetsOnlineAuthRouteState() async {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/register"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.registerSignedInBody())
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = makeManager(transport: transport)
        await manager.register(email: Self.user.email, password: "password123")

        #expect(manager.sessionStore.authRouteState == .signedIn(Self.user, availability: .online))
        #expect(manager.sessionStore.authOperationState == .idle)
        #expect(manager.sessionStore.authNotice == nil)
    }

    @Test func restoreOfflineSetsSignedInOfflineAuthRouteState() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()
        try tokenStore.save("refresh-1", for: "refresh_token")
        userCache.save(Self.user)

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/refresh"),
                 ("GET", "/api/contacts"),
                 ("GET", "/api/contact-requests"),
                 ("GET", "/api/blocks"):
                throw URLError(.notConnectedToInternet)
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: tokenStore,
            userCache: userCache,
            shouldRestoreSession: false
        )

        await manager.restoreSession()

        #expect(manager.sessionStore.authRouteState == .signedIn(
            Self.user,
            availability: .offline(message: "当前无法连接服务器。")
        ))
        #expect(manager.sessionStore.authOperationState == .idle)
    }

    @Test func loadSessionsMarksServerOfflineWhenConnectivityFails() async {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/auth/sessions"):
                throw URLError(.notConnectedToInternet)
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
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
                return try Self.defaultOrUnexpectedIMResponse(for: request)
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

        #expect(manager.sessionStore.authRouteState == .signedIn(Self.user, availability: .online))
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
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = makeManager(transport: transport)
        await manager.login(email: Self.user.email, password: "password123")
        await manager.loadSessions()

        #expect(manager.sessionStore.authRouteState == .signedOut(AuthNotice(
            code: .sessionRevoked,
            message: "当前登录已失效。",
            severity: .error,
            isRecoverable: false
        )))
        #expect(manager.sessionStore.authNotice?.code == .sessionRevoked)
        #expect(manager.sessionStore.authOperationState == .idle)
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
                return try Self.defaultOrUnexpectedIMResponse(for: request)
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
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = makeManager(transport: transport)
        await manager.login(email: Self.user.email, password: "password123")
        await manager.signOut(sessionID: targetSessionID, isCurrent: false)

        #expect(manager.sessionStore.authRouteState == .signedOut(AuthNotice(
            code: .forbidden,
            message: "当前设备已被撤销。",
            severity: .error,
            isRecoverable: false
        )))
        #expect(manager.serverStatus == .unknown)
        #expect(manager.currentUser == nil)
    }


    @Test func loginMarksServerOfflineWhenConnectivityFails() async {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                throw URLError(.notConnectedToInternet)
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = makeManager(transport: transport)
        await manager.login(email: Self.user.email, password: "password123")

        #expect(manager.sessionStore.authRouteState == .signedOut(AuthNotice(
            code: .offline,
            message: "当前无法连接服务器。",
            severity: .warning,
            isRecoverable: true
        )))
        #expect(manager.sessionStore.authNotice?.code == .offline)
        #expect(manager.sessionStore.authOperationState == .idle)
        #expect(manager.serverStatus == .offline(message: "当前无法连接服务器。"))
    }


    @Test func registerMarksServerOfflineWhenConnectivityFails() async {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/register"):
                throw URLError(.notConnectedToInternet)
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = makeManager(transport: transport)
        await manager.register(email: Self.user.email, password: "password123")

        #expect(manager.sessionStore.authRouteState == .signedOut(AuthNotice(
            code: .offline,
            message: "当前无法连接服务器。",
            severity: .warning,
            isRecoverable: true
        )))
        #expect(manager.sessionStore.authNotice?.code == .offline)
        #expect(manager.sessionStore.authOperationState == .idle)
        #expect(manager.serverStatus == .offline(message: "当前无法连接服务器。"))
    }


    @Test func recoveredBackgroundUnauthorizedFailureClearsSession() async {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
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

        #expect(manager.sessionStore.authRouteState == .signedOut(AuthNotice(
            code: .unknown,
            message: "请重新登录。",
            severity: .error,
            isRecoverable: false
        )))
        #expect(manager.serverStatus == .unknown)
        #expect(manager.currentUser == nil)
    }


    func makeManager(
        transport: MockHTTPTransport,
        fileTransferClient: FileTransferClient? = nil,
        openIMConnection: (@Sendable () async throws -> IMTCPConnection)? = nil,
        backgroundTransferMonitor: any BackgroundTransferMonitoring = BackgroundTransferCoordinator.shared,
        imConversationCache: IMConversationCacheHandler = IMConversationCacheHandler(NoopIMConversationCache()),
        contactStateCache: ContactStateCacheHandler = ContactStateCacheHandler(NoopContactStateCache()),
        wrapDefaultIMResponses: Bool = true
    ) -> AuthManager {
        return AuthManager(
            httpClient: HTTPClient(
                baseURL: HTTPFixtures.baseURL,
                transport: wrapDefaultIMResponses ? wrapWithDefaultIMResponses(transport) : transport
            ),
            fileTransferClient: fileTransferClient,
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: openIMConnection,
            backgroundTransferMonitor: backgroundTransferMonitor,
            imConversationCache: imConversationCache,
            contactStateCache: contactStateCache,
            shouldRestoreSession: false
        )
    }
    func wrapWithDefaultIMResponses(_ transport: MockHTTPTransport) -> MockHTTPTransport {
        MockHTTPTransport { request in
            if let response = try Self.defaultIMResponse(for: request) {
                return response
            }
            return try await transport.send(request)
        }
    }

    nonisolated static func defaultIMResponse(
        for request: URLRequest
    ) throws -> (Data, HTTPURLResponse)? {
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/api/contacts"):
            return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
        case ("GET", "/api/contact-requests"):
            return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
        case ("GET", "/api/blocks"):
            return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([UserBlockResponseBody]()))
        case ("GET", "/api/im/conversations"):
            return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
        case ("GET", "/api/im/conversations/changes"):
            return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationChangesBody())
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
        case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/receipts/summary") == true:
            return HTTPFixtures.response(
                statusCode: 200,
                body: try Self.imConversationReceiptSummaryBody(for: request)
            )
        case ("DELETE", "/api/auth/sessions/current"):
            return HTTPFixtures.response(statusCode: 200)
        default:
            return nil
        }
    }

    nonisolated static func defaultOrUnexpectedIMResponse(
        for request: URLRequest
    ) throws -> (Data, HTTPURLResponse) {
        if let response = try defaultIMResponse(for: request) {
            return response
        }
        Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
        return HTTPFixtures.response(statusCode: 500)
    }
    nonisolated static func authResponseBody() throws -> Data {
        try authResponseBody(
            user: user,
            accessToken: "access-1",
            refreshToken: "refresh-1"
        )
    }
    nonisolated static func authResponseBody(
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
    nonisolated static func registerSignedInBody() throws -> Data {
        try HTTPFixtures.jsonBody(
            RegisterResponseBody(
                state: .signedIn,
                auth: AuthResponseBody(
                    accessToken: "access-1",
                    expiresIn: 600,
                    refreshToken: "refresh-1",
                    refreshExpiresIn: 30 * 24 * 60 * 60,
                    user: user
                ),
                email: nil,
                expiresIn: nil,
                message: nil
            )
        )
    }
    nonisolated static func emptyConversationsBody() throws -> Data {
        try HTTPFixtures.jsonBody(
            IMConversationSummaryPageResponseBody(
                items: [],
                nextCursor: nil,
                hasMore: false,
                snapshotToken: "snapshot-empty"
            )
        )
    }
    nonisolated static func emptyMessagesBody() throws -> Data {
        try HTTPFixtures.jsonBody([IMConversationMessageResponseBody]())
    }
    nonisolated static func emptyConversationChangesBody() throws -> Data {
        try HTTPFixtures.jsonBody(
            IMConversationSummaryChangesResponseBody(
                upserts: [],
                removedConversationIDs: [],
                nextCursor: nil,
                hasMore: false,
                targetToken: "snapshot-empty"
            )
        )
    }
    nonisolated static func imConversationChangesBody(
        upserts: [IMConversationSummaryResponseBody],
        removedConversationIDs: [UUID] = [],
        targetToken: String = "snapshot-changes"
    ) throws -> Data {
        try HTTPFixtures.jsonBody(
            IMConversationSummaryChangesResponseBody(
                upserts: upserts,
                removedConversationIDs: removedConversationIDs,
                nextCursor: nil,
                hasMore: false,
                targetToken: targetToken
            )
        )
    }
    nonisolated static func emptyMessagesSinceBody() throws -> Data {
        try HTTPFixtures.jsonBody(
            IMConversationMessagesSinceResponseBody(
                messages: [],
                hasMore: false,
                nextAfterSequence: nil
            )
        )
    }
    nonisolated static func emptyMembersBody() throws -> Data {
        try imConversationMembersPageBody([])
    }

    nonisolated static func imConversationMembersPageBody(
        _ members: [IMConversationMemberResponseBody],
        nextCursor: String? = nil,
        limit: Int = 50
    ) throws -> Data {
        try HTTPFixtures.jsonBody(
            IMConversationMemberPageResponseBody(
                items: members,
                nextCursor: nextCursor,
                total: members.count,
                limit: limit
            )
        )
    }
    nonisolated static func imConversationReadBody(
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
    nonisolated static func imConversationReadBody(for request: URLRequest) throws -> Data {
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

    nonisolated static func imConversationReceiptSummaryBody(for request: URLRequest) throws -> Data {
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

        return try HTTPFixtures.jsonBody(
            IMConversationReceiptSummaryResponseBody(
                conversationID: conversationID,
                deliveredThroughSequence: 0,
                readThroughSequence: 0,
                readableMemberCount: 0
            )
        )
    }
    nonisolated static func imConversationsBody(
        conversationID: UUID,
        latestServerSequence: Int = 1,
        kind: IMConversationKind = .group,
        directMessagingState: String? = nil,
        memberUserIDs: [UUID] = [user.id],
        directPeer: IMDirectPeerResponseBody? = nil
    ) throws -> Data {
        try HTTPFixtures.jsonBody(
            IMConversationSummaryPageResponseBody(
                items: [
                    IMConversationSummaryResponseBody(
                        id: conversationID,
                        title: "服务端会话",
                        kind: kind.rawValue,
                        directMessagingState: directMessagingState,
                        directPeer: directPeer,
                        memberUserIDs: memberUserIDs,
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
                ],
                nextCursor: nil,
                hasMore: false,
                snapshotToken: "snapshot-\(conversationID.uuidString.lowercased())"
            )
        )
    }
    nonisolated static func imConversationSummaryPageBody(
        items: [IMConversationSummaryResponseBody],
        nextCursor: String?,
        hasMore: Bool,
        snapshotToken: String
    ) throws -> Data {
        try HTTPFixtures.jsonBody(
            IMConversationSummaryPageResponseBody(
                items: items,
                nextCursor: nextCursor,
                hasMore: hasMore,
                snapshotToken: snapshotToken
            )
        )
    }
    nonisolated static func imConversationSummary(
        id: UUID,
        latestServerSequence: Int,
        updatedAt: Date,
        title: String,
        kind: IMConversationKind = .group
    ) -> IMConversationSummaryResponseBody {
        IMConversationSummaryResponseBody(
            id: id,
            title: title,
            kind: kind.rawValue,
            memberUserIDs: [user.id],
            lastMessage: IMMessagePreviewResponseBody(
                id: UUID(),
                senderUserID: user.id,
                serverSequence: latestServerSequence,
                kind: "text",
                body: ["text": title],
                createdAt: updatedAt
            ),
            lastReadSequence: 0,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: updatedAt
        )
    }
    nonisolated static func imMessagesBody(conversationID: UUID) throws -> Data {
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
    nonisolated static func imMessagesSinceBody(conversationID: UUID) throws -> Data {
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
    nonisolated static func gapMessage(
        conversationID: UUID,
        serverSequence: Int
    ) -> IMConversationMessageResponseBody {
        IMConversationMessageResponseBody(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", serverSequence)) ?? UUID(),
            conversationID: conversationID,
            senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            clientMessageID: "client-gap-\(serverSequence)",
            serverSequence: serverSequence,
            kind: "text",
            body: ["text": "gap-\(serverSequence)"],
            createdAt: Date(timeIntervalSince1970: 1_700_001_000 + Double(serverSequence))
        )
    }
    nonisolated static func imMessagesSincePageBody(
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
    nonisolated static func afterSequence(from request: URLRequest) -> Int? {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return nil
        }

        return components.queryItems?
            .first(where: { $0.name == "afterSequence" })?
            .value
            .flatMap(Int.init)
    }
    nonisolated static func queuedConversationCacheSnapshot(
        conversationID: String,
        messageCount: Int
    ) -> IMConversationCacheSnapshot {
        let queuedMessages = (0..<messageCount).map { index in
            IMCachedMessageState(
                id: "queued-client-\(index + 1)",
                conversationID: conversationID,
                clientMessageID: "queued-client-\(index + 1)",
                serverMessageID: nil,
                senderUserID: user.id,
                serverSequence: nil,
                kind: "text",
                text: "排队消息-\(index + 1)",
                direction: .outgoing,
                createdAt: Date(timeIntervalSince1970: 1_700_100_000 + Double(index)),
                deliveryState: .queued(message: "等待 IM 长连接恢复后发送。")
            )
        }

        return IMConversationCacheSnapshot(
            conversations: [
                IMCachedConversationState(
                    id: conversationID,
                    title: "缓存会话",
                    kind: .direct,
                    memberCount: 2,
                    memberUserIDs: [user.id],
                    messages: queuedMessages,
                    hasLoadedMessages: true,
                    lastMessagePreviewText: queuedMessages.last?.text ?? "",
                    hasMoreHistory: false,
                    latestSyncedServerSequence: nil,
                    oldestLoadedServerSequence: nil,
                    serverLastReadSequence: 0,
                    serverUnreadCount: 0,
                    updatedAt: queuedMessages.last?.createdAt ?? Date(timeIntervalSince1970: 1_700_100_000)
                )
            ],
            selectedConversationID: conversationID,
            lastSummaryRefreshAt: nil
        )
    }
    nonisolated static func imConversationMembersBody() throws -> Data {
        try imConversationMembersPageBody(
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
    nonisolated static func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<1_000 {
            if await predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        Issue.record("等待状态变化超时。")
        throw IMTCPClientError.connectionClosed
    }
    nonisolated static func requireRecordedLine(
        at index: Int,
        from harness: IMConnectionTestHarness
    ) async throws -> String {
        for _ in 0..<1_000 {
            let lines = await harness.recordedLines()
            if lines.indices.contains(index) {
                return lines[index]
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        Issue.record("等待第 \(index) 条 IM 发送数据超时。")
        throw IMTCPClientError.connectionClosed
    }
    nonisolated static func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(line.utf8))
    }
}

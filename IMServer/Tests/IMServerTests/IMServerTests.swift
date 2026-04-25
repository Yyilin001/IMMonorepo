@testable import IMServer
import Fluent
import NIOCore
import Vapor
import VaporTesting
import Testing

@Suite("App Tests")
struct IMServerTests {
    let loginRequest = LoginRequest(
        email: "demo@example.com",
        password: "password1234",
        device: DeviceMetadata(
            deviceID: "simulator",
            deviceName: "Test Device",
            platform: "iOS",
            appVersion: "1.0"
        )
    )
    let registerRequest = RegisterRequest(
        email: "fresh@example.com",
        password: "password1234",
        device: DeviceMetadata(
            deviceID: "fresh-device",
            deviceName: "Fresh Device",
            platform: "iOS",
            appVersion: "1.0"
        )
    )

    @Test("Test Root Route Returns HTML")
    func rootRouteServesIndex() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "/", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.contentType?.type == "text")
                #expect(res.headers.contentType?.subType == "html")
                #expect(res.body.string.contains("Vapor Hello"))
            })
        }
    }

    @Test("Test Hello World Route")
    func helloWorld() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "hello", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "Hello, world!")
            })
        }
    }

    @Test("Test Hello Greet Route")
    func helloGreet() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "hello/greet/Codex", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "Hello, Codex!")
            })
        }
    }

    @Test("Test Hello Info Route")
    func helloInfo() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "hello/info", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.contentType?.subType == "json")
                #expect(res.body.string.contains("\"message\":\"Hello from Vapor\""))
                #expect(res.body.string.contains("\"availableRoutes\""))
                #expect(res.body.string.contains("greet"))
            })
        }
    }

    @Test("Test Hello Query Route")
    func helloQuery() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "hello/query?name=Taylor", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.contentType?.subType == "json")
                #expect(res.body.string.contains("\"greeting\":\"Hello, Taylor!\""))
            })
        }
    }

    @Test("Login returns an access token and user")
    func login() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let payload = try res.content.decode(AuthResponse.self)
                #expect(!payload.accessToken.isEmpty)
                #expect(!payload.refreshToken.isEmpty)
                #expect(payload.user.email == "demo@example.com")
            })
        }
    }

    @Test("Production requires an explicit JWT secret")
    func productionRequiresJWTSecret() throws {
        let originalJWTSecret = Environment.get("JWT_SECRET")
        defer { restoreEnvironment("JWT_SECRET", to: originalJWTSecret) }

        unsetenv("JWT_SECRET")

        do {
            _ = try AuthConfiguration.load(from: .production)
            Issue.record("Expected production auth configuration to fail without JWT_SECRET")
        } catch AuthConfigurationError.missingJWTSecret {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Login throttles repeated failed attempts per account")
    func loginRateLimit() async throws {
        try await withApp(configure: configure) { app in
            let invalidLogin = LoginRequest(
                email: "demo@example.com",
                password: "wrong-password",
                device: nil
            )

            for attempt in 1...5 {
                try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                    try req.content.encode(invalidLogin)
                }, afterResponse: { res async in
                    #expect(res.status == .unauthorized, "Attempt \(attempt) should still be unauthorized")
                })
            }

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(invalidLogin)
            }, afterResponse: { res async in
                #expect(res.status == .tooManyRequests)
                #expect(res.headers.first(name: .retryAfter) != nil)
            })
        }
    }

    @Test("Login limiter counts pending attempts atomically")
    func loginRateLimitCountsPendingAttempts() async throws {
        let limiter = AuthLoginRateLimiter()
        let now = Date()
        var reservations: [LoginAttemptReservation] = []

        for _ in 1...5 {
            let reservation = try await limiter.beginLoginAttempt(
                ipAddress: "198.51.100.10",
                account: "demo@example.com",
                now: now
            )
            reservations.append(reservation)
        }

        do {
            _ = try await limiter.beginLoginAttempt(
                ipAddress: "198.51.100.10",
                account: "demo@example.com",
                now: now
            )
            Issue.record("Expected pending attempts to exhaust the account rate limit")
        } catch is LoginRateLimitError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        for reservation in reservations {
            await limiter.completeLoginAttempt(reservation, succeeded: false, now: now)
        }
    }

    @Test("Register reuses the auth limiter and throttles repeated invalid attempts")
    func registerRateLimit() async throws {
        try await withApp(configure: configure) { app in
            let weakRegister = RegisterRequest(
                email: "duplicate@example.com",
                password: "short",
                device: nil
            )

            for attempt in 1...3 {
                try await app.testing().test(.POST, "api/auth/register", beforeRequest: { req in
                    try req.content.encode(weakRegister)
                }, afterResponse: { res async in
                    #expect(res.status == .badRequest, "Attempt \(attempt) should still be rejected as a bad request")
                })
            }

            try await app.testing().test(.POST, "api/auth/register", beforeRequest: { req in
                try req.content.encode(weakRegister)
            }, afterResponse: { res async in
                #expect(res.status == .tooManyRequests)
                #expect(res.headers.first(name: .retryAfter) != nil)
            })
        }
    }

    @Test("Disabled login returns the same external credential failure")
    func disabledLoginUsesGenericCredentialError() async throws {
        try await withApp(configure: configure) { app in
            guard let user = try await User.query(on: app.db)
                .filter(\.$email == "demo@example.com")
                .first()
            else {
                Issue.record("Missing demo user")
                return
            }

            user.status = UserStatus.disabled.rawValue
            try await user.update(on: app.db)

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
                #expect(res.body.string.contains("邮箱或密码错误"))
                #expect(!res.body.string.contains("禁用"))
            })
        }
    }

    @Test("Client IP resolver trusts forwarded headers only from configured proxies")
    func trustedProxyClientIPResolution() {
        let resolver = AuthClientIPResolver(trustedProxyIPs: ["10.0.0.1"])
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .xForwardedFor, value: "203.0.113.10, 10.0.0.1")

        let proxiedClientIP = resolver.resolveClientIPAddress(
            remoteIPAddress: "10.0.0.1",
            headers: headers
        )
        #expect(proxiedClientIP == "203.0.113.10")

        let directClientIP = resolver.resolveClientIPAddress(
            remoteIPAddress: "198.51.100.42",
            headers: headers
        )
        #expect(directClientIP == "198.51.100.42")
    }

    @Test("Refresh rotates the refresh token")
    func refresh() async throws {
        try await withApp(configure: configure) { app in
            var initialTokens: AuthResponse?

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async throws in
                initialTokens = try res.content.decode(AuthResponse.self)
            })

            guard let initialTokens else {
                Issue.record("Missing login response")
                return
            }

            try await app.testing().test(.POST, "api/auth/refresh", beforeRequest: { req in
                try req.content.encode(RefreshRequest(refreshToken: initialTokens.refreshToken))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let refreshed = try res.content.decode(AuthResponse.self)
                #expect(refreshed.refreshToken != initialTokens.refreshToken)
                #expect(refreshed.user.email == "demo@example.com")
            })
        }
    }

    @Test("Refresh retry within grace returns the same rotated token")
    func refreshRetryReturnsSameRotatedToken() async throws {
        try await withApp(configure: configure) { app in
            var initialTokens: AuthResponse?
            var rotatedTokens: AuthResponse?

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async throws in
                initialTokens = try res.content.decode(AuthResponse.self)
            })

            guard let initialTokens else {
                Issue.record("Missing login response")
                return
            }

            try await app.testing().test(.POST, "api/auth/refresh", beforeRequest: { req in
                try req.content.encode(RefreshRequest(refreshToken: initialTokens.refreshToken))
            }, afterResponse: { res async throws in
                rotatedTokens = try res.content.decode(AuthResponse.self)
            })

            guard let rotatedTokens else {
                Issue.record("Missing rotated refresh response")
                return
            }

            try await app.testing().test(.POST, "api/auth/refresh", beforeRequest: { req in
                try req.content.encode(RefreshRequest(refreshToken: initialTokens.refreshToken))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let retried = try res.content.decode(AuthResponse.self)
                let retriedPayload = try await app.jwtKeys.verify(retried.refreshToken, as: RefreshTokenPayload.self)
                let rotatedPayload = try await app.jwtKeys.verify(rotatedTokens.refreshToken, as: RefreshTokenPayload.self)
                #expect(retriedPayload.nonce == rotatedPayload.nonce)
                #expect(retriedPayload.sid == rotatedPayload.sid)
                #expect(retried.user.email == "demo@example.com")
            })
        }
    }

    @Test("Protected me route accepts access token")
    func me() async throws {
        try await withApp(configure: configure) { app in
            var accessToken = ""

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async throws in
                accessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let profile = try res.content.decode(UserResponse.self)
                #expect(profile.email == "demo@example.com")
            })
        }
    }

    @Test("Profile update persists display name and avatar preset")
    func updateProfile() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)

            try await app.testing().test(.PATCH, "api/me/profile", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    UserProfileUpdateRequest(
                        displayName: "Demo User",
                        avatarPreset: .forest
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let profile = try res.content.decode(UserResponse.self)
                #expect(profile.email == "demo@example.com")
                #expect(profile.displayName == "Demo User")
                #expect(profile.avatarPreset == .forest)
            })

            let storedUser = try await user(email: "demo@example.com", on: app)
            #expect(storedUser.displayName == "Demo User")
            #expect(storedUser.avatarPresetEnum == .forest)
        }
    }

    @Test("Register creates a user and returns tokens")
    func register() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(.POST, "api/auth/register", beforeRequest: { req in
                try req.content.encode(registerRequest)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let payload = try res.content.decode(AuthResponse.self)
                #expect(payload.user.email == "fresh@example.com")
                #expect(!payload.accessToken.isEmpty)
                #expect(!payload.refreshToken.isEmpty)
            })
        }
    }

    @Test("Duplicate register returns a generic validation error")
    func duplicateRegisterUsesGenericValidationError() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(.POST, "api/auth/register", beforeRequest: { req in
                try req.content.encode(
                    RegisterRequest(
                        email: "demo@example.com",
                        password: "password1234",
                        device: nil
                    )
                )
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("注册信息无效"))
                #expect(!res.body.string.contains("已注册"))
            })
        }
    }

    @Test("Sessions endpoint returns the current device session")
    func sessions() async throws {
        try await withApp(configure: configure) { app in
            var accessToken = ""

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async throws in
                accessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            try await app.testing().test(.GET, "api/auth/sessions", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let sessions = try res.content.decode([AuthSessionResponse].self)
                #expect(sessions.count == 1)
                #expect(sessions[0].isCurrent == true)
                #expect(sessions[0].deviceID == "simulator")
            })
        }
    }

    @Test("IM conversations endpoint returns member conversations with latest message")
    func imConversations() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "chat-peer@example.com", on: app)
            let conversation = Conversation(title: "Demo Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_002))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)
            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: try otherUser.requireID(),
                serverSequence: 1,
                kind: "text",
                body: ["text": "hello from history"]
            ).create(on: app.db)
            try await IMConversationSummaryProjectionService(db: app.db)
                .rebuildSummaries(for: try demoUser.requireID())

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.count == 1)
                #expect(conversations[0].id == conversationID)
                #expect(conversations[0].title == "Demo Chat")
                #expect(conversations[0].kind == IMConversationKind.group.rawValue)
                #expect(conversations[0].directMessagingState == nil)
                #expect(conversations[0].memberCount == 2)
                #expect(conversations[0].memberUserIDs.count == 2)
                #expect(conversations[0].lastMessage?.serverSequence == 1)
                #expect(conversations[0].lastMessage?.body["text"] == "hello from history")
                #expect(conversations[0].lastReadSequence == 0)
                #expect(conversations[0].unreadCount == 1)
            })
        }
    }

    @Test("IM conversations read path does not auto rebuild missing summaries")
    func imConversationsReadPathDoesNotAutoRebuildMissingSummaries() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await makeUser(email: "projection-owner@example.com", on: app)
            let peer = try await makeUser(email: "projection-peer@example.com", on: app)
            let ownerID = try owner.requireID()
            let peerID = try peer.requireID()
            let accessToken = try await loginAccessToken(
                email: owner.email,
                password: "password1234",
                deviceID: "projection-owner-device",
                on: app
            )

            let conversation = Conversation(
                title: "Needs Backfill",
                updatedAt: Date(timeIntervalSince1970: 1_700_120_000)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: ownerID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerID)
                .create(on: app.db)
            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: peerID,
                serverSequence: 1,
                kind: "text",
                body: ["text": "needs rebuild"]
            ).create(on: app.db)

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let page = try res.content.decode(IMConversationPageResponse.self)
                #expect(page.items.isEmpty)
            })

            try await IMConversationSummaryProjectionService(db: app.db)
                .rebuildSummaries(for: ownerID)

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let page = try res.content.decode(IMConversationPageResponse.self)
                #expect(page.items.count == 1)
                #expect(page.items.first?.id == conversationID)
                #expect(page.items.first?.lastMessage?.content.previewText == "needs rebuild")
            })
        }
    }

    @Test("IM conversation summary endpoints page from projection records")
    func imConversationSummaryEndpointsPageFromProjectionRecords() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await makeUser(email: "summary-owner@example.com", on: app)
            let peer = try await makeUser(email: "summary-peer@example.com", on: app)
            let ownerID = try owner.requireID()
            let peerID = try peer.requireID()
            let accessToken = try await loginAccessToken(
                email: owner.email,
                password: "password1234",
                deviceID: "summary-owner-device",
                on: app
            )

            var baselineToken = ""
            try await app.testing().test(.GET, "api/im/conversations?limit=2", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let page = try res.content.decode(IMConversationPageResponse.self)
                #expect(page.items.isEmpty)
                baselineToken = page.snapshotToken
            })

            let firstConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
            let secondConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
            let thirdConversationID = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!

            for summary in try [
                makeConversationSummaryProjection(
                    ownerUserID: ownerID,
                    conversationID: firstConversationID,
                    peerUserID: peerID,
                    title: "Newest",
                    serverSequence: 3,
                    lastActivityAt: Date(timeIntervalSince1970: 1_700_220_300),
                    updatedAt: Date(timeIntervalSince1970: 1_700_220_300)
                ),
                makeConversationSummaryProjection(
                    ownerUserID: ownerID,
                    conversationID: secondConversationID,
                    peerUserID: peerID,
                    title: "Middle",
                    serverSequence: 2,
                    lastActivityAt: Date(timeIntervalSince1970: 1_700_220_200),
                    updatedAt: Date(timeIntervalSince1970: 1_700_220_200)
                ),
                makeConversationSummaryProjection(
                    ownerUserID: ownerID,
                    conversationID: thirdConversationID,
                    peerUserID: peerID,
                    title: "Oldest",
                    serverSequence: 1,
                    lastActivityAt: Date(timeIntervalSince1970: 1_700_220_100),
                    updatedAt: Date(timeIntervalSince1970: 1_700_220_100)
                )
            ] {
                try await summary.create(on: app.db)
            }

            var pageCursor = ""
            try await app.testing().test(.GET, queryPath("api/im/conversations", items: [
                URLQueryItem(name: "limit", value: "2")
            ]), beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let page = try res.content.decode(IMConversationPageResponse.self)
                #expect(page.items.map(\.id) == [firstConversationID, secondConversationID])
                #expect(page.hasMore == true)
                pageCursor = try #require(page.nextCursor)
            })

            try await app.testing().test(.GET, queryPath("api/im/conversations", items: [
                URLQueryItem(name: "limit", value: "2"),
                URLQueryItem(name: "cursor", value: pageCursor)
            ]), beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let page = try res.content.decode(IMConversationPageResponse.self)
                #expect(page.items.map(\.id) == [thirdConversationID])
                #expect(page.hasMore == false)
                #expect(page.nextCursor == nil)
            })

            var changesCursor = ""
            try await app.testing().test(.GET, queryPath("api/im/conversations/changes", items: [
                URLQueryItem(name: "afterToken", value: baselineToken),
                URLQueryItem(name: "limit", value: "2")
            ]), beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let changes = try res.content.decode(IMConversationChangesResponse.self)
                #expect(changes.upserts.map(\.id) == [thirdConversationID, secondConversationID])
                #expect(changes.removedConversationIDs.isEmpty)
                #expect(changes.hasMore == true)
                changesCursor = try #require(changes.nextCursor)
                #expect(changes.targetToken != baselineToken)
            })

            try await app.testing().test(.GET, queryPath("api/im/conversations/changes", items: [
                URLQueryItem(name: "afterToken", value: baselineToken),
                URLQueryItem(name: "limit", value: "2"),
                URLQueryItem(name: "cursor", value: changesCursor)
            ]), beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let changes = try res.content.decode(IMConversationChangesResponse.self)
                #expect(changes.upserts.map(\.id) == [firstConversationID])
                #expect(changes.removedConversationIDs.isEmpty)
                #expect(changes.hasMore == false)
                #expect(changes.nextCursor == nil)
            })
        }
    }

    @Test("IM create conversation endpoint respects explicit direct kind and clears title")
    func createConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "create-peer@example.com", on: app)

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.direct.rawValue,
                        title: "Fresh Chat",
                        memberEmails: [peerUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversation = try res.content.decode(IMConversationResponse.self)
                #expect(conversation.title == nil)
                #expect(conversation.kind == IMConversationKind.direct.rawValue)
                #expect(conversation.directMessagingState == IMDirectMessagingState.active.rawValue)
                #expect(conversation.directPeer == IMDirectPeerResponse(id: try peerUser.requireID(), email: peerUser.email))
                #expect(conversation.memberCount == 2)
                #expect(conversation.lastMessage == nil)
                #expect(conversation.lastReadSequence == 0)
                #expect(conversation.unreadCount == 0)
                #expect(conversation.memberUserIDs.sorted { $0.uuidString < $1.uuidString } == [
                    try demoUser.requireID(),
                    try peerUser.requireID()
                ].sorted { $0.uuidString < $1.uuidString })
            })
        }
    }

    @Test("IM create conversation endpoint creates group for three or more members")
    func createGroupConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let firstPeer = try await makeUser(email: "group-create-first@example.com", on: app)
            let secondPeer = try await makeUser(email: "group-create-second@example.com", on: app)

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.group.rawValue,
                        title: "Fresh Group",
                        memberEmails: [firstPeer.email, secondPeer.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversation = try res.content.decode(IMConversationResponse.self)
                #expect(conversation.title == "Fresh Group")
                #expect(conversation.kind == IMConversationKind.group.rawValue)
                #expect(conversation.memberCount == 3)
                #expect(conversation.memberUserIDs.sorted { $0.uuidString < $1.uuidString } == [
                    try demoUser.requireID(),
                    try firstPeer.requireID(),
                    try secondPeer.requireID()
                ].sorted { $0.uuidString < $1.uuidString })
            })
        }
    }

    @Test("IM group creation writes a system message into summary and history")
    func createGroupConversationPersistsSystemMessage() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let firstPeer = try await makeUser(email: "group-system-first@example.com", on: app)
            let secondPeer = try await makeUser(email: "group-system-second@example.com", on: app)
            var createdConversationID: UUID?

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.group.rawValue,
                        title: "System Group",
                        memberEmails: [firstPeer.email, secondPeer.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversation = try res.content.decode(IMConversationResponse.self)
                createdConversationID = conversation.id
                #expect(conversation.lastMessage?.content.previewText == "\(demoUser.email) 创建了群聊")
                #expect(conversation.lastReadSequence == 1)
                #expect(conversation.unreadCount == 0)
            })

            let conversationID = try #require(createdConversationID)
            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let messages = try res.content.decode([IMMessageResponse].self)
                #expect(messages.count == 1)
                #expect(messages[0].content.previewText == "\(demoUser.email) 创建了群聊")
                #expect(messages[0].serverSequence == 1)
            })
        }
    }

    @Test("IM create conversation endpoint preserves explicit group kind for two members")
    func createTwoMemberGroupConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "two-member-group@example.com", on: app)

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.group.rawValue,
                        title: "Two Member Group",
                        memberEmails: [peerUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversation = try res.content.decode(IMConversationResponse.self)
                #expect(conversation.title == "Two Member Group")
                #expect(conversation.kind == IMConversationKind.group.rawValue)
                #expect(conversation.memberCount == 2)
                #expect(conversation.memberUserIDs.sorted { $0.uuidString < $1.uuidString } == [
                    try demoUser.requireID(),
                    try peerUser.requireID()
                ].sorted { $0.uuidString < $1.uuidString })
            })
        }
    }

    @Test("IM create conversation endpoint allows duplicate explicit two-member groups")
    func createTwoMemberGroupConversationDoesNotReuseExistingGroup() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let peerUser = try await makeUser(email: "two-member-group-duplicate@example.com", on: app)
            var createdConversationIDs: [UUID] = []

            for title in ["Two Member Group A", "Two Member Group B"] {
                try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                    try req.content.encode(
                        IMConversationCreateRequest(
                            kind: IMConversationKind.group.rawValue,
                            title: title,
                            memberEmails: [peerUser.email]
                        )
                    )
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)

                    let conversation = try res.content.decode(IMConversationResponse.self)
                    #expect(conversation.title == title)
                    #expect(conversation.kind == IMConversationKind.group.rawValue)
                    #expect(conversation.memberCount == 2)
                    createdConversationIDs.append(conversation.id)
                })
            }

            #expect(Set(createdConversationIDs).count == 2)

            let conversations = try await Conversation.query(on: app.db).all()
            #expect(conversations.count == 2)
            #expect(conversations.allSatisfy { $0.conversationKind == .group })
        }
    }

    @Test("IM create conversation endpoint marks untitled two-member conversations as direct")
    func createDirectConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "direct-peer@example.com", on: app)

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: nil,
                        title: nil,
                        memberEmails: [peerUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversation = try res.content.decode(IMConversationResponse.self)
                #expect(conversation.title == nil)
                #expect(conversation.kind == IMConversationKind.direct.rawValue)
                #expect(conversation.memberCount == 2)
                #expect(conversation.memberUserIDs.sorted { $0.uuidString < $1.uuidString } == [
                    try demoUser.requireID(),
                    try peerUser.requireID()
                ].sorted { $0.uuidString < $1.uuidString })
            })
        }
    }

    @Test("IM create conversation endpoint reuses existing two-member conversation")
    func createDirectConversationReusesExistingConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let peerUser = try await makeUser(email: "direct-reuse-peer@example.com", on: app)
            var firstConversationID: UUID?
            let requestedTitles: [String?] = [nil, "Duplicate Title"]

            for title in requestedTitles {
                try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                    try req.content.encode(
                        IMConversationCreateRequest(
                            kind: IMConversationKind.direct.rawValue,
                            title: title,
                            memberEmails: [peerUser.email]
                        )
                    )
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)

                    let conversation = try res.content.decode(IMConversationResponse.self)
                    #expect(conversation.title == nil)
                    #expect(conversation.kind == IMConversationKind.direct.rawValue)
                    if let firstConversationID {
                        #expect(conversation.id == firstConversationID)
                    } else {
                        firstConversationID = conversation.id
                    }
                })
            }

            let conversations = try await Conversation.query(on: app.db).all()
            let matchingMemberships = try await ConversationMember.query(on: app.db)
                .filter(\.$conversation.$id == firstConversationID!)
                .all()
            #expect(conversations.count == 1)
            #expect(matchingMemberships.count == 2)
        }
    }

    @Test("IM create conversation endpoint reuses frozen direct conversation")
    func createDirectConversationReusesFrozenConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "direct-frozen-reuse@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let peerUserID = try peerUser.requireID()

            let existingConversation = Conversation(
                title: nil,
                kind: .direct,
                directMessagingState: .frozenAfterUnfriend,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_900)
            )
            try await existingConversation.create(on: app.db)
            let existingConversationID = try existingConversation.requireID()

            try await ConversationMember(conversationID: existingConversationID, userID: demoUserID)
                .create(on: app.db)
            try await ConversationMember(conversationID: existingConversationID, userID: peerUserID)
                .create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.direct.rawValue,
                        title: "Should Reuse Frozen",
                        memberEmails: [peerUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversation = try res.content.decode(IMConversationResponse.self)
                #expect(conversation.id == existingConversationID)
                #expect(conversation.kind == IMConversationKind.direct.rawValue)
                #expect(conversation.title == nil)
                #expect(conversation.directMessagingState == IMDirectMessagingState.frozenAfterUnfriend.rawValue)
                #expect(conversation.directPeer == IMDirectPeerResponse(id: peerUserID, email: peerUser.email))
            })

            let conversations = try await Conversation.query(on: app.db).all()
            #expect(conversations.count == 1)
            #expect(conversations.first?.directMessagingStateEnum == .frozenAfterUnfriend)
        }
    }

    @Test("IM add members endpoint rejects direct conversations")
    func imAddMembersRejectsDirectConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "direct-members-peer@example.com", on: app)
            let newUser = try await makeUser(email: "direct-members-new@example.com", on: app)
            let conversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_004)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/members", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationMemberUpdateRequest(memberEmails: [newUser.email])
                )
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("私聊会话不支持新增成员"))
            })
        }
    }

    @Test("IM add members endpoint adds only new group members and updates summary")
    func imAddMembers() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let existingUser = try await makeUser(email: "group-existing@example.com", on: app)
            let newUser = try await makeUser(email: "group-new@example.com", on: app)
            let conversation = Conversation(
                title: "Study Group",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_005)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try demoUser.requireID(),
                role: .owner
            )
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try existingUser.requireID())
                .create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/members", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationMemberUpdateRequest(
                        memberEmails: [existingUser.email, newUser.email, newUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMConversationResponse.self)
                #expect(response.id == conversationID)
                #expect(response.kind == IMConversationKind.group.rawValue)
                #expect(response.memberCount == 3)
                #expect(response.memberUserIDs.sorted { $0.uuidString < $1.uuidString } == [
                    try demoUser.requireID(),
                    try existingUser.requireID(),
                    try newUser.requireID()
                ].sorted { $0.uuidString < $1.uuidString })
            })

            let members = try await ConversationMember.query(on: app.db)
                .filter(\.$conversation.$id == conversationID)
                .all()
            #expect(members.count == 3)
        }
    }

    @Test("IM add members endpoint requires at least one actual new member")
    func imAddMembersRejectsNoOp() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let existingUser = try await makeUser(email: "group-noop@example.com", on: app)
            let conversation = Conversation(
                title: "Study Group",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_006)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try demoUser.requireID(),
                role: .owner
            )
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try existingUser.requireID())
                .create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/members", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationMemberUpdateRequest(memberEmails: [existingUser.email, existingUser.email])
                )
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("没有可新增的成员"))
            })
        }
    }

    @Test("IM add members endpoint rejects plain group members")
    func imAddMembersRejectsPlainMember() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await user(email: "demo@example.com", on: app)
            let memberUser = try await makeUser(email: "group-member@example.com", on: app)
            let newUser = try await makeUser(email: "group-member-new@example.com", on: app)
            let memberAccessToken = try await loginAccessToken(
                email: memberUser.email,
                password: "password1234",
                deviceID: "group-member-device",
                on: app
            )
            let conversation = Conversation(
                title: "Privilege Group",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_006)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try owner.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try memberUser.requireID(),
                role: .member
            ).create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/members", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: memberAccessToken)
                try req.content.encode(
                    IMConversationMemberUpdateRequest(memberEmails: [newUser.email])
                )
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("只有群主或管理员可以添加成员"))
            })
        }
    }

    @Test("IM owner can promote admin and admin can remove member")
    func imOwnerPromotesAdminAndAdminRemovesMember() async throws {
        try await withApp(configure: configure) { app in
            let ownerAccessToken = try await loginAccessToken(using: app)
            let owner = try await user(email: "demo@example.com", on: app)
            let adminCandidate = try await makeUser(email: "admin-candidate@example.com", on: app)
            let removableMember = try await makeUser(email: "removable-member@example.com", on: app)
            let adminCandidateID = try adminCandidate.requireID()
            let removableMemberID = try removableMember.requireID()
            let adminAccessToken = try await loginAccessToken(
                email: adminCandidate.email,
                password: "password1234",
                deviceID: "admin-candidate-device",
                on: app
            )
            let conversation = Conversation(
                title: "Ops Group",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_006)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try owner.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: adminCandidateID,
                role: .member
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: removableMemberID,
                role: .member
            ).create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/members/\(adminCandidateID.uuidString)/role", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerAccessToken)
                try req.content.encode(
                    IMConversationMemberRoleUpdateRequest(role: IMConversationMemberRole.admin.rawValue)
                )
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/members/\(removableMemberID.uuidString)/remove", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: adminAccessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(IMConversationResponse.self)
                #expect(response.memberCount == 2)
            })

            let memberships = try await ConversationMember.query(on: app.db)
                .filter(\.$conversation.$id == conversationID)
                .all()
            #expect(memberships.count == 2)
            #expect(
                memberships.first(where: { $0.$user.id == adminCandidateID })?.memberRoleEnum == .admin
            )
        }
    }

    @Test("IM admin cannot update another member's group role")
    func imAdminCannotUpdateMemberRole() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await user(email: "demo@example.com", on: app)
            let adminUser = try await makeUser(email: "role-admin@example.com", on: app)
            let targetUser = try await makeUser(email: "role-target@example.com", on: app)
            let adminAccessToken = try await loginAccessToken(
                email: adminUser.email,
                password: "password1234",
                deviceID: "role-admin-device",
                on: app
            )
            let conversation = Conversation(
                title: "Role Boundaries",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_006)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try owner.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try adminUser.requireID(),
                role: .admin
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try targetUser.requireID(),
                role: .member
            ).create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/members/\(try targetUser.requireID().uuidString)/role", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: adminAccessToken)
                try req.content.encode(
                    IMConversationMemberRoleUpdateRequest(role: IMConversationMemberRole.admin.rawValue)
                )
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("只有群主可以调整成员角色"))
            })
        }
    }

    @Test("IM member cannot rename group conversation")
    func imMemberCannotRenameGroupConversation() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await user(email: "demo@example.com", on: app)
            let memberUser = try await makeUser(email: "rename-member@example.com", on: app)
            let memberAccessToken = try await loginAccessToken(
                email: memberUser.email,
                password: "password1234",
                deviceID: "rename-member-device",
                on: app
            )
            let conversation = Conversation(
                title: "Rename Boundaries",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_006)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try owner.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try memberUser.requireID(),
                role: .member
            ).create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/title", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: memberAccessToken)
                try req.content.encode(IMConversationTitleUpdateRequest(title: "Illegal Rename"))
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("只有群主或管理员可以修改群名称"))
            })
        }
    }

    @Test("IM removed member can no longer manage the conversation")
    func imRemovedMemberCannotManageConversation() async throws {
        try await withApp(configure: configure) { app in
            let ownerAccessToken = try await loginAccessToken(using: app)
            let owner = try await user(email: "demo@example.com", on: app)
            let removedUser = try await makeUser(email: "removed-manager@example.com", on: app)
            let removedAccessToken = try await loginAccessToken(
                email: removedUser.email,
                password: "password1234",
                deviceID: "removed-manager-device",
                on: app
            )
            let conversation = Conversation(
                title: "Removal Boundaries",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_006)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try owner.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try removedUser.requireID(),
                role: .member
            ).create(on: app.db)
            let extraUser = try await makeUser(email: "removed-extra@example.com", on: app)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try extraUser.requireID(),
                role: .member
            ).create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/members/\(try removedUser.requireID().uuidString)/remove", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/title", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: removedAccessToken)
                try req.content.encode(IMConversationTitleUpdateRequest(title: "Should Not Work"))
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("IM owner must transfer ownership before leaving group")
    func imOwnerMustTransferBeforeLeaving() async throws {
        try await withApp(configure: configure) { app in
            let ownerAccessToken = try await loginAccessToken(using: app)
            let owner = try await user(email: "demo@example.com", on: app)
            let secondUser = try await makeUser(email: "owner-transfer-second@example.com", on: app)
            let thirdUser = try await makeUser(email: "owner-transfer-third@example.com", on: app)
            let conversation = Conversation(
                title: "Transfer Group",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_006)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try owner.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try secondUser.requireID(),
                role: .member
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try thirdUser.requireID(),
                role: .member
            ).create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/leave", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("群主退出前请先转让群主"))
            })
        }
    }

    @Test("IM leave endpoint rejects direct conversations")
    func imLeaveRejectsDirectConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "leave-direct-peer@example.com", on: app)
            let conversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_007)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/leave", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("私聊会话不支持主动退出"))
            })
        }
    }

    @Test("IM leave endpoint rejects groups that would drop below two members")
    func imLeaveRejectsTooSmallGroup() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "leave-small-peer@example.com", on: app)
            let conversation = Conversation(
                title: "Tiny Group",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_008)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/leave", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("退出后会话成员不能少于 2 人"))
            })
        }
    }

    @Test("IM leave endpoint removes the current member and keeps remaining summaries consistent")
    func imLeaveConversation() async throws {
        try await withApp(configure: configure) { app in
            let demoAccessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "leave-peer@example.com", on: app)
            let thirdUser = try await makeUser(email: "leave-third@example.com", on: app)
            let otherAccessToken = try await loginAccessToken(
                email: otherUser.email,
                password: "password1234",
                deviceID: "leave-peer-device",
                on: app
            )
            let conversation = Conversation(
                title: "Leave Group",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_009)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try thirdUser.requireID())
                .create(on: app.db)
            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: try thirdUser.requireID(),
                serverSequence: 1,
                kind: "text",
                body: ["text": "hello after join"]
            ).create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/leave", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: demoAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: demoAccessToken)
            }, afterResponse: { res async throws in
                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.isEmpty)
            })

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: otherAccessToken)
            }, afterResponse: { res async throws in
                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.count == 1)
                #expect(conversations[0].id == conversationID)
                #expect(conversations[0].kind == IMConversationKind.group.rawValue)
                #expect(conversations[0].memberCount == 2)
                #expect(conversations[0].lastReadSequence == 0)
                #expect(conversations[0].unreadCount == 2)
                #expect(conversations[0].lastMessage?.content.previewText == "\(demoUser.email) 退出了群聊")
            })
        }
    }

    @Test("IM members endpoint returns role-aware sorted members for members only")
    func imConversationMembers() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "members-peer@example.com", on: app)
            let adminUser = try await makeUser(email: "members-admin@example.com", on: app)
            let conversation = Conversation(title: "Members Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_030))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try demoUser.requireID(),
                role: .owner
            )
                .create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try adminUser.requireID(),
                role: .admin
            )
                .create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try otherUser.requireID(),
                role: .member
            )
                .create(on: app.db)

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/members", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let members = try res.content.decode([IMConversationMemberResponse].self)
                #expect(members.map(\.email) == [
                    "demo@example.com",
                    "members-admin@example.com",
                    "members-peer@example.com"
                ])
                #expect(members.map(\.role) == [
                    IMConversationMemberRole.owner.rawValue,
                    IMConversationMemberRole.admin.rawValue,
                    IMConversationMemberRole.member.rawValue
                ])
            })
        }
    }

    @Test("IM messages endpoint returns ordered conversation history for members only")
    func imMessages() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "history-peer@example.com", on: app)
            let conversation = Conversation(title: nil, updatedAt: Date(timeIntervalSince1970: 1_700_100_010))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)
            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: try demoUser.requireID(),
                serverSequence: 1,
                clientMessageID: "client-history-1",
                kind: "text",
                body: ["text": "first"]
            ).create(on: app.db)
            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: try otherUser.requireID(),
                serverSequence: 2,
                clientMessageID: "client-history-2",
                kind: "text",
                body: ["text": "second"]
            ).create(on: app.db)
            try await IMConversationSummaryProjectionService(db: app.db)
                .rebuildSummaries(for: try demoUser.requireID())

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let messages = try res.content.decode([IMMessageResponse].self)
                #expect(messages.map(\.serverSequence) == [1, 2])
                #expect(messages.map(\.clientMessageID) == ["client-history-1", "client-history-2"])
                #expect(messages.map { $0.body["text"] } == ["first", "second"])
            })

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.first?.id == conversationID)
                #expect(conversations.first?.unreadCount == 2)
            })

            let stranger = try await makeUser(email: "outsider@example.com", on: app)
            let strangerAccessToken = try await loginAccessToken(
                email: "outsider@example.com",
                password: "password1234",
                deviceID: "outsider-device",
                on: app
            )
            _ = stranger

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: strangerAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("IM recall endpoint replaces message content and refreshes summaries")
    func imRecallMessage() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "recall-peer@example.com", on: app)

            let conversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_060),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try peerUser.requireID())
                .create(on: app.db)

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: try demoUser.requireID(),
                serverSequence: 1,
                content: .text("hello recall")
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()

            try await IMConversationSummaryProjectionService(db: app.db).refreshConversationSummaries(
                conversationID: conversationID,
                recipientUserIDs: [try demoUser.requireID(), try peerUser.requireID()]
            )

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/messages/\(messageID.uuidString)/recall", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let recalled = try res.content.decode(IMMessageResponse.self)
                #expect(recalled.id == messageID)
                #expect(recalled.content == .recalled)
            })

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let messages = try res.content.decode([IMMessageResponse].self)
                #expect(messages.count == 1)
                #expect(messages[0].id == messageID)
                #expect(messages[0].content == .recalled)
            })

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.count == 1)
                #expect(conversations[0].id == conversationID)
                #expect(conversations[0].lastMessage?.content == .recalled)
            })
        }
    }

    @Test("IM recall endpoint rejects messages outside the recall window")
    func imRecallMessageRejectsExpiredWindow() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "recall-expired-peer@example.com", on: app)

            let conversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_061),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try peerUser.requireID())
                .create(on: app.db)

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: try demoUser.requireID(),
                serverSequence: 1,
                content: .text("expired recall")
            )
            try await message.create(on: app.db)
            message.createdAt = Date().addingTimeInterval(-(3 * 60))
            try await message.update(on: app.db)
            let messageID = try message.requireID()

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/messages/\(messageID.uuidString)/recall", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("消息发送超过 2 分钟后不能撤回"))
            })
        }
    }

    @Test("IM read endpoint advances explicit read sequence for conversation members only")
    func imMarkRead() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "read-peer@example.com", on: app)
            let conversation = Conversation(title: "Read Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_012))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            for sequence in 1...2 {
                try await ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: try otherUser.requireID(),
                    serverSequence: sequence,
                    clientMessageID: "client-read-\(sequence)",
                    kind: "text",
                    body: ["text": "read-\(sequence)"]
                ).create(on: app.db)
            }

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/read", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(IMConversationReadRequest(readSequence: 1))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMConversationReadResponse.self)
                #expect(response.conversationID == conversationID)
                #expect(response.lastReadSequence == 1)
                #expect(response.unreadCount == 1)
            })

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.first?.id == conversationID)
                #expect(conversations.first?.unreadCount == 1)
            })

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/read", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(IMConversationReadRequest(readSequence: 999))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMConversationReadResponse.self)
                #expect(response.conversationID == conversationID)
                #expect(response.lastReadSequence == 2)
                #expect(response.unreadCount == 0)
            })

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.first?.id == conversationID)
                #expect(conversations.first?.unreadCount == 0)
            })

            let stranger = try await makeUser(email: "read-outsider@example.com", on: app)
            let strangerAccessToken = try await loginAccessToken(
                email: stranger.email,
                password: "password1234",
                deviceID: "read-outsider-device",
                on: app
            )

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/read", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: strangerAccessToken)
                try req.content.encode(IMConversationReadRequest(readSequence: 2))
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("IM summary changes reflect read updates across devices for the same user")
    func imConversationChangesReflectCrossDeviceReadProgress() async throws {
        try await withApp(configure: configure) { app in
            let firstDeviceToken = try await loginAccessToken(
                email: "demo@example.com",
                password: "password1234",
                deviceID: "read-device-1",
                on: app
            )
            let secondDeviceToken = try await loginAccessToken(
                email: "demo@example.com",
                password: "password1234",
                deviceID: "read-device-2",
                on: app
            )
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "changes-read-peer@example.com", on: app)
            let conversation = Conversation(
                title: "Cross Device Read",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_012)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try demoUser.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try otherUser.requireID(),
                role: .member
            ).create(on: app.db)

            for sequence in 1...2 {
                try await ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: try otherUser.requireID(),
                    serverSequence: sequence,
                    clientMessageID: "client-cross-read-\(sequence)",
                    content: .text("cross-read-\(sequence)")
                ).create(on: app.db)
            }
            try await IMConversationSummaryProjectionService(db: app.db).refreshConversationSummaries(
                conversationID: conversationID,
                recipientUserIDs: [try demoUser.requireID()]
            )

            var baselineToken = ""
            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: secondDeviceToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let page = try res.content.decode(IMConversationPageResponse.self)
                #expect(page.items.first?.id == conversationID)
                #expect(page.items.first?.lastReadSequence == 0)
                #expect(page.items.first?.unreadCount == 2)
                baselineToken = page.snapshotToken
            })

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/read", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: firstDeviceToken)
                try req.content.encode(IMConversationReadRequest(readSequence: 2))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(IMConversationReadResponse.self)
                #expect(response.lastReadSequence == 2)
                #expect(response.unreadCount == 0)
            })

            try await app.testing().test(.GET, queryPath("api/im/conversations/changes", items: [
                URLQueryItem(name: "afterToken", value: baselineToken)
            ]), beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: secondDeviceToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let changes = try res.content.decode(IMConversationChangesResponse.self)
                #expect(changes.upserts.count == 1)
                #expect(changes.upserts.first?.id == conversationID)
                #expect(changes.upserts.first?.lastReadSequence == 2)
                #expect(changes.upserts.first?.unreadCount == 0)
                #expect(changes.removedConversationIDs.isEmpty)
            })
        }
    }

    @Test("IM conversation preference changes sync across devices")
    func imConversationPreferenceChangesSyncAcrossDevices() async throws {
        try await withApp(configure: configure) { app in
            let firstDeviceToken = try await loginAccessToken(
                email: "demo@example.com",
                password: "password1234",
                deviceID: "preferences-device-1",
                on: app
            )
            let secondDeviceToken = try await loginAccessToken(
                email: "demo@example.com",
                password: "password1234",
                deviceID: "preferences-device-2",
                on: app
            )
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "preferences-peer@example.com", on: app)
            let conversation = Conversation(
                title: "Preferences",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_500_100)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try demoUser.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try peerUser.requireID(),
                role: .member
            ).create(on: app.db)

            try await IMConversationSummaryProjectionService(db: app.db).refreshConversationSummaries(
                conversationID: conversationID,
                recipientUserIDs: [try demoUser.requireID()]
            )

            var baselineToken = ""
            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: secondDeviceToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let page = try res.content.decode(IMConversationPageResponse.self)
                #expect(page.items.count == 1)
                #expect(page.items[0].isPinned == false)
                #expect(page.items[0].isMuted == false)
                baselineToken = page.snapshotToken
            })

            try await app.testing().test(.PATCH, "api/im/conversations/\(conversationID.uuidString)/preferences", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: firstDeviceToken)
                try req.content.encode(
                    IMConversationPreferencesUpdateRequest(isPinned: true, isMuted: true)
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(IMConversationResponse.self)
                #expect(response.isPinned == true)
                #expect(response.pinnedAt != nil)
                #expect(response.isMuted == true)
            })

            try await app.testing().test(.GET, queryPath("api/im/conversations/changes", items: [
                URLQueryItem(name: "afterToken", value: baselineToken)
            ]), beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: secondDeviceToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let changes = try res.content.decode(IMConversationChangesResponse.self)
                #expect(changes.upserts.count == 1)
                #expect(changes.upserts[0].id == conversationID)
                #expect(changes.upserts[0].isPinned == true)
                #expect(changes.upserts[0].pinnedAt != nil)
                #expect(changes.upserts[0].isMuted == true)
            })
        }
    }

    @Test("Profile update refreshes direct peer in summary changes")
    func profileUpdateRefreshesDirectPeerInSummaryChanges() async throws {
        try await withApp(configure: configure) { app in
            let ownerToken = try await loginAccessToken(
                email: "demo@example.com",
                password: "password1234",
                deviceID: "profile-owner-device",
                on: app
            )
            let peer = User(
                email: User.normalize("profile-peer@example.com"),
                passwordHash: try Bcrypt.hash("password1234"),
                status: .active
            )
            try await peer.create(on: app.db)
            let peerToken = try await loginAccessToken(
                email: peer.email,
                password: "password1234",
                deviceID: "profile-peer-device",
                on: app
            )
            let ownerUser = try await user(email: "demo@example.com", on: app)
            let conversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_510_000)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            let peerUserID = try peer.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try ownerUser.requireID(),
                role: .member
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: peerUserID,
                role: .member
            ).create(on: app.db)

            try await IMConversationSummaryProjectionService(db: app.db).refreshConversationSummaries(
                conversationID: conversationID,
                recipientUserIDs: [try ownerUser.requireID()]
            )

            var baselineToken = ""
            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let page = try res.content.decode(IMConversationPageResponse.self)
                #expect(page.items.count == 1)
                #expect(page.items[0].directPeer == IMDirectPeerResponse(
                    id: peerUserID,
                    email: peer.email,
                    displayName: nil,
                    avatarPreset: nil
                ))
                baselineToken = page.snapshotToken
            })

            try await app.testing().test(.PATCH, "api/me/profile", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: peerToken)
                try req.content.encode(
                    UserProfileUpdateRequest(
                        displayName: "Peer Display",
                        avatarPreset: .rose
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, queryPath("api/im/conversations/changes", items: [
                URLQueryItem(name: "afterToken", value: baselineToken)
            ]), beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let changes = try res.content.decode(IMConversationChangesResponse.self)
                #expect(changes.upserts.count == 1)
                #expect(changes.upserts[0].id == conversationID)
                #expect(changes.upserts[0].directPeer == IMDirectPeerResponse(
                    id: peerUserID,
                    email: peer.email,
                    displayName: "Peer Display",
                    avatarPreset: .rose
                ))
            })
        }
    }

    @Test("IM metadata update persists fields and emits a structured system message")
    func imConversationMetadataUpdatePersistsAndEmitsStructuredSystemMessage() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let peerUser = try await makeUser(email: "metadata-peer@example.com", on: app)
            let conversation = Conversation(
                title: "Original Title",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_500_200)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try demoUser.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try peerUser.requireID(),
                role: .member
            ).create(on: app.db)

            try await app.testing().test(.PATCH, "api/im/conversations/\(conversationID.uuidString)/metadata", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationMetadataUpdateRequest(
                        title: "Updated Title",
                        notice: "Ship checklist at 18:00",
                        avatarPreset: .forest
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(IMConversationResponse.self)
                #expect(response.title == "Updated Title")
                #expect(response.notice == "Ship checklist at 18:00")
                #expect(response.avatarPreset == .forest)
            })

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let messages = try res.content.decode([IMMessageResponse].self)
                #expect(messages.count == 1)
                guard case .system(let event) = messages[0].content else {
                    Issue.record("Expected metadata update to emit a system message")
                    return
                }

                #expect(event.type == .metadataUpdated)
                #expect(event.actorUserID == demoUserID)
                #expect(event.actorEmail == "demo@example.com")
                #expect(event.updatedFields == [.title, .notice, .avatarPreset])
                #expect(event.title == "Updated Title")
                #expect(event.notice == "Ship checklist at 18:00")
                #expect(event.avatarPreset == .forest)
            })
        }
    }

    @Test("IM new members only see messages from their visible history window")
    func imConversationHistoryRespectsVisibleFromSequenceForNewMembers() async throws {
        try await withApp(configure: configure) { app in
            let ownerToken = try await loginAccessToken(using: app)
            let ownerUser = try await user(email: "demo@example.com", on: app)
            let existingUser = try await makeUser(email: "visible-existing@example.com", on: app)
            let newUser = try await makeUser(email: "visible-new@example.com", on: app)
            let newUserToken = try await loginAccessToken(
                email: newUser.email,
                password: "password1234",
                deviceID: "visible-new-device",
                on: app
            )

            let conversation = Conversation(
                title: "Visible Window",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_500_300)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try ownerUser.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try existingUser.requireID(),
                role: .member
            ).create(on: app.db)

            _ = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "visible-before-join",
                    text: "before join"
                ),
                senderUserID: try ownerUser.requireID()
            )

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/members", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerToken)
                try req.content.encode(
                    IMConversationMemberUpdateRequest(memberEmails: [newUser.email])
                )
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            _ = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "visible-after-join",
                    text: "after join"
                ),
                senderUserID: try ownerUser.requireID()
            )

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: newUserToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let messages = try res.content.decode([IMMessageResponse].self)
                #expect(messages.map(\.serverSequence) == [2, 3])
                #expect(messages.map(\.content.previewText) == [
                    "demo@example.com 添加了 visible-new@example.com",
                    "after join"
                ])
            })

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages/since?afterSequence=0", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: newUserToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(IMMessageSinceResponse.self)
                #expect(payload.messages.map(\.serverSequence) == [2, 3])
                #expect(payload.nextAfterSequence == 3)
            })
        }
    }

    @Test("IM messages since endpoint returns ordered incremental messages for conversation members only")
    func imMessagesSince() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "since-peer@example.com", on: app)
            let conversation = Conversation(title: "Since Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_015))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            for sequence in 1...4 {
                let senderID = sequence.isMultiple(of: 2) ? try otherUser.requireID() : try demoUser.requireID()
                try await ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    clientMessageID: "client-since-\(sequence)",
                    kind: "text",
                    body: ["text": "since-\(sequence)"]
                ).create(on: app.db)
            }

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/messages/since?afterSequence=0"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMMessageSinceResponse.self)
                let messages = response.messages
                #expect(messages.map(\.serverSequence) == [1, 2, 3, 4])
                #expect(messages.map(\.clientMessageID) == [
                    "client-since-1",
                    "client-since-2",
                    "client-since-3",
                    "client-since-4"
                ])
                #expect(messages.map { $0.body["text"] } == ["since-1", "since-2", "since-3", "since-4"])
                #expect(response.hasMore == false)
                #expect(response.nextAfterSequence == 4)
            })

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/messages/since?afterSequence=2&limit=2"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMMessageSinceResponse.self)
                let messages = response.messages
                #expect(messages.map(\.serverSequence) == [3, 4])
                #expect(response.hasMore == false)
                #expect(response.nextAfterSequence == 4)
            })

            let stranger = try await makeUser(email: "since-outsider@example.com", on: app)
            let strangerAccessToken = try await loginAccessToken(
                email: stranger.email,
                password: "password1234",
                deviceID: "since-outsider-device",
                on: app
            )

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/messages/since?afterSequence=0"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: strangerAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("IM messages since endpoint applies default and maximum limits")
    func imMessagesSinceRespectsLimits() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "since-limit-peer@example.com", on: app)
            let conversation = Conversation(title: "Since Limit Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_025))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            for sequence in 1...520 {
                let senderID = sequence.isMultiple(of: 2) ? try otherUser.requireID() : try demoUser.requireID()
                try await ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    clientMessageID: "client-limit-\(sequence)",
                    kind: "text",
                    body: ["text": "limit-\(sequence)"]
                ).create(on: app.db)
            }

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/messages/since?afterSequence=0"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMMessageSinceResponse.self)
                let messages = response.messages
                #expect(messages.count == 100)
                #expect(messages.first?.serverSequence == 1)
                #expect(messages.last?.serverSequence == 100)
                #expect(response.hasMore == true)
                #expect(response.nextAfterSequence == 100)
            })

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/messages/since?afterSequence=0&limit=999"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMMessageSinceResponse.self)
                let messages = response.messages
                #expect(messages.count == 500)
                #expect(messages.first?.serverSequence == 1)
                #expect(messages.last?.serverSequence == 500)
                #expect(response.hasMore == true)
                #expect(response.nextAfterSequence == 500)
            })
        }
    }

    @Test("IM messages endpoint supports beforeSequence pagination")
    func imMessagesPagination() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "history-page-peer@example.com", on: app)
            let conversation = Conversation(title: "Paged Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_020))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            for sequence in 1...4 {
                let senderID = sequence.isMultiple(of: 2) ? try otherUser.requireID() : try demoUser.requireID()
                try await ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    kind: "text",
                    body: ["text": "message-\(sequence)"]
                ).create(on: app.db)
            }

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages?limit=2", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let messages = try res.content.decode([IMMessageResponse].self)
                #expect(messages.map(\.serverSequence) == [3, 4])
                #expect(messages.map { $0.body["text"] } == ["message-3", "message-4"])
            })

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages?beforeSequence=3&limit=2", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let messages = try res.content.decode([IMMessageResponse].self)
                #expect(messages.map(\.serverSequence) == [1, 2])
                #expect(messages.map { $0.body["text"] } == ["message-1", "message-2"])
            })
        }
    }

    @Test("TCP message persistence is reflected by IM conversations and history endpoints")
    func tcpMessagePersistenceFeedsHTTPConversationData() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "tcp-peer@example.com", on: app)
            let conversation = Conversation(title: "TCP Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_100))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            let result = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                IMTCPMessagePayload(
                    clientMessageID: "client-msg-1",
                    messageID: nil,
                    conversationID: conversationID.uuidString,
                    senderUserID: nil,
                    serverSequence: nil,
                    serverTimestamp: nil,
                    kind: "text",
                    body: ["text": " hello from tcp "]
                ),
                senderUserID: try demoUser.requireID()
            )

            #expect(result.acknowledgement.status == "accepted")
            #expect(result.acknowledgement.conversationID == conversationID.uuidString)
            #expect(result.message.serverSequence == 1)
            #expect(result.message.body["text"] == "hello from tcp")
            #expect(result.recipientUserIDs.count == 2)

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.count == 1)
                #expect(conversations[0].id == conversationID)
                #expect(conversations[0].lastMessage?.serverSequence == 1)
                #expect(conversations[0].lastMessage?.body["text"] == "hello from tcp")
                #expect(conversations[0].unreadCount == 0)
            })

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let messages = try res.content.decode([IMMessageResponse].self)
                #expect(messages.count == 1)
                #expect(messages[0].serverSequence == 1)
                #expect(messages[0].clientMessageID == "client-msg-1")
                #expect(messages[0].body["text"] == "hello from tcp")
            })
        }
    }

    @Test("TCP reply persistence canonicalizes the referenced preview and sender")
    func tcpReplyPersistenceCanonicalizesReference() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "tcp-reply-peer@example.com", on: app)
            let conversation = Conversation(title: "TCP Reply Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_101))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            let referencedMessage = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: try otherUser.requireID(),
                serverSequence: 1,
                content: .text("canonical source")
            )
            try await referencedMessage.create(on: app.db)
            let referencedMessageID = try referencedMessage.requireID()

            let result = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                IMTCPMessagePayload(
                    clientMessageID: "client-reply-1",
                    messageID: nil,
                    conversationID: conversationID.uuidString,
                    senderUserID: nil,
                    serverSequence: nil,
                    serverTimestamp: nil,
                    content: .reply(
                        reference: IMReplyReference(
                            messageID: referencedMessageID.uuidString,
                            senderUserID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
                            previewText: "stale preview"
                        ),
                        text: "reply body"
                    )
                ),
                senderUserID: try demoUser.requireID()
            )

            #expect(result.acknowledgement.status == "accepted")
            #expect(result.message.content == .reply(
                reference: IMReplyReference(
                    messageID: referencedMessageID.uuidString,
                    senderUserID: try otherUser.requireID(),
                    previewText: "canonical source"
                ),
                text: "reply body"
            ))
        }
    }

    @Test("TCP message persistence is idempotent by sender conversation and client message id")
    func tcpMessagePersistenceIsIdempotentByClientMessageID() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "tcp-idempotent-peer@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let conversation = Conversation(title: "Idempotent Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_105))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: demoUserID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            let first = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "client-idempotent-1",
                    text: "first body wins"
                ),
                senderUserID: demoUserID
            )
            let duplicate = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "client-idempotent-1",
                    text: "changed body should be ignored"
                ),
                senderUserID: demoUserID
            )

            #expect(first.acknowledgement.status == "accepted")
            #expect(duplicate.acknowledgement.status == "accepted")
            #expect(duplicate.didCreateMessage == false)
            #expect(duplicate.acknowledgement.messageID == first.acknowledgement.messageID)
            #expect(duplicate.message.messageID == first.message.messageID)
            #expect(duplicate.message.serverSequence == first.message.serverSequence)
            #expect(duplicate.message.body["text"] == "first body wins")

            let messages = try await ConversationMessage.query(on: app.db)
                .filter(\.$conversation.$id == conversationID)
                .all()
            #expect(messages.count == 1)
        }
    }

    @Test("Retrying first stranger direct message with same client id stays accepted")
    func retryingFirstStrangerDirectMessageIsIdempotentBeforePeerReply() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "stranger-idempotent@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let conversation = Conversation(title: nil, kind: .direct, updatedAt: Date(timeIntervalSince1970: 1_700_100_107))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: demoUserID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try peerUser.requireID())
                .create(on: app.db)

            let first = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "stranger-idempotent-first",
                    text: "first hello"
                ),
                senderUserID: demoUserID
            )
            let retry = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "stranger-idempotent-first",
                    text: "first hello retry"
                ),
                senderUserID: demoUserID
            )

            #expect(first.acknowledgement.status == "accepted")
            #expect(retry.acknowledgement.status == "accepted")
            #expect(retry.didCreateMessage == false)
            #expect(retry.acknowledgement.messageID == first.acknowledgement.messageID)

            do {
                _ = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                    imTCPTextPayload(
                        conversationID: conversationID,
                        clientMessageID: "stranger-idempotent-second",
                        text: "second hello"
                    ),
                    senderUserID: demoUserID
                )
                Issue.record("Expected a new second stranger direct message to remain rejected")
            } catch let error as IMRealtimeMessageError {
                #expect(error == .strangerDirectMessageLimitReached)
            }

            let messages = try await ConversationMessage.query(on: app.db)
                .filter(\.$conversation.$id == conversationID)
                .all()
            #expect(messages.count == 1)
        }
    }

    @Test("Null client message ids are not constrained by idempotency index")
    func nullClientMessageIDsCanStillPersistMultipleMessages() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "tcp-null-client-id-peer@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let conversation = Conversation(title: "Null Client ID Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_108))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: demoUserID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            for sequence in 1...2 {
                try await ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: demoUserID,
                    serverSequence: sequence,
                    clientMessageID: nil,
                    kind: "text",
                    body: ["text": "legacy-\(sequence)"]
                ).create(on: app.db)
            }

            let messages = try await ConversationMessage.query(on: app.db)
                .filter(\.$conversation.$id == conversationID)
                .all()
            #expect(messages.count == 2)
        }
    }

    @Test("TCP message persistence rejects users outside the conversation")
    func tcpMessagePersistenceRequiresMembership() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "tcp-member@example.com", on: app)
            let outsider = try await makeUser(email: "tcp-outsider@example.com", on: app)
            let conversation = Conversation(title: nil, updatedAt: Date(timeIntervalSince1970: 1_700_100_110))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            do {
                _ = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                    IMTCPMessagePayload(
                        clientMessageID: "client-msg-outsider",
                        messageID: nil,
                        conversationID: conversationID.uuidString,
                        senderUserID: nil,
                        serverSequence: nil,
                        serverTimestamp: nil,
                        kind: "text",
                        body: ["text": "should fail"]
                    ),
                    senderUserID: try outsider.requireID()
                )
                Issue.record("Expected TCP message persistence to reject outsider membership")
            } catch let error as IMRealtimeMessageError {
                #expect(error == .conversationUnavailable)
            }

            let messages = try await ConversationMessage.query(on: app.db)
                .filter(\.$conversation.$id == conversationID)
                .all()
            #expect(messages.isEmpty)
        }
    }

    @Test("Non-friends can only send one direct message before the peer replies")
    func nonFriendsCanOnlySendOneDirectMessageBeforeReply() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "stranger-direct@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let peerUserID = try peerUser.requireID()
            let conversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_120)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: demoUserID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerUserID)
                .create(on: app.db)

            let firstMessage = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "stranger-first",
                    text: "first hello"
                ),
                senderUserID: demoUserID
            )
            #expect(firstMessage.acknowledgement.status == "accepted")

            do {
                _ = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                    imTCPTextPayload(
                        conversationID: conversationID,
                        clientMessageID: "stranger-second",
                        text: "second hello"
                    ),
                    senderUserID: demoUserID
                )
                Issue.record("Expected second stranger direct message to be rejected before peer reply")
            } catch let error as IMRealtimeMessageError {
                #expect(error == .strangerDirectMessageLimitReached)
                #expect(error.ackStatus == "stranger_direct_message_limit_reached")
            }

            let reply = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "stranger-reply",
                    text: "reply"
                ),
                senderUserID: peerUserID
            )
            #expect(reply.acknowledgement.status == "accepted")

            let thirdMessage = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "stranger-third",
                    text: "after reply"
                ),
                senderUserID: demoUserID
            )
            #expect(thirdMessage.acknowledgement.status == "accepted")
        }
    }

    @Test("Frozen direct conversations reject new messages")
    func frozenDirectConversationRejectsNewMessages() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "frozen-direct-peer@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let peerUserID = try peerUser.requireID()
            let conversation = Conversation(
                title: nil,
                kind: .direct,
                directMessagingState: .frozenAfterUnfriend,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_121)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: demoUserID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerUserID)
                .create(on: app.db)

            do {
                _ = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                    imTCPTextPayload(
                        conversationID: conversationID,
                        clientMessageID: "frozen-direct-message",
                        text: "still there?"
                    ),
                    senderUserID: demoUserID
                )
                Issue.record("Expected frozen direct conversation to reject sending")
            } catch let error as IMRealtimeMessageError {
                #expect(error == .directConversationFrozen)
                #expect(error.ackStatus == "direct_conversation_frozen")
                #expect(error.errorDescription == "你们已不是好友，当前会话不能继续发送消息。")
            }
        }
    }

    @Test("Non-friend direct message limit is enforced across duplicate direct conversations")
    func nonFriendDirectMessageLimitSpansDuplicateDirectConversations() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "stranger-duplicate@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let peerUserID = try peerUser.requireID()
            var conversationIDs: [UUID] = []

            for index in 0..<2 {
                let conversation = Conversation(
                    title: nil,
                    kind: .direct,
                    updatedAt: Date(timeIntervalSince1970: 1_700_100_130 + Double(index))
                )
                try await conversation.create(on: app.db)
                let conversationID = try conversation.requireID()
                conversationIDs.append(conversationID)

                try await ConversationMember(conversationID: conversationID, userID: demoUserID)
                    .create(on: app.db)
                try await ConversationMember(conversationID: conversationID, userID: peerUserID)
                    .create(on: app.db)
            }

            _ = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationIDs[0],
                    clientMessageID: "duplicate-first",
                    text: "first hello"
                ),
                senderUserID: demoUserID
            )

            do {
                _ = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                    imTCPTextPayload(
                        conversationID: conversationIDs[1],
                        clientMessageID: "duplicate-second",
                        text: "second hello"
                    ),
                    senderUserID: demoUserID
                )
                Issue.record("Expected duplicate direct conversation to keep stranger message limit")
            } catch let error as IMRealtimeMessageError {
                #expect(error == .strangerDirectMessageLimitReached)
            }
        }
    }

    @Test("Non-friend message limit does not apply to two-member group conversations")
    func nonFriendMessageLimitDoesNotApplyToTwoMemberGroups() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "stranger-two-member-group@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let peerUserID = try peerUser.requireID()
            let conversation = Conversation(
                title: "Two Person Group",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_140)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: demoUserID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerUserID)
                .create(on: app.db)

            let firstMessage = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "two-member-group-first",
                    text: "first hello"
                ),
                senderUserID: demoUserID
            )

            let secondMessage = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "two-member-group-second",
                    text: "second hello"
                ),
                senderUserID: demoUserID
            )

            #expect(firstMessage.acknowledgement.status == "accepted")
            #expect(secondMessage.acknowledgement.status == "accepted")
            #expect(secondMessage.message.serverSequence == 2)
        }
    }

    @Test("Two-member group messages do not count toward direct stranger message limit")
    func twoMemberGroupMessagesDoNotCountTowardDirectStrangerLimit() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "stranger-group-direct-split@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let peerUserID = try peerUser.requireID()
            let groupConversation = Conversation(
                title: "Two Person Group",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_141)
            )
            try await groupConversation.create(on: app.db)
            let groupConversationID = try groupConversation.requireID()
            let directConversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_142)
            )
            try await directConversation.create(on: app.db)
            let directConversationID = try directConversation.requireID()

            for conversationID in [groupConversationID, directConversationID] {
                try await ConversationMember(conversationID: conversationID, userID: demoUserID)
                    .create(on: app.db)
                try await ConversationMember(conversationID: conversationID, userID: peerUserID)
                    .create(on: app.db)
            }

            _ = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: groupConversationID,
                    clientMessageID: "group-before-direct",
                    text: "group hello"
                ),
                senderUserID: demoUserID
            )

            let firstDirectMessage = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: directConversationID,
                    clientMessageID: "direct-after-group-first",
                    text: "first direct hello"
                ),
                senderUserID: demoUserID
            )
            #expect(firstDirectMessage.acknowledgement.status == "accepted")

            do {
                _ = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                    imTCPTextPayload(
                        conversationID: directConversationID,
                        clientMessageID: "direct-after-group-second",
                        text: "second direct hello"
                    ),
                    senderUserID: demoUserID
                )
                Issue.record("Expected second direct message to be rejected after one direct send")
            } catch let error as IMRealtimeMessageError {
                #expect(error == .strangerDirectMessageLimitReached)
            }
        }
    }

    @Test("Friends are not limited by the pre-reply direct message rule")
    func friendsAreNotLimitedByPreReplyDirectMessageRule() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "friend-direct@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let peerUserID = try peerUser.requireID()
            try await UserContact(ownerUserID: demoUserID, contactUserID: peerUserID)
                .create(on: app.db)
            try await UserContact(ownerUserID: peerUserID, contactUserID: demoUserID)
                .create(on: app.db)

            let conversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_140)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: demoUserID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerUserID)
                .create(on: app.db)

            let firstMessage = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "friend-first",
                    text: "first"
                ),
                senderUserID: demoUserID
            )
            let secondMessage = try await IMRealtimeMessageService(db: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "friend-second",
                    text: "second"
                ),
                senderUserID: demoUserID
            )

            #expect(firstMessage.acknowledgement.status == "accepted")
            #expect(secondMessage.acknowledgement.status == "accepted")
            #expect(secondMessage.message.serverSequence == 2)
        }
    }

    @Test("Expired refresh session no longer authorizes access token requests")
    func accessTokenStopsWorkingWhenSessionExpires() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let currentSession = try await session(for: "demo@example.com", deviceID: "simulator", on: app)

            currentSession.refreshExpiresAt = Date().addingTimeInterval(-1)
            try await currentSession.update(on: app.db)

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })

            let expiredSession = try await session(for: "demo@example.com", deviceID: "simulator", on: app)
            #expect(expiredSession.revokedAt != nil)
        }
    }

    @Test("Logout all revokes every active session")
    func logoutAll() async throws {
        try await withApp(configure: configure) { app in
            var firstAccessToken = ""
            var secondAccessToken = ""

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async throws in
                firstAccessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(
                    LoginRequest(
                        email: "demo@example.com",
                        password: "password1234",
                        device: DeviceMetadata(
                            deviceID: "simulator-2",
                            deviceName: "Second Device",
                            platform: "iOS",
                            appVersion: "1.0"
                        )
                    )
                )
            }, afterResponse: { res async throws in
                secondAccessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            try await app.testing().test(.DELETE, "api/auth/sessions/all", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: firstAccessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let result = try res.content.decode(LogoutAllResponse.self)
                #expect(result.revokedSessions == 2)
            })

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: secondAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Logout all also revokes expired but not yet revoked sessions")
    func logoutAllRevokesExpiredSessions() async throws {
        try await withApp(configure: configure) { app in
            var primaryAccessToken = ""

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(
                    LoginRequest(
                        email: "demo@example.com",
                        password: "password1234",
                        device: DeviceMetadata(
                            deviceID: "primary-device",
                            deviceName: "Primary Device",
                            platform: "iOS",
                            appVersion: "1.0"
                        )
                    )
                )
            }, afterResponse: { res async throws in
                primaryAccessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(
                    LoginRequest(
                        email: "demo@example.com",
                        password: "password1234",
                        device: DeviceMetadata(
                            deviceID: "stale-device",
                            deviceName: "Stale Device",
                            platform: "iOS",
                            appVersion: "1.0"
                        )
                    )
                )
            }, afterResponse: { _ async in })

            let staleSession = try await session(for: "demo@example.com", deviceID: "stale-device", on: app)
            staleSession.refreshExpiresAt = Date().addingTimeInterval(-1)
            try await staleSession.update(on: app.db)

            try await app.testing().test(.DELETE, "api/auth/sessions/all", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: primaryAccessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let result = try res.content.decode(LogoutAllResponse.self)
                #expect(result.revokedSessions == 2)
            })

            let revokedStaleSession = try await session(for: "demo@example.com", deviceID: "stale-device", on: app)
            #expect(revokedStaleSession.revokedAt != nil)
        }
    }

    @Test("Logging in twice on the same device revokes the previous session")
    func singleActiveSessionPerDevice() async throws {
        try await withApp(configure: configure) { app in
            var firstAccessToken = ""
            var secondAccessToken = ""

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async throws in
                firstAccessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async throws in
                secondAccessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: firstAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })

            try await app.testing().test(.GET, "api/auth/sessions", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: secondAccessToken)
            }, afterResponse: { res async throws in
                let sessions = try res.content.decode([AuthSessionResponse].self)
                #expect(sessions.count == 1)
                #expect(sessions[0].deviceID == "simulator")
                #expect(sessions[0].isCurrent == true)
            })
        }
    }

    @Test("Specific device logout revokes only the targeted session")
    func logoutSpecificSession() async throws {
        try await withApp(configure: configure) { app in
            var primaryAccessToken = ""
            var secondaryAccessToken = ""
            var secondarySessionID: UUID?

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(
                    LoginRequest(
                        email: "demo@example.com",
                        password: "password1234",
                        device: DeviceMetadata(
                            deviceID: "primary-device",
                            deviceName: "Primary Device",
                            platform: "iOS",
                            appVersion: "1.0"
                        )
                    )
                )
            }, afterResponse: { res async throws in
                primaryAccessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(
                    LoginRequest(
                        email: "demo@example.com",
                        password: "password1234",
                        device: DeviceMetadata(
                            deviceID: "secondary-device",
                            deviceName: "Secondary Device",
                            platform: "iOS",
                            appVersion: "1.0"
                        )
                    )
                )
            }, afterResponse: { res async throws in
                secondaryAccessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            try await app.testing().test(.GET, "api/auth/sessions", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: primaryAccessToken)
            }, afterResponse: { res async throws in
                let sessions = try res.content.decode([AuthSessionResponse].self)
                secondarySessionID = sessions.first(where: { $0.deviceID == "secondary-device" })?.id
            })

            guard let secondarySessionID else {
                Issue.record("Missing secondary session id")
                return
            }

            try await app.testing().test(.DELETE, "api/auth/sessions/\(secondarySessionID.uuidString)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: primaryAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: secondaryAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: primaryAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("Authenticated upload is persisted and can be downloaded")
    func uploadAndDownloadFile() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let payload = "sample file payload"

            try await app.testing().test(.POST, "api/files/upload", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                req.headers.contentType = .init(type: "application", subType: "octet-stream")
                req.body = ByteBuffer(string: payload)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "api/files/download", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .acceptRanges) == "bytes")
                #expect(res.body.string == payload)
            })
        }
    }

    @Test("Friend request accept creates bilateral contacts")
    func friendRequestAcceptCreatesBilateralContacts() async throws {
        try await withApp(configure: configure) { app in
            let requesterToken = try await loginAccessToken(using: app)
            let requester = try await user(email: "demo@example.com", on: app)
            let addressee = try await makeUser(email: "friend-accept@example.com", on: app)
            let addresseeToken = try await loginAccessToken(
                email: addressee.email,
                password: "password1234",
                deviceID: "friend-accept-device",
                on: app
            )
            var requestID: UUID?

            try await app.testing().test(.POST, "api/contact-requests", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
                try req.content.encode(
                    ContactRequestCreateRequest(
                        email: addressee.email,
                        message: "我是 demo",
                        remark: "好友备注"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(FriendRequestResponse.self)
                requestID = response.id
                #expect(response.status == FriendRequestStatus.pending.rawValue)
                #expect(response.requester.email == requester.email)
                #expect(response.addressee.email == addressee.email)
                #expect(response.requesterRemark == "好友备注")
            })

            try await app.testing().test(.GET, "api/contact-requests?box=outgoing", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
            }, afterResponse: { res async throws in
                let requests = try res.content.decode([FriendRequestResponse].self)
                #expect(requests.map(\.id) == [requestID])
            })

            try await app.testing().test(.GET, "api/contact-requests?box=incoming", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: addresseeToken)
            }, afterResponse: { res async throws in
                let requests = try res.content.decode([FriendRequestResponse].self)
                #expect(requests.map(\.id) == [requestID])
            })

            let acceptedRequestID = try #require(requestID)
            try await app.testing().test(.POST, "api/contact-requests/\(acceptedRequestID.uuidString)/accept", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: addresseeToken)
                try req.content.encode(ContactRequestAcceptRequest(remark: "Demo 备注"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let contact = try res.content.decode(ContactResponse.self)
                #expect(contact.email == requester.email)
                #expect(contact.remark == "Demo 备注")
            })

            try await app.testing().test(.GET, "api/contacts", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
            }, afterResponse: { res async throws in
                let contacts = try res.content.decode([ContactResponse].self)
                #expect(contacts.map(\.email) == [addressee.email])
                #expect(contacts.first?.remark == "好友备注")
            })

            try await app.testing().test(.GET, "api/contacts", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: addresseeToken)
            }, afterResponse: { res async throws in
                let contacts = try res.content.decode([ContactResponse].self)
                #expect(contacts.map(\.email) == [requester.email])
                #expect(contacts.first?.remark == "Demo 备注")
            })
        }
    }

    @Test("Accepting a friend request reactivates an existing frozen direct conversation")
    func friendRequestAcceptReactivatesFrozenDirectConversation() async throws {
        try await withApp(configure: configure) { app in
            let requester = try await user(email: "demo@example.com", on: app)
            let requesterID = try requester.requireID()
            let requesterToken = try await loginAccessToken(using: app)
            let addressee = try await makeUser(email: "friend-reactivate@example.com", on: app)
            let addresseeID = try addressee.requireID()
            let addresseeToken = try await loginAccessToken(
                email: addressee.email,
                password: "password1234",
                deviceID: "friend-reactivate-device",
                on: app
            )
            let directConversation = Conversation(
                title: nil,
                kind: .direct,
                directMessagingState: .frozenAfterUnfriend,
                updatedAt: Date(timeIntervalSince1970: 1_700_200_100)
            )
            try await directConversation.create(on: app.db)
            let directConversationID = try directConversation.requireID()

            try await ConversationMember(conversationID: directConversationID, userID: requesterID)
                .create(on: app.db)
            try await ConversationMember(conversationID: directConversationID, userID: addresseeID)
                .create(on: app.db)

            var requestID: UUID?
            try await app.testing().test(.POST, "api/contact-requests", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
                try req.content.encode(
                    ContactRequestCreateRequest(
                        email: addressee.email,
                        message: "重新加好友",
                        remark: "再次备注"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                requestID = try res.content.decode(FriendRequestResponse.self).id
            })

            let acceptedRequestID = try #require(requestID)
            try await app.testing().test(.POST, "api/contact-requests/\(acceptedRequestID.uuidString)/accept", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: addresseeToken)
                try req.content.encode(ContactRequestAcceptRequest(remark: "回来吧"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            let reloadedConversation = try await Conversation.find(directConversationID, on: app.db)
            #expect(reloadedConversation?.directMessagingStateEnum == .active)

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.first?.id == directConversationID)
                #expect(conversations.first?.directMessagingState == IMDirectMessagingState.active.rawValue)
                #expect(conversations.first?.directPeer == IMDirectPeerResponse(id: addresseeID, email: addressee.email))
            })

            let requesterContact = try await UserContact.query(on: app.db)
                .filter(\.$owner.$id == requesterID)
                .filter(\.$contact.$id == addresseeID)
                .first()
            let addresseeContact = try await UserContact.query(on: app.db)
                .filter(\.$owner.$id == addresseeID)
                .filter(\.$contact.$id == requesterID)
                .first()
            #expect(requesterContact != nil)
            #expect(addresseeContact != nil)
        }
    }

    @Test("Friend request rejects invalid transitions")
    func friendRequestRejectsInvalidTransitions() async throws {
        try await withApp(configure: configure) { app in
            let requesterToken = try await loginAccessToken(using: app)
            let addressee = try await makeUser(email: "friend-rules@example.com", on: app)
            let addresseeToken = try await loginAccessToken(
                email: addressee.email,
                password: "password1234",
                deviceID: "friend-rules-device",
                on: app
            )
            let stranger = try await makeUser(email: "friend-stranger@example.com", on: app)
            let strangerToken = try await loginAccessToken(
                email: stranger.email,
                password: "password1234",
                deviceID: "friend-stranger-device",
                on: app
            )
            var requestID: UUID?

            try await app.testing().test(.POST, "api/contact-requests", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
                try req.content.encode(ContactRequestCreateRequest(email: "demo@example.com", message: nil, remark: nil))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            try await app.testing().test(.POST, "api/contact-requests", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
                try req.content.encode(ContactRequestCreateRequest(email: addressee.email, message: nil, remark: nil))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                requestID = try res.content.decode(FriendRequestResponse.self).id
            })

            try await app.testing().test(.POST, "api/contact-requests", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
                try req.content.encode(ContactRequestCreateRequest(email: addressee.email, message: nil, remark: nil))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            let pendingRequestID = try #require(requestID)
            try await app.testing().test(.POST, "api/contact-requests/\(pendingRequestID.uuidString)/accept", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: strangerToken)
                try req.content.encode(ContactRequestAcceptRequest(remark: nil))
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })

            try await app.testing().test(.POST, "api/contact-requests/\(pendingRequestID.uuidString)/decline", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: addresseeToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "api/contacts", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: requesterToken)
            }, afterResponse: { res async throws in
                let contacts = try res.content.decode([ContactResponse].self)
                #expect(contacts.isEmpty)
            })
        }
    }

    @Test("Contacts direct add is disabled and delete removes both directions")
    func contactsDirectAddDisabledAndDeleteRemovesBothDirections() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let owner = try await user(email: "demo@example.com", on: app)
            let contact = try await makeUser(email: "delete-friend@example.com", on: app)
            let ownerID = try owner.requireID()
            let contactID = try contact.requireID()

            try await app.testing().test(.POST, "api/contacts", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(ContactCreateRequest(email: contact.email, remark: nil))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            try await UserContact(ownerUserID: ownerID, contactUserID: contactID, remark: "peer")
                .create(on: app.db)
            try await UserContact(ownerUserID: contactID, contactUserID: ownerID, remark: "owner")
                .create(on: app.db)
            let directConversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_300_100)
            )
            try await directConversation.create(on: app.db)
            let directConversationID = try directConversation.requireID()
            try await ConversationMember(conversationID: directConversationID, userID: ownerID)
                .create(on: app.db)
            try await ConversationMember(conversationID: directConversationID, userID: contactID)
                .create(on: app.db)

            try await app.testing().test(.DELETE, "api/contacts/\(contactID.uuidString)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            let remainingContacts = try await UserContact.query(on: app.db).all()
            #expect(remainingContacts.isEmpty)
            let reloadedConversation = try await Conversation.find(directConversationID, on: app.db)
            #expect(reloadedConversation != nil)
            #expect(reloadedConversation?.directMessagingStateEnum == .frozenAfterUnfriend)

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.first?.id == directConversationID)
                #expect(conversations.first?.directMessagingState == IMDirectMessagingState.frozenAfterUnfriend.rawValue)
                #expect(conversations.first?.directPeer == IMDirectPeerResponse(id: contactID, email: contact.email))
            })
        }
    }

    @Test("Download supports HTTP range requests")
    func downloadSupportsRangeRequests() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let payload = "range-download-check"

            try await app.testing().test(.POST, "api/files/upload", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                req.headers.contentType = .init(type: "application", subType: "octet-stream")
                req.body = ByteBuffer(string: payload)
            }, afterResponse: { _ async in })

            try await app.testing().test(.GET, "api/files/download", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                req.headers.replaceOrAdd(name: .range, value: "bytes=6-13")
            }, afterResponse: { res async in
                #expect(res.status == .partialContent)
                #expect(res.headers.first(name: .contentRange) == "bytes 6-13/\(payload.utf8.count)")
                #expect(res.body.string == "download")
            })
        }
    }

    private func loginAccessToken(using app: Application) async throws -> String {
        try await loginAccessToken(
            email: loginRequest.email,
            password: loginRequest.password,
            deviceID: loginRequest.device?.deviceID ?? "simulator",
            on: app
        )
    }

    private func loginAccessToken(
        email: String,
        password: String,
        deviceID: String,
        on app: Application
    ) async throws -> String {
        var accessToken = ""

        try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
            try req.content.encode(
                LoginRequest(
                    email: email,
                    password: password,
                    device: DeviceMetadata(
                        deviceID: deviceID,
                        deviceName: "Test Device",
                        platform: "iOS",
                        appVersion: "1.0"
                    )
                )
            )
        }, afterResponse: { res async throws in
            accessToken = try res.content.decode(AuthResponse.self).accessToken
        })

        return accessToken
    }

    private func user(email: String, on app: Application) async throws -> User {
        let normalizedEmail = User.normalize(email)
        guard let user = try await User.query(on: app.db)
            .filter(\.$email == normalizedEmail)
            .first()
        else {
            throw TestFailure.missingEntity("Missing user for \(email)")
        }

        return user
    }

    private func makeUser(email: String, on app: Application) async throws -> User {
        let user = User(
            email: User.normalize(email),
            passwordHash: try Bcrypt.hash("password1234"),
            status: .active
        )
        try await user.create(on: app.db)
        return user
    }

    private func imTCPTextPayload(
        conversationID: UUID,
        clientMessageID: String,
        text: String
    ) -> IMTCPMessagePayload {
        IMTCPMessagePayload(
            clientMessageID: clientMessageID,
            messageID: nil,
            conversationID: conversationID.uuidString,
            senderUserID: nil,
            serverSequence: nil,
            serverTimestamp: nil,
            kind: "text",
            body: ["text": text]
        )
    }

    private func queryPath(_ base: String, items: [URLQueryItem]) -> String {
        var components = URLComponents()
        components.path = base
        components.queryItems = items
        guard let query = components.percentEncodedQuery, !query.isEmpty else {
            return base
        }
        return "\(base)?\(query)"
    }

    private func makeConversationSummaryProjection(
        ownerUserID: UUID,
        conversationID: UUID,
        peerUserID: UUID,
        title: String,
        serverSequence: Int,
        lastActivityAt: Date,
        updatedAt: Date,
        isRemoved: Bool = false
    ) throws -> ConversationUserSummary {
        try ConversationUserSummary(
            ownerUserID: ownerUserID,
            conversationID: conversationID,
            title: title,
            kind: IMConversationKind.group.rawValue,
            directMessagingState: nil,
            directPeerUserID: nil,
            directPeerEmail: nil,
            memberUserIDs: [ownerUserID, peerUserID],
            lastMessage: IMMessagePreviewResponse(
                id: UUID(),
                senderUserID: peerUserID,
                serverSequence: serverSequence,
                content: .text(title),
                createdAt: lastActivityAt
            ),
            lastReadSequence: 0,
            unreadCount: serverSequence,
            lastActivityAt: lastActivityAt,
            updatedAt: updatedAt,
            isRemoved: isRemoved
        )
    }

    private func session(for email: String, deviceID: String, on app: Application) async throws -> AuthSession {
        let user = try await user(email: email, on: app)
        let userID = try user.requireID()

        guard let session = try await AuthSession.query(on: app.db)
            .filter(\.$user.$id == userID)
            .filter(\.$deviceID == deviceID)
            .sort(\.$createdAt, .descending)
            .first()
        else {
            throw TestFailure.missingEntity("Missing session for device \(deviceID)")
        }

        return session
    }

    private func restoreEnvironment(_ key: String, to value: String?) {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }
}

private enum TestFailure: Error {
    case missingEntity(String)
}

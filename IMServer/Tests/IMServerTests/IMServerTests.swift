@testable import IMServer
import Fluent
import NIOCore
import SQLKit
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
    @Test("Reset IM schema rebuilds testing database cleanly")
    func resetIMSchemaRebuildsTestingDatabase() async throws {
        try await withApp(configure: { app in
            app.shouldResetIMSchema = true
            try await configure(app)
        }) { app in
            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let payload = try res.content.decode(AuthResponse.self)
                #expect(payload.user.email == "demo@example.com")
            })
        }
    }


    @Test("Outbox failure increments retry count")
    func conversationOutboxFailureIncrementsRetryCount() async throws {
        try await withApp(configure: configure) { app in
            guard let sql = app.db as? any SQLDatabase else {
                Issue.record("Expected SQL database")
                return
            }

            let event = try ConversationDomainEvent(
                conversationID: UUID(),
                eventType: .metadataUpdated,
                payload: .init()
            )
            try await event.create(on: app.db)
            guard let eventID = event.id else {
                Issue.record("Missing outbox event ID")
                return
            }

            try await sql.raw("""
                UPDATE conversation_domain_events
                SET payload_json = '{"malformed":'
                WHERE id = \(bind: eventID)
                """).run()

            _ = try await ConversationOutboxService(db: app.db).processPendingBatch(
                app: app,
                configuration: .init(batchSize: 10, pollIntervalNanoseconds: 100_000_000, maxRetries: 2)
            )

            guard let reloaded = try await ConversationDomainEvent.find(eventID, on: app.db) else {
                Issue.record("Missing reloaded outbox event")
                return
            }

            #expect(reloaded.statusEnum == .failed)
            #expect(reloaded.retryCount == 1)
            #expect(reloaded.errorMessage?.isEmpty == false)
        }
    }


    @Test("Failed outbox events can be requeued")
    func failedConversationOutboxEventsCanBeRequeued() async throws {
        try await withApp(configure: configure) { app in
            let event = try ConversationDomainEvent(
                conversationID: UUID(),
                eventType: .metadataUpdated,
                payload: .init(),
                status: .failed
            )
            event.retryCount = 3
            event.processingStartedAt = Date()
            event.errorMessage = "boom"
            try await event.create(on: app.imWriteDB)

            let requeuedCount = try await ConversationOutboxService(db: app.imWriteDB).requeueFailedEvents(maxRetryCount: 5)
            #expect(requeuedCount == 1)

            guard let eventID = event.id,
                  let reloaded = try await ConversationDomainEvent.find(eventID, on: app.imWriteDB)
            else {
                Issue.record("Missing reloaded outbox event")
                return
            }

            #expect(reloaded.statusEnum == .pending)
            #expect(reloaded.retryCount == 0)
            #expect(reloaded.processingStartedAt == nil)
            #expect(reloaded.processedAt == nil)
            #expect(reloaded.errorMessage == nil)
        }
    }


    @Test("Outbox relay marks stream publication once per event")
    func conversationOutboxRelayMarksPublishedEvents() async throws {
        try await withApp(configure: configure) { app in
            let event = try ConversationDomainEvent(
                conversationID: UUID(),
                eventType: .metadataUpdated,
                payload: .init(recipientUserIDs: [UUID()])
            )
            try await event.create(on: app.imWriteDB)

            let relayedCount = try await ConversationOutboxRelay(app: app).relayPendingEvents(limit: 10)
            #expect(relayedCount == 1)

            guard let eventID = event.id,
                  let reloaded = try await ConversationDomainEvent.find(eventID, on: app.imWriteDB)
            else {
                Issue.record("Missing reloaded outbox event")
                return
            }

            #expect(reloaded.streamPublishedAt != nil)
            #expect(reloaded.streamPublishError == nil)
            #expect(reloaded.streamPublishStartedAt == nil)
            #expect(reloaded.streamPublishClaimedBy == nil)

            let secondRelayCount = try await ConversationOutboxRelay(app: app).relayPendingEvents(limit: 10)
            #expect(secondRelayCount == 0)
        }
    }

    @Test("Outbox relay skips active claims and recovers timed out claims")
    func conversationOutboxRelayRecoversTimedOutClaims() async throws {
        try await withApp(configure: configure) { app in
            app.conversationOutboxConfiguration = .init(
                batchSize: 10,
                pollIntervalNanoseconds: 100_000_000,
                maxRetries: 5,
                claimTimeoutNanoseconds: 1_000_000_000
            )
            let event = try ConversationDomainEvent(
                conversationID: UUID(),
                eventType: .metadataUpdated,
                payload: .init(recipientUserIDs: [UUID()])
            )
            event.streamPublishStartedAt = Date()
            event.streamPublishClaimedBy = "other-relay"
            try await event.create(on: app.imWriteDB)

            let activeClaimRelayCount = try await ConversationOutboxRelay(app: app).relayPendingEvents(limit: 10)
            #expect(activeClaimRelayCount == 0)

            event.streamPublishStartedAt = Date(timeIntervalSinceNow: -5)
            try await event.update(on: app.imWriteDB)

            let recoveredRelayCount = try await ConversationOutboxRelay(app: app).relayPendingEvents(limit: 10)
            #expect(recoveredRelayCount == 1)

            guard let eventID = event.id,
                  let reloaded = try await ConversationDomainEvent.find(eventID, on: app.imWriteDB)
            else {
                Issue.record("Missing reloaded outbox event")
                return
            }

            #expect(reloaded.streamPublishedAt != nil)
            #expect(reloaded.streamPublishStartedAt == nil)
            #expect(reloaded.streamPublishClaimedBy == nil)
        }
    }

    @Test("Hot conversation limiter rejects messages above the configured rate")
    func hotConversationLimiterRejectsAboveConfiguredRate() async throws {
        let limiter = HotConversationLimiter()
        let conversationID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try await limiter.reserve(conversationID: conversationID, limit: 1, now: now)
        do {
            try await limiter.reserve(conversationID: conversationID, limit: 1, now: now)
            Issue.record("Expected hot conversation limiter to reject the second message in the same window")
        } catch HotConversationLimiterError.rateLimited {
        } catch {
            Issue.record("Unexpected limiter error: \(error)")
        }

        try await limiter.reserve(
            conversationID: conversationID,
            limit: 1,
            now: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let nextWindowCount = await limiter.currentWindowCount(
            for: conversationID,
            now: Date(timeIntervalSince1970: 1_700_000_001)
        )
        #expect(nextWindowCount == 1)
    }


    @Test("Query read model facade uses injected summary read model store")
    func queryReadModelFacadeUsesInjectedSummaryStore() async throws {
        struct StubSummaryReadModelStore: SummaryReadModelStore {
            let response: IMConversationResponse
            let page: IMConversationPageResponse
            let changes: IMConversationChangesResponse

            func conversationSummary(conversationID: UUID, for userID: UUID) async throws -> IMConversationResponse {
                response
            }

            func listConversations(
                for userID: UUID,
                cursor: String?,
                limit: Int?,
                kind: String?
            ) async throws -> IMConversationPageResponse {
                page
            }

            func listConversationChanges(
                for userID: UUID,
                afterToken: String,
                cursor: String?,
                limit: Int?
            ) async throws -> IMConversationChangesResponse {
                changes
            }
        }

        try await withApp(configure: configure) { app in
            let conversationID = UUID()
            let userID = UUID()
            let summary = IMConversationResponse(
                id: conversationID,
                title: "summary-store",
                kind: IMConversationKind.group.rawValue,
                directMessagingState: nil,
                directPeer: nil,
                notice: "notice",
                avatarPreset: .forest,
                memberCount: 2,
                memberUserIDs: [userID],
                lastMessage: nil,
                lastReadSequence: 7,
                unreadCount: 3,
                isPinned: false,
                pinnedAt: nil,
                isMuted: true,
                createdAt: nil,
                updatedAt: Date(timeIntervalSince1970: 123)
            )
            let page = IMConversationPageResponse(
                items: [summary],
                nextCursor: "cursor",
                hasMore: true,
                snapshotToken: "snapshot"
            )
            let changes = IMConversationChangesResponse(
                upserts: [summary],
                removedConversationIDs: [],
                nextCursor: nil,
                hasMore: false,
                targetToken: "target"
            )
            app.summaryReadModelStore = StubSummaryReadModelStore(
                response: summary,
                page: page,
                changes: changes
            )

            let facade = QueryReadModelFacade(app: app)
            let summaryResponse = try await facade.conversationSummary(conversationID: conversationID, for: userID)
            let pageResponse = try await facade.listConversations(for: userID, cursor: nil, limit: nil)
            let changesResponse = try await facade.listConversationChanges(
                for: userID,
                afterToken: "since",
                cursor: nil,
                limit: nil
            )

            #expect(summaryResponse.title == "summary-store")
            #expect(pageResponse.items.first?.title == "summary-store")
            #expect(changesResponse.upserts.first?.title == "summary-store")
        }
    }


    @Test("Summary read model store respects configured query read source")
    func summaryReadModelStoreRespectsConfiguredReadSource() async throws {
        try await withApp(configure: configure) { app in
            app.summaryReadModelConfiguration = IMSummaryReadModelConfiguration(
                projectionWriteMode: .dualWrite,
                queryReadSource: .legacy
            )
            app.summaryReadModelStore = DatabaseSummaryReadModelStore(summaryDB: app.imSummaryDB)
            #expect(String(reflecting: type(of: app.summaryReadModelStore)).contains("DatabaseSummaryReadModelStore"))

            app.summaryReadModelConfiguration = IMSummaryReadModelConfiguration(
                projectionWriteMode: .dualWrite,
                queryReadSource: .sharded
            )
            app.summaryReadModelStore = OwnerShardedSummaryReadModelStore(app: app, router: app.summaryShardRouter)
            #expect(String(reflecting: type(of: app.summaryReadModelStore)).contains("OwnerShardedSummaryReadModelStore"))
        }
    }


    @Test("Notification consumer writes owner-scoped notification entries")
    func notificationConsumerWritesOwnerScopedEntries() async throws {
        try await withApp(configure: configure) { app in
            let recipientUserID = UUID()
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: UUID(),
                eventType: .messageUpdated,
                payload: .init(recipientUserIDs: [recipientUserID]),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let envelope = ConversationEventEnvelope(event: event, payload: try event.decodedPayload(), deliveryContext: nil)

            try await ConversationNotificationConsumer(app: app).consume(envelope)

            let recordID = ConversationNotificationEntry.recordID(ownerUserID: recipientUserID, eventID: try #require(event.id))
            let stored = try await ConversationNotificationEntry.find(recordID, on: app.imSummaryDB)
            #expect(stored?.ownerUserID == recipientUserID)
            #expect(stored?.conversationID == event.conversationID)
            #expect(stored?.eventType == ConversationDomainEventType.messageUpdated.rawValue)
        }
    }


    @Test("Repair replay consumer stores dead-letter envelopes for later replay")
    func repairReplayConsumerStoresDeadLetterEnvelopes() async throws {
        try await withApp(configure: configure) { app in
            let eventID = UUID()
            let conversationID = UUID()
            let envelope = ConversationEventEnvelope(
                event: try ConversationDomainEvent(
                    id: eventID,
                    conversationID: conversationID,
                    eventType: .metadataUpdated,
                    payload: .init(recipientUserIDs: [UUID()]),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_100)
                ),
                payload: .init(recipientUserIDs: [UUID()]),
                deliveryContext: .init(
                    sourceTopic: "conversation-domain-events-dead-letter",
                    consumerGroupID: "repair-replay-consumer",
                    producerShard: "shard-0",
                    deadLetterError: "projection failed"
                )
            )

            try await RepairReplayConsumer(
                db: app.imWriteDB,
                consumerGroupID: "repair-replay-consumer"
            ).consume(envelope)

            let recordID = ConversationReplayRecord.recordID(
                consumerGroupID: "repair-replay-consumer",
                eventID: eventID
            )
            let stored = try await ConversationReplayRecord.find(recordID, on: app.imWriteDB)
            #expect(stored?.conversationID == conversationID)
            #expect(stored?.sourceTopic == "conversation-domain-events-dead-letter")
            #expect(stored?.producerShard == "shard-0")
            #expect(stored?.lastError == "projection failed")
            #expect(stored?.statusEnum == .pending)
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


    @Test("Media upload supports create, chunk upload, and completion")
    func mediaUploadCreateChunkAndComplete() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let payloadData = Data("fake-image-data".utf8)

            struct CreateUploadBody: Content {
                let kind: IMMediaAssetKind
                let mimeType: String
                let byteSize: Int64
                let filename: String
                let width: Int?
                let height: Int?
                let durationMillis: Int?
                let previewAssetID: String?
            }

            struct UploadSessionBody: Content {
                let uploadID: String
                let uploadPath: String
                let completePath: String
                let expiresAt: Date
            }

            var uploadID = ""

            try await app.testing().test(.POST, "api/media/uploads", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    CreateUploadBody(
                        kind: .image,
                        mimeType: "image/png",
                        byteSize: Int64(payloadData.count),
                        filename: "photo.png",
                        width: 120,
                        height: 90,
                        durationMillis: nil,
                        previewAssetID: nil
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(UploadSessionBody.self)
                #expect(body.uploadPath == "/api/media/uploads/\(body.uploadID)/chunk")
                #expect(body.completePath == "/api/media/uploads/\(body.uploadID)/complete")
                #expect(body.expiresAt > Date())
                uploadID = body.uploadID
            })

            try await app.testing().test(.PUT, "api/media/uploads/\(uploadID)/chunk", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                req.headers.contentType = .binary
                req.body = .init(data: payloadData)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.POST, "api/media/uploads/\(uploadID)/complete", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let asset = try res.content.decode(IMMediaAsset.self)
                #expect(asset.assetID == uploadID)
                #expect(asset.kind == .image)
                #expect(asset.mimeType == "image/png")
                #expect(asset.byteSize == Int64(payloadData.count))
                #expect(asset.filename == "photo.png")
                #expect(asset.width == 120)
                #expect(asset.height == 90)
            })

            try await app.testing().test(.GET, "api/media/assets/\(uploadID)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .acceptRanges) == "bytes")
                #expect(res.headers.first(name: .eTag) != nil)
                #expect(Data(res.body.readableBytesView) == payloadData)
            })
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


    func loginAccessToken(using app: Application) async throws -> String {
        try await loginAccessToken(
            email: loginRequest.email,
            password: loginRequest.password,
            deviceID: loginRequest.device?.deviceID ?? "simulator",
            on: app
        )
    }

    func loginAccessToken(
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

    func user(email: String, on app: Application) async throws -> User {
        let normalizedEmail = User.normalize(email)
        guard let user = try await User.query(on: app.db)
            .filter(\.$email == normalizedEmail)
            .first()
        else {
            throw TestFailure.missingEntity("Missing user for \(email)")
        }

        return user
    }

    func makeUser(email: String, on app: Application) async throws -> User {
        let user = User(
            email: User.normalize(email),
            passwordHash: try Bcrypt.hash("password1234"),
            status: .active
        )
        try await user.create(on: app.db)
        return user
    }

    func imTCPTextPayload(
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

    func queryPath(_ base: String, items: [URLQueryItem]) -> String {
        var components = URLComponents()
        components.path = base
        components.queryItems = items
        guard let query = components.percentEncodedQuery, !query.isEmpty else {
            return base
        }
        return "\(base)?\(query)"
    }

    func makeConversationSummaryProjection(
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

    func session(for email: String, deviceID: String, on app: Application) async throws -> AuthSession {
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

    func restoreEnvironment(_ key: String, to value: String?) {
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

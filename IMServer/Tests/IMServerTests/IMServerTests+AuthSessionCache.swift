@testable import IMServer
import Vapor
import VaporTesting
import Testing

extension IMServerTests {
    @Test("Local auth session cache expires entries by TTL")
    func localAuthSessionCacheExpiresEntriesByTTL() async throws {
        let store = LocalAuthSessionPrincipalStore(maxEntries: 10)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let principal = try makeAuthSessionPrincipal(
            userID: UUID(),
            sessionID: UUID(),
            refreshExpiresAt: now.addingTimeInterval(60)
        )

        await store.store(principal, ttlSeconds: 5, now: now)

        let cached = await store.value(
            sessionID: principal.sessionID,
            userID: principal.userID,
            now: now.addingTimeInterval(4)
        )
        #expect(cached == principal)

        let expired = await store.value(
            sessionID: principal.sessionID,
            userID: principal.userID,
            now: now.addingTimeInterval(5)
        )
        #expect(expired == nil)
    }

    @Test("Local auth session cache evicts oldest entry at max entries")
    func localAuthSessionCacheEvictsOldestEntryAtMaxEntries() async throws {
        let store = LocalAuthSessionPrincipalStore(maxEntries: 1)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try makeAuthSessionPrincipal(
            userID: UUID(),
            sessionID: UUID(),
            refreshExpiresAt: now.addingTimeInterval(60)
        )
        let second = try makeAuthSessionPrincipal(
            userID: UUID(),
            sessionID: UUID(),
            refreshExpiresAt: now.addingTimeInterval(60)
        )

        await store.store(first, ttlSeconds: 30, now: now)
        await store.store(second, ttlSeconds: 30, now: now.addingTimeInterval(1))

        let evicted = await store.value(sessionID: first.sessionID, userID: first.userID, now: now.addingTimeInterval(2))
        let retained = await store.value(sessionID: second.sessionID, userID: second.userID, now: now.addingTimeInterval(2))
        #expect(evicted == nil)
        #expect(retained == second)
    }

    @Test("Local auth session cache invalidates by session and user")
    func localAuthSessionCacheInvalidatesBySessionAndUser() async throws {
        let store = LocalAuthSessionPrincipalStore(maxEntries: 10)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let userID = UUID()
        let first = try makeAuthSessionPrincipal(
            userID: userID,
            sessionID: UUID(),
            refreshExpiresAt: now.addingTimeInterval(60)
        )
        let second = try makeAuthSessionPrincipal(
            userID: userID,
            sessionID: UUID(),
            refreshExpiresAt: now.addingTimeInterval(60)
        )

        await store.store(first, ttlSeconds: 30, now: now)
        await store.store(second, ttlSeconds: 30, now: now)
        await store.invalidate(sessionID: first.sessionID)

        let sessionInvalidated = await store.value(sessionID: first.sessionID, userID: first.userID, now: now)
        let stillCached = await store.value(sessionID: second.sessionID, userID: second.userID, now: now)
        #expect(sessionInvalidated == nil)
        #expect(stillCached == second)

        await store.invalidate(userID: userID)

        let userInvalidated = await store.value(sessionID: second.sessionID, userID: second.userID, now: now)
        #expect(userInvalidated == nil)
    }

    @Test("Access auth cache avoids repeated database fallback")
    func accessAuthCacheAvoidsRepeatedDatabaseFallback() async throws {
        try await withLocalAuthSessionCache { app in
            let accessToken = try await loginAccessToken(using: app)

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            let metrics = await app.authSessionCacheMetrics.currentSnapshot()
            #expect(metrics.databaseFallbacks == 1)
            #expect(metrics.stores == 1)
            #expect(metrics.hits == 1)
        }
    }

    @Test("Logout invalidates cached access principal immediately")
    func logoutInvalidatesCachedAccessPrincipalImmediately() async throws {
        try await withLocalAuthSessionCache { app in
            let accessToken = try await loginAccessToken(using: app)

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.DELETE, "api/auth/sessions/current", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Profile update invalidates cached user snapshot")
    func profileUpdateInvalidatesCachedUserSnapshot() async throws {
        try await withLocalAuthSessionCache { app in
            let accessToken = try await loginAccessToken(using: app)
            var previousDisplayName: String?

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let profile = try res.content.decode(UserResponse.self)
                previousDisplayName = profile.displayName
            })

            try await app.testing().test(.PATCH, "api/me/profile", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    UserProfileUpdateRequest(
                        displayName: "Cached Profile",
                        avatarPreset: .forest
                    )
                )
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let profile = try res.content.decode(UserResponse.self)
                #expect(profile.displayName == "Cached Profile")
                #expect(profile.displayName != previousDisplayName)
                #expect(profile.avatarPreset == .forest)
            })
        }
    }

    private func withLocalAuthSessionCache(
        _ body: (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { app in
            try await configure(app)
            app.authSessionCacheConfiguration = AuthSessionCacheConfiguration(
                mode: .local,
                ttlSeconds: 5,
                maxEntries: 1_000,
                redisURL: nil
            )
            app.authSessionValidationCache = LocalAuthSessionValidationCache(
                ttlSeconds: 5,
                maxEntries: 1_000,
                metrics: app.authSessionCacheMetrics
            )
        }, body)
    }

    private func makeAuthSessionPrincipal(
        userID: UUID,
        sessionID: UUID,
        refreshExpiresAt: Date
    ) throws -> AuthenticatedPrincipal {
        let user = User(
            id: userID,
            email: "\(userID.uuidString.lowercased())@example.com",
            passwordHash: "hash",
            status: .active,
            displayName: nil,
            avatarPreset: nil
        )
        let session = AuthSession(
            id: sessionID,
            userID: userID,
            currentNonce: "nonce",
            refreshExpiresAt: refreshExpiresAt,
            deviceID: "device-\(sessionID.uuidString.lowercased())",
            deviceName: "Test Device",
            platform: "iOS",
            appVersion: "1.0",
            lastSeenAt: nil
        )
        return try AuthenticatedPrincipal(user: user, session: session)
    }
}

import HTTPTypes
import Foundation
import IMV2Core
import IMV2Server
@testable import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 password fallback routes", .serialized)
struct V2PasswordAccountRoutesTests {
    @Test("registration conflicts have distinct no-store business codes", arguments: [false, true])
    func registrationConflict(_ publicConflict: Bool) async throws {
        let app = try await Application(.testing)
        let store = PasswordAccountStoreFake(userID: .init(uuid: UUID()))
        await store.failRegistration(publicConflict ? .publicHandleAlreadyExists : .accountAlreadyExists)
        V2PasswordAccountRoutes(store: store, assertionIssuer: try .init(rawKey: Data(repeating: 8, count: 32)),
            passwords: testPasswordWorker(on: app), loginAttemptLimiter: AllowedPasswordAttemptLimiter()).register(on: app)
        do {
            try await app.testing { client in
                let response = try await client.send(.post, to: "v2/account-auth/password/register", beforeSend: { request in
                try request.content.encode(V2PasswordAccountHTTPRequest(accountHandle: "new-account", password: "valid-password",
                    deviceID: UUID().uuidString, publicHandle: "public_user", displayName: "User"))
            })
                #expect(response.status == .conflict)
                #expect(response.headers[.cacheControl] == "no-store")
                let body = try await response.content.decode([String: String].self)
                #expect(body["code"] == (publicConflict ? "public_handle_taken" : "account_handle_taken"))
            }
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("password fallback preserves all accepted UTF-8 bytes", arguments: [71, 72, 73, 1024])
    func passwordFullInput(_ bytes: Int) async throws {
        let app = try await Application(.testing)
        let store = PasswordAccountStoreFake(userID: .init(uuid: UUID()))
        let issuer = try V2HMACAccountAssertionIssuer(rawKey: Data(repeating: 4, count: 32))
        V2PasswordAccountRoutes(store: store, assertionIssuer: issuer,
            passwords: testPasswordWorker(on: app),
            loginAttemptLimiter: AllowedPasswordAttemptLimiter()).register(on: app)
        do {
            let password = String(repeating: "a", count: bytes - 1) + "x"
            let device = UUID().uuidString
            try await app.testing { client in
                let response = try await client.send(.post, to: "v2/account-auth/password/register", beforeSend: { request in
                try request.content.encode(V2PasswordAccountHTTPRequest(accountHandle: "length-test", password: password, deviceID: device, publicHandle: "length_test", displayName: "Length test"))
            })
 #expect(response.status == .ok)
            }
            #expect(await store.persistedPasswordHash()?.hasPrefix("$argon2id$v=19$") == true)
            for (candidate, expected) in [(password, HTTPResponse.Status.ok), (String(password.dropLast()) + "y", HTTPResponse.Status.unauthorized)] {
                try await app.testing { client in
                    let response = try await client.send(.post, to: "v2/account-auth/password/assertion", beforeSend: { request in
                    try request.content.encode(V2PasswordAccountHTTPRequest(accountHandle: "length-test", password: candidate, deviceID: device))
                })
 #expect(response.status == expected)
                }
            }
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("password fallback rejects embedded NUL before persistence", arguments: ["register", "assertion"])
    func passwordRejectsNUL(_ endpoint: String) async throws {
        let app = try await Application(.testing)
        let store = PasswordAccountStoreFake(userID: .init(uuid: UUID()))
        V2PasswordAccountRoutes(store: store,
            assertionIssuer: try .init(rawKey: Data(repeating: 5, count: 32)),
            passwords: testPasswordWorker(on: app),
            loginAttemptLimiter: AllowedPasswordAttemptLimiter()).register(on: app)
        do {
            try await app.testing { client in
                let response = try await client.send(.post, to: URI(string: "v2/account-auth/password/\(endpoint)"), beforeSend: { request in
                try request.content.encode(V2PasswordAccountHTTPRequest(accountHandle: "nul-test", password: "twelve-bytes-before\u{0}ignored", deviceID: UUID().uuidString, publicHandle: "nul_test", displayName: "NUL test"))
            })
 #expect(response.status == .badRequest)
            }
            #expect(await store.persistedPasswordHash() == nil)
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("saturated password work returns no-store 503 with a bounded retry", arguments: ["register", "assertion"])
    func passwordWorkOverload(_ endpoint: String) async throws {
        let app = try await Application(.testing)
        let store = PasswordAccountStoreFake(userID: .init(uuid: UUID()))
        V2PasswordAccountRoutes(store: store, assertionIssuer: try .init(rawKey: Data(repeating: 6, count: 32)),
            passwords: BusyPasswordHasher(), loginAttemptLimiter: AllowedPasswordAttemptLimiter()).register(on: app)
        do {
            try await app.testing { client in
                let response = try await client.send(.post, to: URI(string: "v2/account-auth/password/\(endpoint)"), beforeSend: { request in
                try request.content.encode(V2PasswordAccountHTTPRequest(accountHandle: "busy-test", password: "valid-password", deviceID: UUID().uuidString, publicHandle: "busy_test", displayName: "Busy test"))
            })
                #expect(response.status == .serviceUnavailable)
                #expect(response.headers[.cacheControl] == "no-store")
                #expect(response.headers[.retryAfter] == "1")
            }
            #expect(await store.persistedPasswordHash() == nil)
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test("account routes reject a direct caller without the edge proof")
    func accountEdgeProofIsRequired() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let proof = Data(repeating: 9, count: 32).base64EncodedString()
        let secret = try V2AccountEdgeAuthorizationSecret(base64Encoded: proof)
        app.middleware.use(V2AccountEdgeAuthenticationMiddleware(secret: secret))
        app.get("ready") { _ in "ok" }

        try await app.testing { client in
            let response = try await client.send(.get, to: "ready")
            #expect(response.status == .forbidden)
        }
        try await app.testing { client in
            let response = try await client.send(.get, to: "ready", beforeSend: { request in
            request.headers[V2AccountEdgeAuthenticationMiddleware.headerName] = proof
        })
            #expect(response.status == .forbidden)
        }
        try await app.testing { client in
            let response = try await client.send(.get, to: "ready", beforeSend: { request in
            request.headers[V2AccountEdgeAuthenticationMiddleware.headerName] = proof
            request.headers[V2AccountEdgeAuthenticationMiddleware.clientAddressHeaderName] = "127.0.0.1"
        })
            #expect(response.status == .ok)
            #expect((try await response.body.string() ?? "") == "ok")
        }
    }

    @Test("account edge limits only an authenticated Caddy-derived client address")
    func accountEdgeClientBudgetIsNoStoreAndFailsClosed() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let proof = Data(repeating: 7, count: 32).base64EncodedString()
        let secret = try V2AccountEdgeAuthorizationSecret(base64Encoded: proof)
        app.middleware.use(V2AccountEdgeAuthenticationMiddleware(secret: secret))
        app.middleware.use(V2AccountEdgeClientRateLimitMiddleware(limiter: FixedEdgeClientLimiter()))
        app.get("ready") { _ in "must not be reached" }

        try await app.testing { client in
            let response = try await client.send(.get, to: "ready", beforeSend: { request in
            request.headers[V2AccountEdgeAuthenticationMiddleware.headerName] = proof
            request.headers[V2AccountEdgeAuthenticationMiddleware.clientAddressHeaderName] = "not-an-address"
        })
            #expect(response.status == .forbidden)
        }
        try await app.testing { client in
            let response = try await client.send(.get, to: "ready", beforeSend: { request in
            request.headers[V2AccountEdgeAuthenticationMiddleware.headerName] = proof
            request.headers[V2AccountEdgeAuthenticationMiddleware.clientAddressHeaderName] = "2001:db8::1"
        })
            #expect(response.status == .tooManyRequests)
            #expect(response.headers[.cacheControl] == "no-store")
            #expect(response.headers[.pragma] == "no-cache")
            #expect(response.headers[.retryAfter] == "19")
            #expect((try await response.body.string() ?? "").isEmpty)
        }
    }

    @Test("account-edge limiter preserves an allowed route's client status")
    func accountEdgeClientBudgetDoesNotRewriteRouteErrors() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let proof = Data(repeating: 8, count: 32).base64EncodedString()
        let secret = try V2AccountEdgeAuthorizationSecret(base64Encoded: proof)
        app.middleware.use(V2AccountEdgeAuthenticationMiddleware(secret: secret))
        app.middleware.use(V2AccountEdgeClientRateLimitMiddleware(limiter: AllowedEdgeClientLimiter()))
        app.get("invalid") { _ throws -> Response in throw Abort(.badRequest) }

        try await app.testing { client in
            let response = try await client.send(.get, to: "invalid", beforeSend: { request in
            request.headers[V2AccountEdgeAuthenticationMiddleware.headerName] = proof
            request.headers[V2AccountEdgeAuthenticationMiddleware.clientAddressHeaderName] = "192.0.2.8"
        })
            #expect(response.status == .badRequest)
        }
    }

    @Test("running edge requests reject duplicate fields and do not reuse another request's identity")
    func edgeHeadersAreRequestScoped() async throws {
        try await withApp { app in
            let proof = Data(repeating: 0x37, count: 32).base64EncodedString()
            let limiter = RecordingEdgeClientLimiter()
            app.middleware.use(V2AccountEdgeAuthenticationMiddleware(secret: try .init(base64Encoded: proof)))
            app.middleware.use(V2AccountEdgeClientRateLimitMiddleware(limiter: limiter))
            app.get("ready") { _ in "ok" }
            let proofName = V2AccountEdgeAuthenticationMiddleware.headerName
            let addressName = V2AccountEdgeAuthenticationMiddleware.clientAddressHeaderName

            try await app.testing(.running) { client in
                for address in ["192.0.2.10", "192.0.2.11"] {
                    let response = try await client.get("ready", headers: [proofName: proof, addressName: address])
                    #expect(response.status == .ok)
                }
                let missing = try await client.get("ready", headers: [addressName: "192.0.2.10"])
                #expect(missing.status == .forbidden)

                for duplicate in [proofName, addressName] {
                    var headers: HTTPFields = [proofName: proof, addressName: "192.0.2.12"]
                    headers.append(HTTPField(name: duplicate, value: duplicate == proofName ? proof : "192.0.2.13"))
                    let response = try await client.get("ready", headers: headers)
                    #expect(response.status == .forbidden)
                }
                let recovered = try await client.get("ready", headers: [proofName: proof, addressName: "192.0.2.14"])
                #expect(recovered.status == .ok)
            }
            let expectedAddresses = [
                try V2AccountEdgeClientAddress("192.0.2.10"),
                try V2AccountEdgeClientAddress("192.0.2.11"),
                try V2AccountEdgeClientAddress("192.0.2.14"),
            ]
            #expect(await limiter.addresses == expectedAddresses)
        }
    }

    @Test("locked password fallback responses are no-store and expose the durable retry interval")
    func lockedPasswordAttemptReturnsNoStoreRetryAfter() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let store = PasswordAccountStoreTripwire()
        let assertionIssuer = try V2HMACAccountAssertionIssuer(rawKey: Data(repeating: 1, count: 32))
        V2PasswordAccountRoutes(
            store: store,
            assertionIssuer: assertionIssuer,
            passwords: testPasswordWorker(on: app),
            loginAttemptLimiter: BlockedPasswordAttemptLimiter(retryAfterSeconds: 47)
        ).register(on: app)

        let body = V2PasswordAccountHTTPRequest(
            accountHandle: "locked-account",
            password: "a-valid-length-password",
            deviceID: "00000000-0000-0000-0000-000000000901"
        )
        try await app.testing { client in
            let response = try await client.send(.post, to: "v2/account-auth/password/assertion", beforeSend: { request in
            try request.content.encode(body)
        })
            #expect(response.status == .tooManyRequests)
            #expect(response.headers[.cacheControl] == "no-store")
            #expect(response.headers[.pragma] == "no-cache")
            #expect(response.headers[.retryAfter] == "47")
            #expect((try await response.body.string() ?? "").isEmpty)
        }
        #expect(await store.calls == 0)
    }

    @Test("password registration missing public profile fields remains a bad request")
    func passwordRegistrationMissingPublicProfileReturnsBadRequest() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let passwordHasher = RecordingPasswordHasher()
        let store = PasswordAccountStoreTripwire()
        let assertionIssuer = try V2HMACAccountAssertionIssuer(rawKey: Data(repeating: 2, count: 32))
        V2PasswordAccountRoutes(
            store: store,
            assertionIssuer: assertionIssuer,
            passwords: passwordHasher,
            loginAttemptLimiter: BlockedPasswordAttemptLimiter(retryAfterSeconds: 1)
        ).register(on: app)

        let body = V2PasswordAccountHTTPRequest(
            accountHandle: "new-account",
            password: "a-valid-length-password",
            deviceID: "00000000-0000-0000-0000-000000000902"
        )
        try await app.testing { client in
            let response = try await client.send(.post, to: "v2/account-auth/password/register", beforeSend: { request in
            try request.content.encode(body)
        })
            #expect(response.status == .badRequest)
        }
        #expect(await passwordHasher.hashCallCount == 0)
        #expect(await store.calls == 0)
    }

    @Test("password transport depends on a store capability and never passes plaintext to persistence")
    func passwordRegistrationUsesAbstractStoreWithDigest() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let userID = try UserID("00000000-0000-0000-0000-000000000903")
        let store = PasswordAccountStoreFake(userID: userID)
        let assertionIssuer = try V2HMACAccountAssertionIssuer(rawKey: Data(repeating: 3, count: 32))
        V2PasswordAccountRoutes(
            store: store,
            assertionIssuer: assertionIssuer,
            passwords: testPasswordWorker(on: app),
            loginAttemptLimiter: AllowedPasswordAttemptLimiter()
        ).register(on: app)

        let plaintext = "a-valid-length-password"
        let body = V2PasswordAccountHTTPRequest(
            accountHandle: "new-account",
            password: plaintext,
            deviceID: "00000000-0000-0000-0000-000000000904",
            publicHandle: "new_public_handle",
            displayName: "New account"
        )
        try await app.testing { client in
            let response = try await client.send(.post, to: "v2/account-auth/password/register", beforeSend: { request in
            try request.content.encode(body)
        })
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "no-store")
        }

        let persistedHash = await store.persistedPasswordHash()
        #expect(persistedHash?.hasPrefix("$argon2id$v=19$") == true)
        #expect(persistedHash != plaintext)
    }
}

private struct BlockedPasswordAttemptLimiter: V2PasswordLoginAttemptLimiting {
    func consumeAttempt(accountHandle _: String) async throws -> Int? { retryAfterSeconds }
    func auditRejectedAttempt(accountHandle _: String, userID _: UserID?, deviceID _: DeviceID) async throws {}
    let retryAfterSeconds: Int

    func blockedRetryAfterSeconds(accountHandle _: String) async throws -> Int? { retryAfterSeconds }
    func recordRejectedAttempt(accountHandle _: String, userID _: UserID?, deviceID _: DeviceID) async throws {}
    func recordSuccessfulAttempt(accountHandle _: String, userID _: UserID, deviceID _: DeviceID) async throws {}
}

private struct AllowedPasswordAttemptLimiter: V2PasswordLoginAttemptLimiting {
    func consumeAttempt(accountHandle _: String) async throws -> Int? { nil }
    func auditRejectedAttempt(accountHandle _: String, userID _: UserID?, deviceID _: DeviceID) async throws {}
    func blockedRetryAfterSeconds(accountHandle _: String) async throws -> Int? { nil }
    func recordRejectedAttempt(accountHandle _: String, userID _: UserID?, deviceID _: DeviceID) async throws {}
    func recordSuccessfulAttempt(accountHandle _: String, userID _: UserID, deviceID _: DeviceID) async throws {}
}

private actor RecordingPasswordHasher: V2PasswordHashing {
    private(set) var hashCallCount = 0
    func hash(_ password: String) async throws -> String { hashCallCount += 1; return "unused" }
    func verify(_ password: String, created digest: String) async throws -> Bool { false }
}

private func testPasswordWorker(on app: Application) -> V2PasswordHashWorker {
    let worker = V2PasswordHashWorker()
    app.addLifecycleHandler(TestPasswordWorkerLifecycle(worker: worker))
    return worker
}
private struct TestPasswordWorkerLifecycle: LifecycleHandler {
    let worker: V2PasswordHashWorker
    func shutdown(_ application: Application) async { try? await worker.shutdown() }
}

private actor PasswordAccountStoreFake: V2PasswordAccountStoring {
    private let userID: UserID
    private var passwordHash: String?
    private var registrationFailure: V2PasswordAccountStoreError?

    init(userID: UserID) {
        self.userID = userID
    }

    func register(
        accountHandle _: String,
        passwordHash: String,
        publicHandle _: String,
        displayName _: String,
        deviceID _: DeviceID
    ) async throws -> UserID {
        if let registrationFailure { throw registrationFailure }
        self.passwordHash = passwordHash
        return userID
    }

    func passwordCredential(for _: String) async throws -> V2PasswordCredential? { passwordHash.map { .init(userID: userID, passwordHash: $0) } }

    func completeAuthentication(accountHandle: String, expected: V2PasswordCredential, deviceID: DeviceID) async throws -> Bool {
        expected.userID == userID && expected.passwordHash == passwordHash
    }
    func failRegistration(_ error: V2PasswordAccountStoreError) { registrationFailure = error }
    func seedPasswordHash(_ digest: String) { passwordHash = digest }

    func persistedPasswordHash() -> String? { passwordHash }
}

private actor PasswordAccountStoreTripwire: V2PasswordAccountStoring {
    private(set) var calls = 0

    func register(
        accountHandle _: String,
        passwordHash _: String,
        publicHandle _: String,
        displayName _: String,
        deviceID _: DeviceID
    ) async throws -> UserID {
        calls += 1
        throw UnexpectedCall.store
    }

    func passwordCredential(for _: String) async throws -> V2PasswordCredential? {
        calls += 1
        throw UnexpectedCall.store
    }

    func completeAuthentication(accountHandle _: String, expected _: V2PasswordCredential, deviceID _: DeviceID) async throws -> Bool {
        calls += 1
        throw UnexpectedCall.store
    }

    private enum UnexpectedCall: Error { case store }
}

private struct FixedEdgeClientLimiter: V2AccountEdgeClientRateLimiting {
    func consume(address _: V2AccountEdgeClientAddress) async throws -> V2AccountEdgeClientRateLimitResult {
        .rateLimited(retryAfterSeconds: 19)
    }
}

private struct AllowedEdgeClientLimiter: V2AccountEdgeClientRateLimiting {
    func consume(address _: V2AccountEdgeClientAddress) async throws -> V2AccountEdgeClientRateLimitResult {
        .allowed
    }
}

private actor RecordingEdgeClientLimiter: V2AccountEdgeClientRateLimiting {
    private(set) var addresses: [V2AccountEdgeClientAddress] = []
    func consume(address: V2AccountEdgeClientAddress) async throws -> V2AccountEdgeClientRateLimitResult {
        addresses.append(address)
        return .allowed
    }
}

private struct BusyPasswordHasher: V2PasswordHashing {
    func hash(_ password: String) async throws -> String { throw V2PasswordHashError.busy }
    func verify(_ password: String, created digest: String) async throws -> Bool { throw V2PasswordHashError.busy }
}

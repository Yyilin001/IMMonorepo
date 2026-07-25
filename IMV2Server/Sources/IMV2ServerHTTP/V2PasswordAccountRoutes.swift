import Fluent
import Foundation
import IMV2Core
import IMV2Server
import SQLKit
import Vapor

public enum V2PasswordAccountStoreError: Error, Equatable, Sendable {
    case invalidAccountHandle
    case invalidPublicIdentity
    case accountAlreadyExists
    case publicHandleAlreadyExists
    case unavailable
}

/// Database boundary for the V2 password fallback. The route performs bcrypt
/// on Vapor's worker pool before it reaches this store, keeping CPU-bound work
/// off the event loop and plaintext passwords out of persistence APIs.
public struct V2PostgresPasswordAccountStore: Sendable {
    private let database: any Database
    private let now: @Sendable () -> Date

    public init(database: any Database, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.now = now
    }

    public func register(
        accountHandle: String,
        passwordHash: String,
        publicHandle: String,
        displayName: String,
        deviceID: DeviceID
    ) async throws -> UserID {
        let handle = try canonicalAccountHandle(accountHandle)
        let userUUID = UUID()
        let identity: V2PublicIdentity
        do {
            identity = try .init(userID: .init(userUUID.uuidString), handle: .init(publicHandle), displayName: displayName)
        } catch {
            throw V2PasswordAccountStoreError.invalidPublicIdentity
        }
        guard !passwordHash.isEmpty else { throw V2PasswordAccountStoreError.unavailable }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2PasswordAccountStoreError.unavailable }
            let current = now()
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "v2-account:" + handle), 0))").run()
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "v2-public-handle:" + identity.handle.rawValue), 0))").run()
            guard try await sql.raw("SELECT 1 FROM im_v2.account_password_credentials WHERE account_handle = \(bind: handle)").first() == nil else {
                throw V2PasswordAccountStoreError.accountAlreadyExists
            }
            guard try await sql.raw("SELECT 1 FROM im_v2.public_user_profiles WHERE public_handle = \(bind: identity.handle.rawValue)").first() == nil else {
                throw V2PasswordAccountStoreError.publicHandleAlreadyExists
            }
            try await sql.raw("INSERT INTO im_v2.account_password_credentials (account_handle, user_id, password_hash, created_at) VALUES (\(bind: handle), \(bind: userUUID), \(bind: passwordHash), \(bind: current))").run()
            try await sql.raw("INSERT INTO im_v2.public_user_profiles (user_id, public_handle, display_name, revision, created_at, updated_at) VALUES (\(bind: userUUID), \(bind: identity.handle.rawValue), \(bind: identity.displayName), 1, \(bind: current), \(bind: current))").run()
            try await recordPasswordAuthenticationAudit(
                outcome: .registrationSucceeded,
                userID: identity.userID,
                deviceID: deviceID,
                occurredAt: current,
                on: sql
            )
            return identity.userID
        }
    }

    public func passwordCredential(for accountHandle: String) async throws -> V2PasswordCredential? {
        let handle = try canonicalAccountHandle(accountHandle)
        guard let sql = database as? any SQLDatabase else { throw V2PasswordAccountStoreError.unavailable }
        guard let row = try await sql.raw("SELECT user_id, password_hash FROM im_v2.account_password_credentials WHERE account_handle = \(bind: handle)").first(decoding: PasswordCredentialRow.self),
              let userID = try? UserID(row.userID.uuidString)
        else { return nil }
        return .init(userID: userID, passwordHash: row.passwordHash)
    }
}

public struct V2PasswordCredential: Equatable, Sendable {
    public let userID: UserID
    public let passwordHash: String
}

/// `POST /v2/account-auth/password/*` is deliberately a fallback surface.
/// Both endpoints bind the returned assertion to the requested device, use
/// `no-store`, and run bcrypt through Vapor's configured worker pool.
public struct V2PasswordAccountRoutes: Sendable {
    private let store: V2PostgresPasswordAccountStore
    private let assertionIssuer: V2HMACAccountAssertionIssuer
    private let dummyPasswordHash: String
    private let loginAttemptLimiter: any V2PasswordLoginAttemptLimiting

    /// `dummyPasswordHash` must be a valid bcrypt digest at the same cost as
    /// the configured application password hasher. It equalizes unknown-handle
    /// and wrong-password work without treating a missing account as success.
    public init(
        store: V2PostgresPasswordAccountStore,
        assertionIssuer: V2HMACAccountAssertionIssuer,
        dummyPasswordHash: String,
        loginAttemptLimiter: any V2PasswordLoginAttemptLimiting
    ) {
        self.store = store
        self.assertionIssuer = assertionIssuer
        self.dummyPasswordHash = dummyPasswordHash
        self.loginAttemptLimiter = loginAttemptLimiter
    }

    public func register(on routes: RoutesBuilder) {
        routes.post("v2", "account-auth", "password", "register") { request async throws -> Response in
            let input = try request.content.decode(V2PasswordAccountHTTPRequest.self)
            let deviceID = try parsedDeviceID(input.deviceID)
            do {
                try validatePassword(input.password)
                let passwordHash = try await request.password.async.hash(input.password).get()
                guard let publicHandle = input.publicHandle, let displayName = input.displayName else { throw Abort(.badRequest) }
                let userID = try await store.register(
                    accountHandle: input.accountHandle,
                    passwordHash: passwordHash,
                    publicHandle: publicHandle,
                    displayName: displayName,
                    deviceID: deviceID
                )
                return try noStoreJSONResponse(.init(accountAssertion: try assertionIssuer.issue(userID: userID, deviceID: deviceID)))
            } catch V2PasswordAccountStoreError.accountAlreadyExists {
                throw Abort(.conflict)
            } catch V2PasswordAccountStoreError.publicHandleAlreadyExists {
                throw Abort(.conflict)
            } catch V2PasswordAccountStoreError.invalidAccountHandle {
                throw Abort(.badRequest)
            } catch V2PasswordAccountStoreError.invalidPublicIdentity {
                throw Abort(.badRequest)
            } catch V2PasswordRouteError.invalidPassword {
                throw Abort(.badRequest)
            } catch {
                throw Abort(.serviceUnavailable)
            }
        }

        routes.post("v2", "account-auth", "password", "assertion") { request async throws -> Response in
            let input = try request.content.decode(V2PasswordAccountHTTPRequest.self)
            let deviceID = try parsedDeviceID(input.deviceID)
            do {
                try validatePassword(input.password)
                _ = try canonicalAccountHandle(input.accountHandle)
                if let retryAfter = try await loginAttemptLimiter.blockedRetryAfterSeconds(accountHandle: input.accountHandle) {
                    return noStoreRetryAfterResponse(seconds: retryAfter)
                }
                let credential = try await store.passwordCredential(for: input.accountHandle)
                let candidateHash = credential?.passwordHash ?? dummyPasswordHash
                let matches = try await request.password.async.verify(input.password, created: candidateHash).get()
                guard let credential, matches else {
                    try await loginAttemptLimiter.recordRejectedAttempt(
                        accountHandle: input.accountHandle,
                        userID: credential?.userID,
                        deviceID: deviceID
                    )
                    throw V2PasswordRouteError.rejected
                }
                try await loginAttemptLimiter.recordSuccessfulAttempt(
                    accountHandle: input.accountHandle,
                    userID: credential.userID,
                    deviceID: deviceID
                )
                return try noStoreJSONResponse(.init(accountAssertion: try assertionIssuer.issue(userID: credential.userID, deviceID: deviceID)))
            } catch V2PasswordRouteError.rejected {
                throw Abort(.unauthorized)
            } catch V2PasswordAccountStoreError.invalidAccountHandle {
                throw Abort(.badRequest)
            } catch V2PasswordRouteError.invalidPassword {
                throw Abort(.badRequest)
            } catch {
                throw Abort(.serviceUnavailable)
            }
        }
    }

    private func parsedDeviceID(_ value: String) throws -> DeviceID {
        guard let deviceID = try? DeviceID(value) else { throw Abort(.badRequest) }
        return deviceID
    }

    private func validatePassword(_ password: String) throws {
        guard password.utf8.count >= 12, password.utf8.count <= 1_024 else { throw V2PasswordRouteError.invalidPassword }
    }

    private func noStoreJSONResponse(_ response: V2AccountAssertionHTTPResponse) throws -> Response {
        let data = try JSONEncoder().encode(response)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        return .init(status: .ok, headers: headers, body: .init(data: data))
    }

    private func noStoreRetryAfterResponse(seconds: Int) -> Response {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        headers.replaceOrAdd(name: "Retry-After", value: String(seconds))
        return .init(status: .tooManyRequests, headers: headers)
    }
}

public struct V2PasswordAccountHTTPRequest: Content, Sendable {
    public let accountHandle: String
    public let password: String
    public let deviceID: String
    public let publicHandle: String?
    public let displayName: String?

    public init(accountHandle: String, password: String, deviceID: String, publicHandle: String? = nil, displayName: String? = nil) {
        self.accountHandle = accountHandle
        self.password = password
        self.deviceID = deviceID
        self.publicHandle = publicHandle
        self.displayName = displayName
    }
}

public struct V2AccountAssertionHTTPResponse: Content, Sendable {
    public let accountAssertion: String
}

private enum V2PasswordRouteError: Error { case invalidPassword, rejected }

private struct PasswordCredentialRow: Decodable {
    let userID: UUID
    let passwordHash: String
    enum CodingKeys: String, CodingKey { case userID = "user_id"; case passwordHash = "password_hash" }
}

func canonicalAccountHandle(_ value: String) throws -> String {
    let normalized = value.lowercased()
    let scalars = normalized.unicodeScalars
    guard (3 ... 64).contains(scalars.count), scalars.allSatisfy({ scalar in
        (48 ... 57).contains(scalar.value) ||
        (97 ... 122).contains(scalar.value) ||
        scalar == "_" || scalar == "-"
    }) else { throw V2PasswordAccountStoreError.invalidAccountHandle }
    return normalized
}

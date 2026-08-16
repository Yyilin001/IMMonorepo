import Fluent
import Foundation
import IMV2Core
import SQLKit

public enum V2PasswordAccountStoreError: Error, Equatable, Sendable {
    case invalidAccountHandle
    case invalidPublicIdentity
    case accountAlreadyExists
    case publicHandleAlreadyExists
    case unavailable
}

public struct V2PasswordCredential: Equatable, Sendable {
    public let userID: UserID
    public let passwordHash: String

    public init(userID: UserID, passwordHash: String) {
        self.userID = userID
        self.passwordHash = passwordHash
    }
}

/// Persistence boundary for the password fallback. Plaintext password work
/// belongs to the HTTP adapter's worker pool; this capability only accepts a
/// completed password digest and returns domain identities/credentials.
public protocol V2PasswordAccountStoring: Sendable {
    func register(
        accountHandle: String,
        passwordHash: String,
        publicHandle: String,
        displayName: String,
        deviceID: DeviceID
    ) async throws -> UserID
    func passwordCredential(for accountHandle: String) async throws -> V2PasswordCredential?
}

public struct V2PostgresPasswordAccountStore: V2PasswordAccountStoring, Sendable {
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
            identity = try .init(
                userID: .init(userUUID.uuidString),
                handle: .init(publicHandle),
                displayName: displayName,
                accountKind: .regular
            )
        } catch {
            throw V2PasswordAccountStoreError.invalidPublicIdentity
        }
        guard !passwordHash.isEmpty else { throw V2PasswordAccountStoreError.unavailable }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2PasswordAccountStoreError.unavailable
            }
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
            try await sql.raw("INSERT INTO im_v2.public_user_profiles (user_id, public_handle, display_name, account_kind, revision, created_at, updated_at) VALUES (\(bind: userUUID), \(bind: identity.handle.rawValue), \(bind: identity.displayName), \(bind: identity.accountKind.rawValue), 1, \(bind: current), \(bind: current))").run()
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
        guard let sql = database as? any SQLDatabase else {
            throw V2PasswordAccountStoreError.unavailable
        }
        guard let row = try await sql.raw("SELECT credential.user_id, credential.password_hash FROM im_v2.account_password_credentials AS credential LEFT JOIN im_v2.account_disables AS disabled ON disabled.user_id = credential.user_id WHERE credential.account_handle = \(bind: handle) AND disabled.user_id IS NULL").first(decoding: PasswordCredentialRow.self),
              let userID = try? UserID(row.userID.uuidString)
        else { return nil }
        return .init(userID: userID, passwordHash: row.passwordHash)
    }
}

public func canonicalAccountHandle(_ value: String) throws -> String {
    let normalized = value.lowercased()
    let scalars = normalized.unicodeScalars
    guard (3 ... 64).contains(scalars.count), scalars.allSatisfy({ scalar in
        (48 ... 57).contains(scalar.value) ||
        (97 ... 122).contains(scalar.value) ||
        scalar == "_" || scalar == "-"
    }) else { throw V2PasswordAccountStoreError.invalidAccountHandle }
    return normalized
}

private struct PasswordCredentialRow: Decodable {
    let userID: UUID
    let passwordHash: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case passwordHash = "password_hash"
    }
}

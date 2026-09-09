import Crypto
import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Provider identifiers are deliberately narrow. Adding a new provider is a
/// reviewed server-side change rather than a client-controlled string.
public enum V2PushEndpointProvider: String, Codable, Equatable, Sendable {
    case apns
}

public enum V2PushEndpointEnvironment: String, Codable, Equatable, Sendable {
    case development
    case production
}

/// Registration is authenticated as the exact device that will receive the
/// wake. The provider token is opaque and is never suitable for logs, metrics,
/// event payloads, or user-sync records.
public struct V2PushDeviceEndpointRegistration: Equatable, Sendable {
    public let provider: V2PushEndpointProvider
    public let environment: V2PushEndpointEnvironment
    public let token: String

    public init(provider: V2PushEndpointProvider, environment: V2PushEndpointEnvironment, token: String) throws {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 4_096,
              normalized.unicodeScalars.allSatisfy({
                  !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0)
              })
        else { throw V2PushDeviceEndpointError.invalidRegistration }
        self.provider = provider
        self.environment = environment
        self.token = normalized
    }
}

/// Plaintext exists only between the encrypted persistence boundary and the
/// configured provider adapter. The generation prevents a late provider
/// rejection from disabling a newer endpoint registration for the same device.
public struct V2PushDeviceEndpoint: Equatable, Sendable {
    public let deviceID: DeviceID
    public let provider: V2PushEndpointProvider
    public let environment: V2PushEndpointEnvironment
    public let token: String
    public let generation: UUID

    public init(deviceID: DeviceID, provider: V2PushEndpointProvider, environment: V2PushEndpointEnvironment, token: String, generation: UUID) {
        self.deviceID = deviceID
        self.provider = provider
        self.environment = environment
        self.token = token
        self.generation = generation
    }
}

public enum V2PushDeviceEndpointError: Error, Equatable, Sendable {
    case invalidRegistration
    case deviceUnavailable
    case unavailable
    case malformedPersistence
    case intentVersionRequired
    case staleIntent
    case intentConflict
}

/// Separate deployment-secret material from credential replay encryption.
/// Compromise of an account replay envelope must not decrypt provider endpoint
/// material, and vice versa.
public struct V2PushEndpointEnvelopeKey: Sendable {
    private let rawBytes: Data

    public init(rawBytes: Data) throws {
        guard rawBytes.count == 32 else { throw V2PushDeviceEndpointError.unavailable }
        self.rawBytes = rawBytes
    }

    public init(base64Encoded value: String) throws {
        guard let bytes = Data(base64Encoded: value) else { throw V2PushDeviceEndpointError.unavailable }
        try self.init(rawBytes: bytes)
    }

    fileprivate func seal(_ plaintext: String, authenticating context: Data) throws -> String {
        let box = try ChaChaPoly.seal(Data(plaintext.utf8), using: SymmetricKey(data: rawBytes), authenticating: context)
        return box.combined.base64EncodedString()
    }

    fileprivate func open(_ ciphertext: String, authenticating context: Data) throws -> String {
        guard let combined = Data(base64Encoded: ciphertext) else { throw V2PushDeviceEndpointError.malformedPersistence }
        let box = try ChaChaPoly.SealedBox(combined: combined)
        let plaintext = try ChaChaPoly.open(box, using: SymmetricKey(data: rawBytes), authenticating: context)
        guard let value = String(data: plaintext, encoding: .utf8),
              !value.isEmpty,
              value.utf8.count <= 4_096
        else { throw V2PushDeviceEndpointError.malformedPersistence }
        return value
    }

    fileprivate func intentDigest(_ bytes: Data) -> Data {
        let derived = HMAC<SHA256>.authenticationCode(for: Data("im-v2-push-intent-digest-v1".utf8), using: SymmetricKey(data: rawBytes))
        return Data(HMAC<SHA256>.authenticationCode(for: bytes, using: SymmetricKey(data: Data(derived))))
    }
}

public protocol V2PushDeviceEndpointStore: Sendable {
    func register(
        actorUserID: UserID,
        deviceID: DeviceID,
        endpoint: V2PushDeviceEndpointRegistration,
        now: Date
    ) async throws
    func endpoint(for deviceID: DeviceID) async throws -> V2PushDeviceEndpoint?
    func disable(_ endpoint: V2PushDeviceEndpoint, now: Date) async throws
    func disableOwnedEndpoint(
        actorUserID: UserID,
        deviceID: DeviceID,
        now: Date
    ) async throws
}

public extension V2PushDeviceEndpointStore {
    /// Compatibility implementation for stores that do not own an atomic
    /// identity-aware update. PostgreSQL overrides this to avoid reading and
    /// decrypting provider material for a user-initiated delete.
    func disableOwnedEndpoint(
        actorUserID _: UserID,
        deviceID: DeviceID,
        now: Date
    ) async throws {
        if let endpoint = try await endpoint(for: deviceID) {
            try await disable(endpoint, now: now)
        }
    }
}

/// Encrypts opaque provider tokens at rest and checks the active device inside
/// the same transaction that updates endpoint state. Nothing in fan-out,
/// user-sync, or Push outbox stores a provider token.
public struct PostgresV2PushDeviceEndpointStore: V2PushDeviceEndpointStore {
    private let database: any Database
    private let envelopeKey: V2PushEndpointEnvelopeKey
    private let makeUUID: @Sendable () -> UUID

    public init(
        database: any Database,
        envelopeKey: V2PushEndpointEnvelopeKey,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.database = database
        self.envelopeKey = envelopeKey
        self.makeUUID = makeUUID
    }

    public func register(
        actorUserID: UserID,
        deviceID: DeviceID,
        endpoint: V2PushDeviceEndpointRegistration,
        now: Date
    ) async throws {
        let userUUID = try endpointUUID(actorUserID)
        let deviceUUID = try endpointUUID(deviceID)
        guard v2PostgresTimestampCanEncode(now) else { throw V2PushDeviceEndpointError.unavailable }
        let generation = makeUUID()
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2PushDeviceEndpointError.unavailable }
            guard try await sql.raw("""
                SELECT 1
                FROM im_v2.auth_devices
                WHERE user_id = \(bind: userUUID)
                  AND device_id = \(bind: deviceUUID)
                  AND revoked_at IS NULL AND session_expires_at > \(bind: now)
                FOR UPDATE
                """).first() != nil
            else { throw V2PushDeviceEndpointError.deviceUnavailable }

            guard try await sql.raw("SELECT 1 FROM im_v2.push_device_intents WHERE device_id = \(bind: deviceUUID)").first() == nil else {
                throw V2PushDeviceEndpointError.intentVersionRequired
            }

            let encryptedToken = try envelopeKey.seal(
                endpoint.token,
                authenticating: endpointContext(
                    deviceID: deviceID,
                    provider: endpoint.provider,
                    environment: endpoint.environment,
                    generation: generation
                )
            )
            try await sql.raw("""
                INSERT INTO im_v2.push_device_endpoints
                    (device_id, provider, environment, endpoint_generation, encrypted_token, updated_at, disabled_at)
                VALUES
                    (\(bind: deviceUUID), \(bind: endpoint.provider.rawValue), \(bind: endpoint.environment.rawValue),
                     \(bind: generation), \(bind: encryptedToken), \(bind: now), NULL)
                ON CONFLICT (device_id, provider)
                DO UPDATE SET environment = EXCLUDED.environment,
                              endpoint_generation = EXCLUDED.endpoint_generation,
                              encrypted_token = EXCLUDED.encrypted_token,
                              updated_at = EXCLUDED.updated_at,
                              disabled_at = NULL
                """).run()
        }
    }

    public func endpoint(for deviceID: DeviceID) async throws -> V2PushDeviceEndpoint? {
        guard let sql = database as? any SQLDatabase else { throw V2PushDeviceEndpointError.unavailable }
        let deviceUUID = try endpointUUID(deviceID)
        guard let row = try await sql.raw("""
            SELECT endpoint.provider, endpoint.environment, endpoint.endpoint_generation, endpoint.encrypted_token
            FROM im_v2.push_device_endpoints AS endpoint
            JOIN im_v2.auth_devices AS device ON device.device_id = endpoint.device_id
            WHERE endpoint.device_id = \(bind: deviceUUID)
              AND endpoint.disabled_at IS NULL
              AND device.revoked_at IS NULL AND device.session_expires_at > clock_timestamp()
            ORDER BY endpoint.updated_at DESC
            LIMIT 1
            """).first(decoding: PushEndpointRow.self)
        else { return nil }
        guard let provider = V2PushEndpointProvider(rawValue: row.provider),
              let environment = V2PushEndpointEnvironment(rawValue: row.environment)
        else { throw V2PushDeviceEndpointError.malformedPersistence }
        let token = try envelopeKey.open(
            row.encryptedToken,
            authenticating: endpointContext(
                deviceID: deviceID,
                provider: provider,
                environment: environment,
                generation: row.generation
            )
        )
        return .init(deviceID: deviceID, provider: provider, environment: environment, token: token, generation: row.generation)
    }

    public func disable(_ endpoint: V2PushDeviceEndpoint, now: Date) async throws {
        guard v2PostgresTimestampCanEncode(now),
              let sql = database as? any SQLDatabase else { throw V2PushDeviceEndpointError.unavailable }
        let deviceUUID = try endpointUUID(endpoint.deviceID)
        try await sql.raw("""
            UPDATE im_v2.push_device_endpoints
            SET disabled_at = COALESCE(disabled_at, \(bind: now)),
                updated_at = \(bind: now)
            WHERE device_id = \(bind: deviceUUID)
              AND provider = \(bind: endpoint.provider.rawValue)
              AND endpoint_generation = \(bind: endpoint.generation)
              AND disabled_at IS NULL
            """).run()
    }

    public func disableOwnedEndpoint(actorUserID: UserID, deviceID: DeviceID, now: Date) async throws {
        let user = try endpointUUID(actorUserID), device = try endpointUUID(deviceID)
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2PushDeviceEndpointError.unavailable }
            try await lockIntentDevice(user: user, device: device, sql: sql)
            guard try await sql.raw("SELECT 1 FROM im_v2.push_device_intents WHERE device_id = \(bind: device)").first() == nil else { throw V2PushDeviceEndpointError.intentVersionRequired }
            guard v2PostgresTimestampCanEncode(now) else { throw V2PushDeviceEndpointError.unavailable }
            try await sql.raw("UPDATE im_v2.push_device_endpoints SET disabled_at = COALESCE(disabled_at, \(bind: now)), updated_at = \(bind: now) WHERE device_id = \(bind: device) AND disabled_at IS NULL").run()
        }
    }

    private func endpointContext(
        deviceID: DeviceID,
        provider: V2PushEndpointProvider,
        environment: V2PushEndpointEnvironment,
        generation: UUID
    ) -> Data {
        Data("im-v2-push-endpoint|\(deviceID.rawValue)|\(provider.rawValue)|\(environment.rawValue)|\(generation.uuidString)".utf8)
    }
}

private struct PushEndpointRow: Decodable {
    let provider: String
    let environment: String
    let generation: UUID
    let encryptedToken: String

    enum CodingKeys: String, CodingKey {
        case provider, environment
        case generation = "endpoint_generation"
        case encryptedToken = "encrypted_token"
    }
}

private func endpointUUID(_ identifier: UserID) throws -> UUID {
    guard let value = UUID(uuidString: identifier.rawValue) else { throw V2PushDeviceEndpointError.malformedPersistence }
    return value
}

private func endpointUUID(_ identifier: DeviceID) throws -> UUID {
    guard let value = UUID(uuidString: identifier.rawValue) else { throw V2PushDeviceEndpointError.malformedPersistence }
    return value
}

public enum V2PushEndpointIntent: Sendable {
    case enabled(V2PushDeviceEndpointRegistration)
    case disabled
}

/// Required conditional-write capability for the versioned HTTP contract.
/// Epochs and revisions contain no provider token and grant no authentication.
public protocol V2PushEndpointIntentStoring: Sendable {
    func intentEpoch(actorUserID: UserID, deviceID: DeviceID) async throws -> UInt64
    func claimIntentSession(actorUserID: UserID, deviceID: DeviceID, claim: V2PushIntentSessionClaim, now: Date) async throws -> UInt64
    func publishIntent(actorUserID: UserID, deviceID: DeviceID, version: V2PushIntentVersion, intent: V2PushEndpointIntent, now: Date) async throws
}

extension PostgresV2PushDeviceEndpointStore: V2PushEndpointIntentStoring {
    public func intentEpoch(actorUserID: UserID, deviceID: DeviceID) async throws -> UInt64 {
        guard let sql = database as? any SQLDatabase else { throw V2PushDeviceEndpointError.unavailable }
        let user = try endpointUUID(actorUserID), device = try endpointUUID(deviceID)
        guard let row = try await sql.raw("""
            SELECT COALESCE(intent.session_epoch, 0) AS epoch
            FROM im_v2.auth_devices AS device
            LEFT JOIN im_v2.push_device_intents AS intent ON intent.device_id = device.device_id
            WHERE device.user_id = \(bind: user) AND device.device_id = \(bind: device) AND device.revoked_at IS NULL AND device.session_expires_at > clock_timestamp()
            """).first(decoding: PushIntentEpochRow.self), row.epoch >= 0 else { throw V2PushDeviceEndpointError.deviceUnavailable }
        return UInt64(row.epoch)
    }

    public func claimIntentSession(actorUserID: UserID, deviceID: DeviceID, claim: V2PushIntentSessionClaim, now: Date) async throws -> UInt64 {
        let user = try endpointUUID(actorUserID), device = try endpointUUID(deviceID)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2PushDeviceEndpointError.unavailable }
            try await lockIntentDevice(user: user, device: device, sql: sql)
            let current = try await sql.raw("SELECT session_epoch, session_claim_id, intent_revision, intent_digest FROM im_v2.push_device_intents WHERE device_id = \(bind: device) FOR UPDATE").first(decoding: PushIntentStateRow.self)
            let expected = Int64(claim.expectedEpoch)
            if let current, current.claimID == claim.requestID {
                guard current.epoch == expected + 1 else { throw V2PushDeviceEndpointError.intentConflict }
                return UInt64(current.epoch)
            }
            guard (current?.epoch ?? 0) == expected else { throw V2PushDeviceEndpointError.staleIntent }
            guard v2PostgresTimestampCanEncode(now) else { throw V2PushDeviceEndpointError.unavailable }
            let granted = expected + 1
            try await sql.raw("""
                INSERT INTO im_v2.push_device_intents (device_id, session_epoch, session_claim_id, intent_revision, intent_digest, updated_at)
                VALUES (\(bind: device), \(bind: granted), \(bind: claim.requestID), 0, NULL, \(bind: now))
                ON CONFLICT(device_id) DO UPDATE SET session_epoch = EXCLUDED.session_epoch,
                    session_claim_id = EXCLUDED.session_claim_id, intent_revision = 0, intent_digest = NULL,
                    updated_at = EXCLUDED.updated_at
                """).run()
            return UInt64(granted)
        }
    }

    public func publishIntent(actorUserID: UserID, deviceID: DeviceID, version: V2PushIntentVersion, intent: V2PushEndpointIntent, now: Date) async throws {
        let user = try endpointUUID(actorUserID), device = try endpointUUID(deviceID)
        // Authenticate equality with a separate derived key. Neither provider
        // material nor a plain token hash is persisted in the intent receipt.
        struct Canonical: Encodable {
            let device: UUID
            let enabled: Bool
            let provider: String?
            let environment: String?
            let token: String?
        }
        let value: Canonical
        switch intent {
        case .enabled(let endpoint): value = .init(device: device, enabled: true, provider: endpoint.provider.rawValue, environment: endpoint.environment.rawValue, token: endpoint.token)
        case .disabled: value = .init(device: device, enabled: false, provider: nil, environment: nil, token: nil)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = envelopeKey.intentDigest(try encoder.encode(value))
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2PushDeviceEndpointError.unavailable }
            try await lockIntentDevice(user: user, device: device, sql: sql)
            guard let current = try await sql.raw("SELECT session_epoch, session_claim_id, intent_revision, intent_digest FROM im_v2.push_device_intents WHERE device_id = \(bind: device) FOR UPDATE").first(decoding: PushIntentStateRow.self) else { throw V2PushDeviceEndpointError.intentVersionRequired }
            guard current.epoch == Int64(version.epoch), current.revision <= Int64(version.revision) else { throw V2PushDeviceEndpointError.staleIntent }
            if current.revision == Int64(version.revision) {
                guard current.digest == digest else { throw V2PushDeviceEndpointError.intentConflict }
                return
            }
            guard v2PostgresTimestampCanEncode(now) else { throw V2PushDeviceEndpointError.unavailable }
            switch intent {
            case .enabled(let endpoint):
                let generation = makeUUID()
                let encrypted = try envelopeKey.seal(endpoint.token, authenticating: endpointContext(deviceID: deviceID, provider: endpoint.provider, environment: endpoint.environment, generation: generation))
                try await sql.raw("""
                    INSERT INTO im_v2.push_device_endpoints (device_id, provider, environment, endpoint_generation, encrypted_token, updated_at, disabled_at)
                    VALUES (\(bind: device), \(bind: endpoint.provider.rawValue), \(bind: endpoint.environment.rawValue), \(bind: generation), \(bind: encrypted), \(bind: now), NULL)
                    ON CONFLICT(device_id, provider) DO UPDATE SET environment = EXCLUDED.environment,
                        endpoint_generation = EXCLUDED.endpoint_generation, encrypted_token = EXCLUDED.encrypted_token,
                        updated_at = EXCLUDED.updated_at, disabled_at = NULL
                    """).run()
            case .disabled:
                try await sql.raw("UPDATE im_v2.push_device_endpoints SET disabled_at = COALESCE(disabled_at, \(bind: now)), updated_at = \(bind: now) WHERE device_id = \(bind: device)").run()
            }
            try await sql.raw("UPDATE im_v2.push_device_intents SET intent_revision = \(bind: Int64(version.revision)), intent_digest = \(bind: digest), updated_at = \(bind: now) WHERE device_id = \(bind: device)").run()
        }
    }

    private func lockIntentDevice(user: UUID, device: UUID, sql: any SQLDatabase) async throws {
        guard try await sql.raw("SELECT 1 FROM im_v2.auth_devices WHERE user_id = \(bind: user) AND device_id = \(bind: device) AND revoked_at IS NULL AND session_expires_at > clock_timestamp() FOR UPDATE").first() != nil else { throw V2PushDeviceEndpointError.deviceUnavailable }
    }
}

private struct PushIntentEpochRow: Decodable { let epoch: Int64 }
private struct PushIntentStateRow: Decodable {
    let epoch: Int64; let claimID: UUID; let revision: Int64; let digest: Data?
    enum CodingKeys: String, CodingKey {
        case epoch = "session_epoch", claimID = "session_claim_id", revision = "intent_revision", digest = "intent_digest"
    }
}

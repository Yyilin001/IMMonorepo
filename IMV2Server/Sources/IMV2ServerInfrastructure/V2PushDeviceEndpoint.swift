import IMV2ServerApplication
import IMV2ServerContracts
import Crypto
import FluentKit
import Foundation
import IMV2Core
import SQLKit


/// 推送端点信封密钥。
///
/// 它与凭据重放加密材料相互独立：账号重放信封密钥泄漏不应能解开推送端点材料，反之亦然。
public struct V2PushEndpointEnvelopeKey: Sendable {
    private let rawBytes: Data

    /// 以 32 字节原始密钥构造。
    ///
    /// - Parameter rawBytes: 密钥字节，长度需恰好为 32。
    /// - Throws: 长度不符时抛出 ``V2PushDeviceEndpointError/unavailable``。
    public init(rawBytes: Data) throws {
        guard rawBytes.count == 32 else { throw V2PushDeviceEndpointError.unavailable }
        self.rawBytes = rawBytes
    }

    /// 以 Base64 密钥材料构造。
    ///
    /// - Parameter value: Base64 编码的 32 字节密钥。
    /// - Throws: 无法解码或长度不符时抛出
    ///   ``V2PushDeviceEndpointError/unavailable``。
    public init(base64Encoded value: String) throws {
        guard let bytes = Data(base64Encoded: value) else { throw V2PushDeviceEndpointError.unavailable }
        try self.init(rawBytes: bytes)
    }

    /// 以认证加密方式封存令牌明文。
    ///
    /// - Parameters:
    ///   - plaintext: 令牌明文。
    ///   - context: 参与完整性认证的上下文。
    /// - Returns: Base64 编码的密文信封。
    /// - Throws: 加密封装失败时抛出。
    fileprivate func seal(_ plaintext: String, authenticating context: Data) throws -> String {
        let box = try ChaChaPoly.seal(Data(plaintext.utf8), using: SymmetricKey(data: rawBytes), authenticating: context)
        return box.combined.base64EncodedString()
    }

    /// 解封并校验令牌密文。
    ///
    /// - Parameters:
    ///   - ciphertext: Base64 编码的密文信封。
    ///   - context: 参与完整性认证的上下文。
    /// - Returns: 令牌明文。
    /// - Throws: 信封无法解码、认证失败，或明文为空或超过 4096 字节时抛出
    ///   ``V2PushDeviceEndpointError/malformedPersistence``。
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

    /// 计算意图摘要，用于同一端点设备上的幂等与冲突判定。
    ///
    /// - Parameter bytes: 参与摘要的规范化字节。
    /// - Returns: 带部署域前缀的 HMAC-SHA256 摘要。
    fileprivate func intentDigest(_ bytes: Data) -> Data {
        let derived = HMAC<SHA256>.authenticationCode(for: Data("im-v2-push-intent-digest-v1".utf8), using: SymmetricKey(data: rawBytes))
        return Data(HMAC<SHA256>.authenticationCode(for: bytes, using: SymmetricKey(data: Data(derived))))
    }
}


/// 推送端点的 PostgreSQL 实现。
///
/// 它在静态存储中对不透明提供方令牌加密，并在更新端点状态的同一事务内校验设备有效性。
/// 扇出、用户同步与推送发件箱都不会保存提供方令牌。
public struct PostgresV2PushDeviceEndpointStore: V2PushDeviceEndpointStore {
    private let database: any Database
    private let envelopeKey: V2PushEndpointEnvelopeKey
    private let makeUUID: @Sendable () -> UUID

    /// 组合数据库、信封密钥与代次生成方式。
    ///
    /// - Parameters:
    ///   - database: 存放设备与端点状态的数据库。
    ///   - envelopeKey: 端点令牌的加密密钥。
    ///   - makeUUID: 端点代次生成方式。
    public init(
        database: any Database,
        envelopeKey: V2PushEndpointEnvelopeKey,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.database = database
        self.envelopeKey = envelopeKey
        self.makeUUID = makeUUID
    }

    /// 在单个事务内校验设备并注册或更新端点。
    ///
    /// 事务会确认设备未吊销且会话有效，随后以新的代次加密写入端点材料，
    /// 使延迟到达的旧停用请求无法影响新的注册。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起注册的用户。
    ///   - deviceID: 目标设备。
    ///   - endpoint: 端点注册内容。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 标识非法或时刻不可编码时抛出
    ///   ``V2PushDeviceEndpointError/unavailable``；设备无效时抛出
    ///   ``V2PushDeviceEndpointError/deviceUnavailable``。
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

    /// 读取设备的推送端点并解密令牌。
    ///
    /// - Parameter deviceID: 目标设备。
    /// - Returns: 端点；不存在或已停用时返回 `nil`。
    /// - Throws: 标识非法或连接不支持 SQL 时抛出
    ///   ``V2PushDeviceEndpointError/unavailable``；密文无法解密时抛出
    ///   ``V2PushDeviceEndpointError/malformedPersistence``。
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

    /// 按代次栅栏停用给定端点。
    ///
    /// 只有代次仍与当前记录一致时才会停用，因此延迟到达的提供方拒绝
    /// 不会影响同一设备之后注册的新端点。
    ///
    /// - Parameters:
    ///   - endpoint: 待停用的端点。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 时刻不可编码或连接不支持 SQL 时抛出
    ///   ``V2PushDeviceEndpointError/unavailable``。
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
        // 使用单独派生的密钥验证相等性。意图回执中既不持久化
        // 服务商凭据材料，也不持久化普通令牌哈希。
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

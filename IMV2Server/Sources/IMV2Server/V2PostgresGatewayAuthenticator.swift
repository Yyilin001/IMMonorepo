import Crypto
import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Gateway 认证的配置、凭证与持久化状态错误。
public enum V2GatewayAuthenticationError: Error, Equatable, Sendable {
    /// HMAC 密钥编码无效或解码后不足 32 字节。
    case invalidKeyMaterial
    /// 无法认证令牌和设备；当前适配器也以此报告非 SQL 数据库配置或无法转换为 UUID 的设备标识。
    case unauthenticated
    /// 读取到的用户或时间数据不可表示，或本地时钟不能安全用于 PostgreSQL 时间参数。
    case corruptPersistenceState
}

/// 用于访问令牌索引的 HMAC 密钥材料。
///
/// 由组装层从密钥管理或环境配置注入；数据库查找使用摘要，不把原始访问令牌作为持久化查询键。
/// 内部保存不可变字节，仅在同步摘要计算时创建 Crypto 密钥值。
public struct V2AccessTokenHMACKey: Sendable {
    // Crypto's SymmetricKey is not Sendable. Retain immutable byte material
    // (which is Sendable) and build the short-lived Crypto value only at the
    // synchronous digest boundary.
    /// 不可变密钥字节，不应输出到日志或诊断响应。
    private let rawBytes: Data

    /// 从 Base64 配置创建令牌摘要密钥。
    ///
    /// - Parameter value: 编码后的密钥，解码后至少 32 字节。
    /// - Throws: 无法解码或长度不足时抛出无效密钥材料错误。
    public init(base64Encoded value: String) throws {
        guard let bytes = Data(base64Encoded: value), bytes.count >= 32 else {
            throw V2GatewayAuthenticationError.invalidKeyMaterial
        }
        rawBytes = bytes
    }

    /// 从原始字节创建令牌摘要密钥。
    ///
    /// - Parameter rawBytes: 至少 32 字节的密钥材料。
    /// - Throws: 长度不足时抛出无效密钥材料错误。
    ///
    /// 长度检查不能证明随机性，安全生成与存储由配置提供方负责。
    public init(rawBytes: Data) throws {
        guard rawBytes.count >= 32 else { throw V2GatewayAuthenticationError.invalidKeyMaterial }
        self.rawBytes = rawBytes
    }

    /// 计算访问令牌的 HMAC-SHA256 查询摘要。
    ///
    /// - Parameter accessToken: 按原样 UTF-8 编码的令牌，不执行空白清理或格式校验。
    /// - Returns: 64 个小写十六进制字符，可用于数据库精确匹配。
    ///
    /// 同一密钥与令牌产生相同摘要；更换密钥会改变查询结果，需要外部协调令牌生命周期。
    public func digest(_ accessToken: String) -> String {
        let key = SymmetricKey(data: rawBytes)
        let code = HMAC<SHA256>.authenticationCode(for: Data(accessToken.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }
}

/// 通过 PostgreSQL 同一次联表查询认证令牌、设备和撤销状态。
///
/// 用户身份由查询结果确定；有效期取令牌与设备会话期限的较早值。查询完成后再次检查期限，
/// 排除查询等待期间已到期的结果。设备活跃时间属于尽力更新的展示元数据，不参与认证决定。
public struct V2PostgresGatewayAuthenticator: V2GatewayAuthenticator {
    /// 令牌和设备状态的数据库依赖。
    private let database: any Database
    /// 查询令牌摘要所需的密钥。
    private let tokenKey: V2AccessTokenHMACKey
    /// 用于查询与完成后期限检查的时间来源。
    private let now: @Sendable () -> Date
    /// 展示元数据写入的本地节流器。
    private let activityWriteGate: V2DeviceActivityWriteGate

    /// 配置数据库认证与设备活跃时间的尽力更新。
    ///
    /// - Parameters:
    ///   - database: 支持 SQL 的数据库实现；当前实现把非 SQL 配置报告为未认证。
    ///   - tokenKey: 必须与令牌签发时一致的 HMAC 密钥。
    ///   - now: 查询前后读取的可注入服务器时钟。
    ///   - activityWriteGate: 进程内活跃时间写入节流器，默认新建实例。
    public init(
        database: any Database,
        tokenKey: V2AccessTokenHMACKey,
        now: @escaping @Sendable () -> Date = Date.init,
        activityWriteGate: V2DeviceActivityWriteGate = .init()
    ) {
        self.database = database
        self.tokenKey = tokenKey
        self.now = now
        self.activityWriteGate = activityWriteGate
    }

    /// 按令牌摘要和设备标识查询有效、未撤销的普通账户会话。
    ///
    /// - Parameters:
    ///   - accessToken: 非空访问令牌。
    ///   - deviceID: 必须可转换为 UUID 的设备身份。
    /// - Returns: 同一查询所得用户和最早有效期。
    /// - Throws: 无匹配会话、空令牌、无效设备格式或非 SQL 数据库配置时抛出未认证错误；
    ///   不可表示时间或用户数据抛出状态错误；查询失败保留底层错误。
    ///
    /// 查询排除有效的特殊账户。成功查询后可能更新设备活跃时间，该更新失败被忽略。
    /// 返回结果是查询观察时的状态，不构成未来不被撤销的承诺；连接生命周期仍需响应后续撤销事件。
    public func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        guard !accessToken.isEmpty, let database = database as? any SQLDatabase else {
            throw V2GatewayAuthenticationError.unauthenticated
        }
        guard let deviceUUID = UUID(uuidString: deviceID.rawValue) else {
            throw V2GatewayAuthenticationError.unauthenticated
        }
        let observedAt = now()
        guard v2PostgresTimestampCanEncode(observedAt) else {
            throw V2GatewayAuthenticationError.corruptPersistenceState
        }
        guard let row = try await database.raw("""
            SELECT token.user_id, LEAST(token.expires_at, device.session_expires_at) AS expires_at
            FROM im_v2.device_access_tokens AS token
            JOIN im_v2.auth_devices AS device
              ON device.user_id = token.user_id AND device.device_id = token.device_id
            WHERE token.token_hmac = \(bind: tokenKey.digest(accessToken))
              AND token.device_id = \(bind: deviceUUID)
              AND token.expires_at > \(bind: observedAt)
              AND token.revoked_at IS NULL
              AND device.revoked_at IS NULL
              AND device.session_expires_at > \(bind: observedAt)
              AND NOT EXISTS (
                  SELECT 1
                  FROM im_v2.special_accounts AS special
                  WHERE special.account_user_id = token.user_id
                    AND special.status = 'active'
              )
            """).first(decoding: V2AuthenticatedSessionRow.self)
        else { throw V2GatewayAuthenticationError.unauthenticated }
        let completedAt = now()
        guard v2PostgresTimestampCanEncode(completedAt),
              v2PostgresTimestampCanEncode(row.expiresAt) else {
            throw V2GatewayAuthenticationError.corruptPersistenceState
        }
        guard row.expiresAt > completedAt else { throw V2GatewayAuthenticationError.unauthenticated }
        guard let userID = try? UserID(row.userID.uuidString) else {
            throw V2GatewayAuthenticationError.corruptPersistenceState
        }
        // This timestamp is presentation metadata, not authentication state.
        // The local gate removes repeated no-op UPDATE round trips; PostgreSQL's
        // predicate remains the cross-replica correctness boundary.
        if let activityCutoff = v2PostgresPastTimestamp(now: observedAt, interval: 60),
           await activityWriteGate.shouldWrite(deviceID: deviceID, at: observedAt) {
            try? await database.raw("""
                UPDATE im_v2.auth_devices
                SET last_active_at = \(bind: observedAt)
                WHERE user_id = \(bind: row.userID)
                  AND device_id = \(bind: deviceUUID)
                  AND (last_active_at IS NULL
                       OR last_active_at < \(bind: activityCutoff))
                """).run()
        }
        return .init(userID: userID, expiresAt: row.expiresAt)
    }
}

/// 限制进程内同一设备活跃时间的尽力写入频率。
///
/// 只减少展示元数据的重复更新，不参与认证。跨进程限制仍由数据库 UPDATE 条件保证。
/// 每接受 1024 次写入清理已过期的设备键；没有后台定时清理。
public actor V2DeviceActivityWriteGate {
    /// 本地写入间隔，初始化时限制为至少一秒；实际截止时间必须通过时间编码检查。
    private let interval: TimeInterval
    /// 各设备下一次可尝试写入的墙上时钟时间。
    private var nextEligibleAt: [DeviceID: Date] = [:]
    /// 已放行的写入尝试数，用于触发周期性键清理。
    private var acceptedWrites = 0

    /// 创建活跃时间写入门。
    ///
    /// - Parameter interval: 尝试间隔秒数，默认 60，使用 `max(1, interval)` 保存。
    ///
    /// 实际可表示性由每次放行检查负责；此类型不持有数据库写入任务。
    public init(interval: TimeInterval = 60) {
        self.interval = max(1, interval)
    }

    /// 判断并记录设备本次活跃时间是否可尝试写入。
    ///
    /// - Parameters:
    ///   - deviceID: 活跃设备。
    ///   - now: 此次认证观察到的时间。
    /// - Returns: 截止时间可表示且设备已到可写时间时返回 `true`；无效时间或间隔未到时返回 `false`。
    ///
    /// 放行时先推进本地截止时间，后续数据库失败不会自动撤销该推进。时钟回拨可能延长已有截止时间前的抑制期。
    /// 无效时间不会覆盖原有截止时间，避免影响时钟恢复后的处理。
    public func shouldWrite(deviceID: DeviceID, at now: Date) -> Bool {
        // A broken clock must not replace the next eligible write with an
        // unusable deadline that continues suppressing activity after recovery.
        guard let nextWriteAt = v2PostgresFutureTimestamp(now: now, interval: interval) else {
            return false
        }
        if let nextEligible = nextEligibleAt[deviceID], nextEligible > now {
            return false
        }
        nextEligibleAt[deviceID] = nextWriteAt
        acceptedWrites += 1
        if acceptedWrites.isMultiple(of: 1_024) {
            nextEligibleAt = nextEligibleAt.filter { $0.value > now }
        }
        return true
    }
}

/// 认证联表查询的最小结果投影，保持用户与最早期限来自同一次读取。
private struct V2AuthenticatedSessionRow: Decodable {
    /// 令牌关联的持久化用户身份。
    let userID: UUID
    /// 令牌到期时间与设备会话到期时间中的较早值。
    let expiresAt: Date
    /// 把 Swift 属性映射到认证 SQL 查询列名。
    enum CodingKeys: String, CodingKey { case userID = "user_id", expiresAt = "expires_at" }
}

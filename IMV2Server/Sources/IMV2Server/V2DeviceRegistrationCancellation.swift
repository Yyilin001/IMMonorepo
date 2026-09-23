import Crypto
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 设备注册请求与其取消请求的组合。
public struct V2CancellableDeviceRegistration: Sendable {
    /// 待签发的受信设备注册请求。
    public let registration: V2TrustedDeviceRegistration
    /// 对应的取消请求。
    public let cancellation: V2DeviceRegistrationCancellation

    /// 校验两者指向同一设备与同一操作后组合。
    ///
    /// - Parameters:
    ///   - registration: 设备注册请求。
    ///   - cancellation: 取消请求。
    /// - Throws: 设备标识或操作标识不一致时抛出
    ///   ``V2DeviceSessionServiceError/invalidRequest``。
    public init(registration: V2TrustedDeviceRegistration, cancellation: V2DeviceRegistrationCancellation) throws {
        guard UUID(uuidString: registration.deviceID.rawValue) == UUID(uuidString: cancellation.deviceID.rawValue),
              registration.operationID == cancellation.operationID else { throw V2DeviceSessionServiceError.invalidRequest }
        self.registration = registration; self.cancellation = cancellation
    }
}

/// 设备注册取消结果。
public enum V2DeviceRegistrationCancellationOutcome: Equatable, Sendable {
    /// 本次调用实际写入取消或吊销了绑定会话。
    case applied
    /// 该取消请求此前已生效，未产生第二次效果。
    case idempotent
    /// 取消到达过晚，签发窗口已关闭，不再处理。
    case expired
}

/// 设备注册取消能力。
public protocol V2DeviceRegistrationCancelling: Sendable {
    /// 取消一次尚未完成或刚完成的设备注册。
    ///
    /// - Parameter request: 取消请求。
    /// - Returns: 取消结果。
    /// - Throws: 请求非法或持久化状态异常时抛出。
    func cancel(_ request: V2DeviceRegistrationCancellation) async throws -> V2DeviceRegistrationCancellationOutcome
}

/// 基于 PostgreSQL 的设备注册取消实现。
///
/// 证明锁先于既有账号锁获取。签发前到达的取消会留下墓碑；签发后到达的取消会吊销
/// 完全匹配的绑定会话。两种跃迁都与各自的持久化标记一同提交。
public struct V2PostgresDeviceRegistrationCancellationService: V2DeviceRegistrationCancelling, Sendable {
    private let database: any Database
    private let now: @Sendable () -> Date

    /// 组合数据库与授时来源。
    ///
    /// - Parameters:
    ///   - database: 存放设备、会话与取消记录的数据库。
    ///   - now: 可注入的当前时刻读取函数。
    public init(database: any Database, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database; self.now = now
    }

    /// 在单个事务内完成幂等判定、墓碑写入或会话吊销。
    ///
    /// 已存在取消记录时直接返回幂等；记录已绑定用户时校验设备与会话三元组完全一致，
    /// 再以精确宽限期判断是否仍可吊销，超期返回已过期。尚未签发的请求在时间窗内写入墓碑，
    /// 到达过晚则返回过期。
    ///
    /// - Parameter request: 取消请求。
    /// - Returns: 取消结果。
    /// - Throws: 连接不支持 SQL、时刻不可编码或持久化记录异常时抛出
    ///   ``V2DeviceSessionServiceError/unavailable`` 或
    ///   ``V2DeviceSessionServiceError/malformedPersistence``。
    public func cancel(_ request: V2DeviceRegistrationCancellation) async throws -> V2DeviceRegistrationCancellationOutcome {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2DeviceSessionServiceError.unavailable }
            try await Self.lock(sql, request: request)
            let prior = try await Self.record(sql, request: request)
            if prior?.cancelledAt != nil { return .idempotent }
            if let prior, let userID = prior.userID {
                try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "account-state:" + userID.uuidString), 0))").run()
                guard try await sql.raw("""
                    SELECT device.device_id FROM im_v2.auth_devices AS device
                    JOIN im_v2.device_registration_cancellations AS binding
                      ON binding.user_id=device.user_id AND binding.device_id=device.device_id
                     AND binding.session_created_at=device.created_at
                     AND binding.session_expires_at=device.session_expires_at
                    WHERE binding.request_digest=\(bind: Self.digest(request))
                      AND device.user_id=\(bind: userID) AND device.device_id=\(bind: Self.device(request))
                    FOR UPDATE OF device
                    """).first() != nil
                else { throw V2DeviceSessionServiceError.malformedPersistence }
                let occurredAt = now()
                guard v2PostgresTimestampCanEncode(occurredAt) else { throw V2DeviceSessionServiceError.unavailable }
                // EXTRACT returns numeric: compare the exact grace period
                // without a Date round trip or overflowing a SQL timestamp.
                guard let deadline = try await sql.raw("SELECT EXTRACT(EPOCH FROM session_expires_at) + 600 > EXTRACT(EPOCH FROM \(bind: occurredAt)::timestamptz) AS is_open FROM im_v2.auth_devices WHERE user_id=\(bind: userID) AND device_id=\(bind: Self.device(request))").first(decoding: Deadline.self) else {
                    throw V2DeviceSessionServiceError.malformedPersistence
                }
                guard deadline.isOpen else { return .expired }
                try await Self.markCancelled(sql, request: request, at: occurredAt)
                try await V2PostgresDeviceSessionService.revokeSession(sql, userID: userID, deviceID: Self.device(request), at: occurredAt)
                return .applied
            }
            let occurredAt = now()
            guard try Self.admitsNewRequest(request, at: occurredAt) else { return .expired }
            try await sql.raw("""
                INSERT INTO im_v2.device_registration_cancellations
                    (request_digest, device_id, operation_id, issue_before, created_at, cancelled_at)
                VALUES (\(bind: Self.digest(request)), \(bind: Self.device(request)), \(bind: request.operationID),
                    \(bind: request.issueBefore), \(bind: occurredAt), \(bind: occurredAt))
                """).run()
            return .applied
        }
    }

    /// 按请求摘要获取取消证明锁。
    ///
    /// - Parameters:
    ///   - sql: 当前事务使用的数据库连接。
    ///   - request: 取消请求。
    /// - Throws: 加锁失败时抛出。
    static func lock(_ sql: any SQLDatabase, request: V2DeviceRegistrationCancellation) async throws {
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "registration-cancellation:" + digest(request)), 0))").run()
    }

    /// 判断该取消请求是否仍允许签发。
    ///
    /// 调用方需先持有证明锁再持有账号锁，且必须在之后才读取当前时刻。
    ///
    /// - Parameters:
    ///   - sql: 当前事务使用的数据库连接。
    ///   - request: 取消请求。
    ///   - now: 判定时刻。
    /// - Returns: 请求仍处于时间窗内且不存在已生效取消时为 `true`。
    /// - Throws: 时刻不可编码或时间窗超出上限时抛出。
    static func permitsIssuance(_ sql: any SQLDatabase, request: V2DeviceRegistrationCancellation,
                                at now: Date) async throws -> Bool {
        guard try admitsNewRequest(request, at: now) else { return false }
        return try await record(sql, request: request)?.cancelledAt == nil
    }

    /// 判断既有取消记录是否绑定到指定用户。
    ///
    /// - Parameters:
    ///   - sql: 当前事务使用的数据库连接。
    ///   - request: 取消请求。
    ///   - userID: 期望绑定的用户。
    /// - Returns: 记录存在且绑定该用户时为 `true`。
    /// - Throws: 查询失败时抛出。
    static func ownsReplay(_ sql: any SQLDatabase, request: V2DeviceRegistrationCancellation,
                           userID: UUID) async throws -> Bool {
        try await record(sql, request: request)?.userID == userID
    }

    /// 把已签发会话与取消请求绑定。
    ///
    /// 证明锁会阻止取消与重复绑定并发，直到凭据、重放信封与本记录一同提交。
    ///
    /// - Parameters:
    ///   - sql: 当前事务使用的数据库连接。
    ///   - request: 取消请求。
    ///   - userID: 会话归属用户。
    ///   - now: 绑定时刻。
    /// - Throws: 时刻不可编码时抛出
    ///   ``V2DeviceSessionServiceError/unavailable``。
    static func bindIssuedSession(_ sql: any SQLDatabase, request: V2DeviceRegistrationCancellation,
                                  userID: UUID, at now: Date) async throws {
        guard v2PostgresTimestampCanEncode(now) else { throw V2DeviceSessionServiceError.unavailable }
        // The proof lock excludes cancellation and duplicate binding until the
        // credentials, replay envelope, and this record commit together.
        try await sql.raw("""
            INSERT INTO im_v2.device_registration_cancellations
                (request_digest, device_id, operation_id, issue_before, created_at,
                 user_id, session_created_at, session_expires_at)
            SELECT \(bind: digest(request)), device_id, \(bind: request.operationID), \(bind: request.issueBefore),
                \(bind: now), user_id, created_at, session_expires_at
            FROM im_v2.auth_devices WHERE user_id = \(bind: userID) AND device_id = \(bind: device(request))
            """).run()
    }

    /// 判断是否接受本次签发前的取消。
    ///
    /// 要求当前时刻早于签发截止时间，且两者间隔不超过 24 小时，
    /// 以限制未认证的签发前墓碑数量并拦截时钟异常。
    ///
    /// - Parameters:
    ///   - request: 取消请求。
    ///   - now: 判定时刻。
    /// - Returns: 仍可接受时为 `true`。
    /// - Throws: 时刻不可编码时抛出
    ///   ``V2DeviceSessionServiceError/unavailable``；时间窗超过 24 小时时抛出
    ///   ``V2DeviceSessionServiceError/invalidRequest``。
    private static func admitsNewRequest(_ request: V2DeviceRegistrationCancellation, at now: Date) throws -> Bool {
        guard v2PostgresTimestampCanEncode(now) else { throw V2DeviceSessionServiceError.unavailable }
        guard v2PostgresTimestampPrecedes(now, request.issueBefore) else { return false }
        // Limits unauthenticated pre-issuance tombstones and clock errors.
        guard request.issueBefore.timeIntervalSince(now) <= 86_400 else { throw V2DeviceSessionServiceError.invalidRequest }
        return true
    }

    /// 把取消记录标记为已生效。
    ///
    /// - Parameters:
    ///   - sql: 当前事务使用的数据库连接。
    ///   - request: 取消请求。
    ///   - now: 生效时刻。
    /// - Throws: 时刻不可编码时抛出
    ///   ``V2DeviceSessionServiceError/unavailable``。
    private static func markCancelled(_ sql: any SQLDatabase, request: V2DeviceRegistrationCancellation, at now: Date) async throws {
        guard v2PostgresTimestampCanEncode(now) else { throw V2DeviceSessionServiceError.unavailable }
        try await sql.raw("UPDATE im_v2.device_registration_cancellations SET cancelled_at = \(bind: now) WHERE request_digest = \(bind: digest(request))").run()
    }

    /// 读取取消记录。
    ///
    /// - Parameters:
    ///   - sql: 当前事务使用的数据库连接。
    ///   - request: 取消请求。
    /// - Returns: 取消记录；不存在时返回 `nil`。
    /// - Throws: 查询失败时抛出。
    private static func record(_ sql: any SQLDatabase, request: V2DeviceRegistrationCancellation) async throws -> Record? {
        try await sql.raw("""
            SELECT user_id, cancelled_at
            FROM im_v2.device_registration_cancellations WHERE request_digest = \(bind: digest(request))
            """).first(decoding: Record.self)
    }

    /// 把目标设备标识解析为 UUID。
    ///
    /// - Parameter request: 取消请求。
    /// - Returns: 设备 UUID。
    /// - Throws: 标识非法时抛出 ``V2DeviceSessionServiceError/invalidRequest``。
    private static func device(_ request: V2DeviceRegistrationCancellation) throws -> UUID {
        guard let value = UUID(uuidString: request.deviceID.rawValue) else { throw V2DeviceSessionServiceError.invalidRequest }
        return value
    }

    /// 计算取消请求摘要，绑定设备、操作标识、截止毫秒与证明内容。
    ///
    /// - Parameter request: 取消请求。
    /// - Returns: 十六进制 SHA-256 摘要。
    private static func digest(_ request: V2DeviceRegistrationCancellation) -> String {
        let context = "imv2-registration-cancellation-v1\0\(request.deviceID.rawValue)\0\(request.operationID.uuidString)\0\(request.issueBeforeMilliseconds)\0\(request.proof.rawValue)"
        return SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private struct Record: Decodable {
        let userID: UUID?
        let cancelledAt: Date?
        enum CodingKeys: String, CodingKey {
            case userID = "user_id", cancelledAt = "cancelled_at"
        }
    }
    private struct Deadline: Decodable {
        let isOpen: Bool
        enum CodingKeys: String, CodingKey { case isOpen = "is_open" }
    }
}

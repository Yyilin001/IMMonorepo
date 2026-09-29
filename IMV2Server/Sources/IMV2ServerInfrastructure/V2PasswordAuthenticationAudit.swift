import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import SQLKit

/// 密码备选认证因子的持久化审计结果。
///
/// 审计记录不包含账号标识、密码、密码哈希、断言内容，也不包含由网络推导出的客户端身份。
enum V2PasswordAuthenticationAuditOutcome: String, Sendable {
    /// 密码注册成功。
    case registrationSucceeded = "registration_succeeded"
    /// 密码断言校验通过。
    case assertionSucceeded = "assertion_succeeded"
    /// 密码断言被拒绝。
    case assertionRejected = "assertion_rejected"
}

/// 密码认证审计写入错误。
enum V2PasswordAuthenticationAuditError: Error, Equatable, Sendable {
    /// 设备或用户标识无法解析为 UUID。
    case invalidIdentifier
    /// 时间戳无法按持久化精度编码。
    case invalidTimestamp
}

/// 以 `Date` 时刻记录一次密码认证审计。
///
/// - Parameters:
///   - outcome: 本次认证结果。
///   - userID: 关联用户；注册未完成时可为空。
///   - deviceID: 发起认证的设备。
///   - occurredAt: 事件发生时刻。
///   - sql: 当前事务使用的数据库连接。
/// - Throws: 时刻无法编码时抛出
///   ``V2PasswordAuthenticationAuditError/invalidTimestamp``；标识非法时抛出
///   ``V2PasswordAuthenticationAuditError/invalidIdentifier``。
func recordPasswordAuthenticationAudit(
    outcome: V2PasswordAuthenticationAuditOutcome,
    userID: UserID?,
    deviceID: DeviceID,
    occurredAt: Date,
    on sql: any SQLDatabase
) async throws {
    guard let timestamp = try? V2PersistenceTimestamp(date: occurredAt) else {
        throw V2PasswordAuthenticationAuditError.invalidTimestamp
    }
    try await recordPasswordAuthenticationAudit(outcome: outcome, userID: userID,
        deviceID: deviceID, occurredAt: timestamp, on: sql)
}

/// 以已编码的 PostgreSQL 时刻记录一次密码认证审计。
///
/// 设备与用户标识必须是合法 UUID，审计行使用新生成的随机事件标识，
/// 因此同一认证事件重复记录会产生多条独立记录。
///
/// - Parameters:
///   - outcome: 本次认证结果。
///   - userID: 关联用户；注册未完成时可为空。
///   - deviceID: 发起认证的设备。
///   - occurredAt: 已按持久化精度编码的事件时刻。
///   - sql: 当前事务使用的数据库连接。
/// - Throws: 标识不是合法 UUID 时抛出
///   ``V2PasswordAuthenticationAuditError/invalidIdentifier``；时刻超出可编码范围时抛出
///   ``V2PasswordAuthenticationAuditError/invalidTimestamp``。
func recordPasswordAuthenticationAudit(
    outcome: V2PasswordAuthenticationAuditOutcome,
    userID: UserID?,
    deviceID: DeviceID,
    occurredAt: V2PersistenceTimestamp,
    on sql: any SQLDatabase
) async throws {
    guard let deviceUUID = UUID(uuidString: deviceID.rawValue) else {
        throw V2PasswordAuthenticationAuditError.invalidIdentifier
    }
    let userUUID = try userID.map { userID in
        guard let value = UUID(uuidString: userID.rawValue) else {
            throw V2PasswordAuthenticationAuditError.invalidIdentifier
        }
        return value
    }
    guard v2PostgresTimestampMicrosecondsCanEncode(occurredAt.microseconds) else {
        throw V2PasswordAuthenticationAuditError.invalidTimestamp
    }
    try await sql.raw("""
        INSERT INTO im_v2.account_password_authentication_audit
            (event_id, outcome, user_id, device_id, occurred_at)
        VALUES
            (\(bind: UUID()), \(bind: outcome.rawValue), \(bind: userUUID),
             \(bind: deviceUUID), \(bind: occurredAt))
        """).run()
}

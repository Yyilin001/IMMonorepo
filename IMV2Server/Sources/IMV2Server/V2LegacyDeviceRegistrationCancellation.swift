import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 已认证的历史设备注册取消请求。
///
/// 只有在为 `assertionDeviceID` 校验了新鲜的账号认证因子之后才能构造该请求：
/// 目标设备的旧标识只用于定位待处理工作，真正的授权来自账号校验。
public struct V2TrustedLegacyDeviceRegistrationCancellation: Sendable {
    /// 发起取消的用户。
    public let userID: UserID
    /// 提供账号认证因子的设备。
    public let assertionDeviceID: DeviceID
    /// 需要取消注册的目标设备。
    public let targetDeviceID: DeviceID
    /// 本次取消的幂等操作标识。
    public let operationID: UUID

    /// 校验并保存取消请求。
    ///
    /// - Parameters:
    ///   - userID: 发起取消的用户，需可解析为 UUID。
    ///   - assertionDeviceID: 提供认证因子的设备，需可解析为 UUID。
    ///   - targetDeviceID: 需要取消注册的设备，需可解析为 UUID。
    ///   - operationID: 幂等操作标识。
    /// - Throws: 任一标识无法解析，或认证设备与目标设备相同时抛出
    ///   ``V2DeviceSessionServiceError/invalidRequest``。
    public init(userID: UserID, assertionDeviceID: DeviceID, targetDeviceID: DeviceID, operationID: UUID) throws {
        guard userID.uuidValue != nil, assertionDeviceID.uuidValue != nil, targetDeviceID.uuidValue != nil,
              assertionDeviceID != targetDeviceID else { throw V2DeviceSessionServiceError.invalidRequest }
        self.userID = userID; self.assertionDeviceID = assertionDeviceID
        self.targetDeviceID = targetDeviceID; self.operationID = operationID
    }
}

/// 历史设备注册取消的执行结果。
public enum V2LegacyDeviceRegistrationCancellationOutcome: Equatable, Sendable {
    /// 本次调用实际写入了取消记录。
    case applied
    /// 同一设备与操作标识已取消过，未产生第二次效果。
    case idempotent
    /// 目标设备不存在或属于其他账号。
    case targetUnavailable
    /// 账号已被停用或处于特殊状态。
    case accountUnavailable
    /// 同一账号或同一操作标识已存在不同的取消记录。
    case conflict
    /// 该账号的取消墓碑数量已达上限。
    case capacityExceeded
}

/// 历史设备注册取消能力。
public protocol V2LegacyDeviceRegistrationCancelling: Sendable {
    /// 取消一台历史设备的注册。
    ///
    /// - Parameter request: 已认证的取消请求。
    /// - Returns: 取消结果。
    /// - Throws: 标识非法或持久化失败时抛出。
    func cancel(_ request: V2TrustedLegacyDeviceRegistrationCancellation) async throws -> V2LegacyDeviceRegistrationCancellationOutcome
}

/// 基于 PostgreSQL 的历史设备注册取消实现。
///
/// 加锁顺序与签发路径保持一致的「账号 → 注册 → 设备」，避免与签发并发时死锁；
/// 账号级墓碑同样会拒绝此前从未成功签发的操作，防止取消在签发之前到达时被绕过。
public struct V2PostgresLegacyDeviceRegistrationCancellationService: V2LegacyDeviceRegistrationCancelling {
    private let database: any Database
    private let now: @Sendable () -> Date
    /// 组合数据库与授时来源。
    ///
    /// - Parameters:
    ///   - database: 存放账号、设备与取消墓碑的数据库。
    ///   - now: 可注入的当前时刻读取函数。
    public init(database: any Database, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database; self.now = now
    }

    /// 在单个事务内完成校验、墓碑写入与必要的会话吊销。
    ///
    /// 顺序为：账号状态检查、设备行加锁、幂等与冲突判定、墓碑容量判定、写入墓碑，
    /// 若该设备已有会话则一并吊销。墓碑容量上限为 256 条。
    ///
    /// - Parameter request: 已认证的取消请求。
    /// - Returns: 取消结果。
    /// - Throws: 标识非法时抛出 ``V2DeviceSessionServiceError/invalidRequest``；
    ///   连接不支持 SQL 或时刻不可编码时抛出 ``V2DeviceSessionServiceError/unavailable``。
    public func cancel(_ request: V2TrustedLegacyDeviceRegistrationCancellation) async throws -> V2LegacyDeviceRegistrationCancellationOutcome {
        guard let user = request.userID.uuidValue, let device = request.targetDeviceID.uuidValue else { throw V2DeviceSessionServiceError.invalidRequest }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2DeviceSessionServiceError.unavailable }
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "account-state:" + user.uuidString), 0))").run()
            guard try await sql.raw("SELECT 1 FROM im_v2.account_disables WHERE user_id = \(bind: user)").first() == nil,
                  try await sql.raw("SELECT 1 FROM im_v2.special_accounts WHERE account_user_id = \(bind: user) AND status = 'active'").first() == nil
            else { return .accountUnavailable }
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "register:" + device.uuidString), 0))").run()
            let target = try await sql.raw("SELECT user_id FROM im_v2.auth_devices WHERE device_id = \(bind: device) FOR UPDATE").first(decoding: Target.self)
            guard target == nil || target?.userID == user else { return .targetUnavailable }
            if let previous = try await sql.raw("SELECT device_id, operation_id FROM im_v2.legacy_device_registration_cancellations WHERE user_id = \(bind: user) AND (device_id = \(bind: device) OR operation_id = \(bind: request.operationID))").first(decoding: Previous.self) {
                return previous.deviceID == device && previous.operationID == request.operationID ? .idempotent : .conflict
            }
            let count = try await sql.raw("SELECT count(*)::integer AS count FROM im_v2.legacy_device_registration_cancellations WHERE user_id = \(bind: user)").first(decoding: Count.self)?.count ?? 0
            guard count < 256 else { return .capacityExceeded }
            let at = now()
            guard v2PostgresTimestampCanEncode(at) else { throw V2DeviceSessionServiceError.unavailable }
            try await sql.raw("INSERT INTO im_v2.legacy_device_registration_cancellations (user_id, device_id, operation_id, cancelled_at) VALUES (\(bind: user), \(bind: device), \(bind: request.operationID), \(bind: at))").run()
            if target != nil { try await V2PostgresDeviceSessionService.revokeSession(sql, userID: user, deviceID: device, at: at) }
            return .applied
        }
    }

    /// 判断指定设备是否仍被允许签发凭据。
    ///
    /// - Parameters:
    ///   - sql: 当前事务使用的数据库连接。
    ///   - userID: 目标账号。
    ///   - deviceID: 目标设备。
    /// - Returns: 不存在取消墓碑时为 `true`。
    /// - Throws: 查询失败时抛出。
    static func permitsIssuance(_ sql: any SQLDatabase, userID: UUID, deviceID: UUID) async throws -> Bool {
        try await sql.raw("SELECT 1 FROM im_v2.legacy_device_registration_cancellations WHERE user_id = \(bind: userID) AND device_id = \(bind: deviceID)").first() == nil
    }

    private struct Target: Decodable {
        let userID: UUID
        enum CodingKeys: String, CodingKey { case userID = "user_id" }
    }
    private struct Previous: Decodable {
        let deviceID: UUID
        let operationID: UUID
        enum CodingKeys: String, CodingKey { case deviceID = "device_id", operationID = "operation_id" }
    }
    private struct Count: Decodable { let count: Int }
}

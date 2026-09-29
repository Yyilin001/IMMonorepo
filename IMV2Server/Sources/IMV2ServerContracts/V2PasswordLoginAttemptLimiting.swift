import IMV2Core

/// 密码传输适配器使用的窄接口。
///
/// 生产路径先原子预扣校验预算，再单独记录校验结果；未完成的请求不会退回预算。
/// recordRejectedAttempt 保留计数与拒绝审计的原子组合，供已有受信调用方使用。
public protocol V2PasswordLoginAttemptLimiting: Sendable {
    /// 原子检查并预扣一次校验预算。未完成、取消或基础设施失败的尝试仍占预算，
    /// 防止通过断开请求绕过限制；成功认证重置预算，其他情况由窗口到期恢复。
    func consumeAttempt(accountHandle: String) async throws -> Int?
    /// 已预扣尝试的拒绝审计，不再次计数。
    func auditRejectedAttempt(accountHandle: String, userID: UserID?, deviceID: DeviceID) async throws

    /// 查询账号当前是否处于锁定状态。
    ///
    /// - Parameter accountHandle: 账号标识。
    /// - Returns: 仍需等待的秒数；未锁定时返回 `nil`。
    /// - Throws: 标识非法或存储不可用时抛出。
    func blockedRetryAfterSeconds(accountHandle: String) async throws -> Int?

    /// 记录一次被拒绝的登录尝试。
    ///
    /// - Parameters:
    ///   - accountHandle: 账号标识。
    ///   - userID: 账号对应用户；账号不存在时为空。
    ///   - deviceID: 发起尝试的设备。
    /// - Throws: 标识非法或存储不可用时抛出。
    func recordRejectedAttempt(accountHandle: String, userID: UserID?, deviceID: DeviceID) async throws

    /// 记录一次成功的登录尝试并清空失败窗口。
    ///
    /// - Parameters:
    ///   - accountHandle: 账号标识。
    ///   - userID: 账号对应用户。
    ///   - deviceID: 发起尝试的设备。
    /// - Throws: 标识非法或存储不可用时抛出。
    func recordSuccessfulAttempt(accountHandle: String, userID: UserID, deviceID: DeviceID) async throws
}

import Foundation

/// 会话协调器向应用报告的重新认证与身份不匹配错误。
public enum V2RealtimeSessionCoordinatorError: Error, Equatable, Sendable {
    /// 认证会话已无法提供有效凭证，或当前凭证遭到明确拒绝并经凭证所有者处理，需要进入重新认证流程。
    case authenticationRequired
    /// 握手返回的用户或设备与本地一致凭证元组不符，协调器已请求断开该连接。
    case identityMismatch
}

/// 协调设备凭证与实时连接握手的应用边界。
///
/// 并发 connect 共享一次尝试，由 V2AuthSession 提供一致的用户、设备、令牌和会话代际，必要刷新由凭证所有者完成。
/// 成功后核对会话代际及用户设备身份。访问令牌仅交给认证传输，不作为返回会话的一部分暴露。
public actor V2RealtimeSessionCoordinator: V2RealtimeSessionConnecting {
    /// 拥有凭证刷新、一致元组和会话失效状态的认证会话。
    private let authSession: V2AuthSession
    /// 执行握手认证与断开的实时连接。
    private let connection: any V2RealtimeConnection
    /// 客户端允许协商的非空能力集合。
    private let supportedCapabilityProfiles: Set<String>
    /// 当前共享的连接尝试；完成时按身份清除，避免旧等待者误清理新尝试。
    private var activeAttempt: ConnectionAttempt?

    /// 创建实时会话协调器，不读取凭证或发起连接。
    ///
    /// - Parameters:
    ///   - authSession: 认证凭证所有者。
    ///   - connection: 可注入的实时连接。
    ///   - supportedCapabilityProfiles: 非空能力集合，否则触发前置条件失败。
    public init(
        authSession: V2AuthSession,
        connection: any V2RealtimeConnection,
        supportedCapabilityProfiles: Set<String>
    ) {
        precondition(!supportedCapabilityProfiles.isEmpty)
        self.authSession = authSession
        self.connection = connection
        self.supportedCapabilityProfiles = supportedCapabilityProfiles
    }

    /// 复用或发起一次从一致凭证到已认证连接的共享尝试。
    ///
    /// - Returns: 用户和设备与本地凭证匹配的会话。
    /// - Throws: 需要重新认证、身份不匹配、会话代际失效或底层连接错误。
    ///
    /// 凭证读取返回后保存其代际和实际提交的令牌。明确认证拒绝只交由认证会话在当前代际和令牌仍匹配时处理，
    /// 避免旧尝试清除替换后的凭证。身份不匹配会先断开连接再报错。
    ///
    /// 单个调用者取消不会取消共享任务；此方法也不在返回前检查等待者自身的取消状态。
    /// 一般连接错误直接传播，不在所有错误分支统一断开，底层及应用生命周期仍负责收尾。
    public func connect() async throws -> V2AuthenticatedClientSession {
        let attempt: ConnectionAttempt
        if let activeAttempt {
            attempt = activeAttempt
        } else {
            let id = UUID()
            let task = Task { [authSession, connection, supportedCapabilityProfiles] in
                var credentialEpoch: V2AuthSessionEpoch?
                var attemptedAccessToken: String?
                do {
                    let credentials = try await authSession.realtimeCredentials()
                    credentialEpoch = credentials.sessionEpoch
                    attemptedAccessToken = credentials.accessToken
                    let established = try await connection.connectAndAuthenticate(
                        accessToken: credentials.accessToken,
                        deviceID: credentials.deviceID,
                        supportedCapabilityProfiles: supportedCapabilityProfiles
                    )
                    if let credentialEpoch { try await authSession.requireAuthenticatedEpoch(credentialEpoch) }
                    guard established.userID == credentials.userID,
                          established.deviceID == credentials.deviceID
                    else {
                        await connection.disconnect()
                        throw V2RealtimeSessionCoordinatorError.identityMismatch
                    }
                    return established
                } catch V2AuthSessionError.unauthenticated {
                    // Refresh/restore can conclusively end the session before
                    // a socket is opened. Use the same app-facing transition.
                    throw V2RealtimeSessionCoordinatorError.authenticationRequired
                } catch let error as V2TLSFrameConnectionError where error == .authenticationFailed {
                    guard let credentialEpoch else { throw V2AuthSessionError.sessionInvalidated }
                    try await authSession.handleTerminalRejection(ifCurrent: credentialEpoch, rejectedAccessToken: attemptedAccessToken)
                    throw V2RealtimeSessionCoordinatorError.authenticationRequired
                }
            }
            attempt = .init(id: id, task: task)
            activeAttempt = attempt
        }

        let result = await attempt.task.result
        if activeAttempt?.id == attempt.id {
            activeAttempt = nil
        }
        return try result.get()
    }

    /// 请求取消当前共享尝试，清除其引用并等待底层连接断开。
    ///
    /// 不单独等待共享尝试完全退出，也不删除认证会话凭证。旧尝试的延迟结果由其持有者及会话代际检查处理。
    public func disconnect() async {
        activeAttempt?.task.cancel()
        activeAttempt = nil
        await connection.disconnect()
    }
}

/// 共享连接尝试及其内部身份，不表示已建立可长期复用的会话缓存。
private struct ConnectionAttempt {
    /// 本次尝试身份，用于安全清除 activeAttempt。
    let id: UUID
    /// 由协调器拥有的共享握手任务，独立于任一界面等待者。
    let task: Task<V2AuthenticatedClientSession, Error>
}

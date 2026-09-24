import Foundation
import IMV2Core

/// 可信账号边界提供设备凭据的能力。
///
/// 账号因子由 App／部署选择，ClientKit 只接收签发结果，不持有密码、Passkey 或 SSO
/// 状态。实现者还需遵守注册幂等和收到结果后的持久恢复合同。
public protocol V2AccountDeviceCredentialProvider: Sendable {
    /// 签发或恢复本次设备凭据。
    ///
    /// - Returns: 尚待会话所有者持久收养的凭据。
    /// - Throws: 账号验证、签发、恢复或取消错误；失败不能伪造已建立的本地会话。
    func issueDeviceCredentials() async throws -> V2AuthCredentials
}

/// 对持久化注册操作进行收养确认或放弃交接的可选能力。
///
/// 仅在 V2AuthSession 已持久化并确认拥有凭据后清除收养记录。
/// 不能仅因远端签发成功就删除本地恢复责任。
public protocol V2AccountDeviceCredentialIssueFinalizer: Sendable {
    /// 确认本地已收养该凭据，清除与其匹配的注册／结果恢复记录。
    ///
    /// - Parameter credentials: 需要精确匹配的已收养会话凭据。
    /// - Throws: 恢复记录验证或持久化清理错误。
    func finalizeIssuedDeviceCredentials(_ credentials: V2AuthCredentials) async throws
    /// 将未收养的签发结果交给放弃／撤销恢复流程。
    ///
    /// - Parameter credentials: 原签发结果；不能替换成当前其他会话。
    /// - Throws: 无法持久化恢复责任或完成匹配校验时的错误。
    func discardIssuedDeviceCredentials(_ credentials: V2AuthCredentials) async throws
}

/// 启动边界向 App 暴露的认证和签发恢复状态。
public enum V2ClientSessionBootstrapError: Error, Equatable, Sendable {
    /// 不存在可恢复的认证会话，需要用户重新认证。
    case authenticationRequired
    /// 凭据暂不可访问；不等于账号已退出或数据可以擦除。
    case credentialsUnavailable
    /// 无法确认签发结果已被收养或妥善放弃，需保留恢复责任。
    case credentialIssueRecoveryPending
}

/// 按认证先于存储的顺序协调设备会话与安装绑定数据库。
///
/// App 通过此入口恢复或建立会话，不直接写凭据或绕过安装验证打开数据库。
/// 认证 epoch 在异步存储操作前后检查，防止旧建立流程把 store 交给新会话。
/// 普通 close 只关闭对象，不表示注销远端设备或擦除本地数据。
public actor V2ClientSessionBootstrapper {
    private let authSession: V2AuthSession
    private let localStoreBootstrapper: V2LocalStoreBootstrapper
    private let databaseURL: URL
    private let accountStorage: V2AccountLocalStoreOwner?

    /// 注入认证、安装绑定和账号目录依赖。
    ///
    /// - Parameters:
    ///   - authSession: 设备凭据与认证代次所有者。
    ///   - localStoreBootstrapper: 负责安装绑定验证的数据库打开入口。
    ///   - databaseURL: 未启用账号目录时的主库位置。
    ///   - accountStorageRoot: 可选账号目录根；提供后启用按账号分开的 store 管理。
    ///
    /// 构造不请求网络或打开数据库，首次实际会话操作时才执行。
    public init(authSession: V2AuthSession, localStoreBootstrapper: V2LocalStoreBootstrapper, databaseURL: URL, accountStorageRoot: URL? = nil) {
        self.authSession = authSession
        self.localStoreBootstrapper = localStoreBootstrapper
        self.databaseURL = databaseURL
        accountStorage = accountStorageRoot.map { V2AccountLocalStoreOwner(root: $0, bootstrapper: localStoreBootstrapper) }
    }

    /// 查询账号目录模式下当前 store 的 scope。
    ///
    /// - Parameter store: 需要定位的具体数据库对象。
    /// - Returns: 启用账号目录时的有效 scope；未启用时为 nil。
    /// - Throws: 启用账号目录但对象已失效时的 staleStore 错误。
    public func storageScope(for store: GRDBV2LocalSyncStore) async throws -> V2AccountStorageScope? {
        try await accountStorage?.scope(for: store)
    }

    /// 通过原所有者关闭指定 store，或在无账号目录模式下直接关闭。
    ///
    /// - Parameter store: 已由 App 停止全部访问任务的原对象。
    /// - Throws: 关闭存储失败。方法不清理凭据、下载缓存或服务端会话。
    public func closeLocalStore(_ store: GRDBV2LocalSyncStore) async throws {
        if let accountStorage { try await accountStorage.close(store) }
        else { try await store.close() }
    }

    /// 按配置选择账号目录所有者或原始数据库入口，始终把已确认的账号身份传给安装绑定打开流程。
    private func openLocalStore(userID: IMV2Core.UserID) async throws -> GRDBV2LocalSyncStore {
        if let accountStorage { return try await accountStorage.open(accountID: userID) }
        return try await localStoreBootstrapper.open(databaseURL: databaseURL, userID: userID)
    }

    /// 恢复已有设备会话并打开其账号数据库，不启动新的账号因子流程。
    ///
    /// 获取凭据可能触发会话内部刷新；认证 epoch 在数据库打开前后核对。
    ///
    /// - Returns: 通过安装绑定验证的账号 store。
    /// - Throws: authenticationRequired、credentialsUnavailable，或认证代次／存储错误。
    public func openEstablishedSession() async throws -> GRDBV2LocalSyncStore {
        do {
            let credentials = try await authSession.realtimeCredentials()
            if let epoch = credentials.sessionEpoch { try await authSession.requireAuthenticatedEpoch(epoch) }
            let store = try await openLocalStore(userID: credentials.userID)
            if let epoch = credentials.sessionEpoch { try await authSession.requireAuthenticatedEpoch(epoch) }
            return store
        } catch V2AuthSessionError.unauthenticated {
            throw V2ClientSessionBootstrapError.authenticationRequired
        } catch V2AuthSessionError.credentialsUnavailable {
            throw V2ClientSessionBootstrapError.credentialsUnavailable
        }
    }

    /// 从可信 provider 建立持久会话，然后打开安装绑定的账号数据库。
    ///
    /// 凭据持久提交后才执行 finalizer。取消或旧代次结果按会话实际所有权进行收养确认
    /// 或放弃交接；无法完成交接时报告恢复待处理。数据库打开失败不会自动撤销已落盘凭据，
    /// 后续可通过 openEstablishedSession 恢复。
    ///
    /// - Parameters:
    ///   - provider: 负责账号因子和设备签发／恢复的可信实现。
    ///   - expectedEpoch: 若提供，只有当前代次匹配时才开始建立，避免覆盖较新会话。
    /// - Returns: 新建立会话所属账号的本地 store。
    /// - Throws: 取消、签发／持久化、代次失效、恢复交接或数据库打开错误。
    public func establishSession(using provider: any V2AccountDeviceCredentialProvider, ifCurrent expectedEpoch: V2AuthSessionEpoch? = nil) async throws -> GRDBV2LocalSyncStore {
        try Task.checkCancellation()
        let epoch: V2AuthSessionEpoch
        if let expectedEpoch {
            epoch = try await authSession.beginEstablishment(ifCurrent: expectedEpoch)
        } else {
            epoch = await authSession.beginEstablishment()
        }
        do {
            let credentials = try await provider.issueDeviceCredentials()
            do {
                try Task.checkCancellation()
                try await authSession.establish(credentials, ifCurrent: epoch)
            } catch {
                if error is CancellationError || (error as? V2AuthSessionError) == .sessionInvalidated,
                   let finalizer = provider as? any V2AccountDeviceCredentialIssueFinalizer {
                    do {
                        if try await authSession.ownsCredentialSession(credentials) {
                            try await finalizer.finalizeIssuedDeviceCredentials(credentials)
                        } else {
                            try await finalizer.discardIssuedDeviceCredentials(credentials)
                        }
                    } catch {
                        throw V2ClientSessionBootstrapError.credentialIssueRecoveryPending
                    }
                }
                // An uncertain credential-store save retains the recovery
                // receipt for cold-start comparison with the durable record.
                throw error
            }
            if let finalizer = provider as? any V2AccountDeviceCredentialIssueFinalizer {
                try await finalizer.finalizeIssuedDeviceCredentials(credentials)
            }
            try await authSession.requireCurrentEpoch(epoch)
            let store = try await openLocalStore(userID: credentials.userID)
            try await authSession.requireCurrentEpoch(epoch)
            return store
        } catch {
            await authSession.abandonEstablishment(ifCurrent: epoch)
            throw error
        }
    }
}

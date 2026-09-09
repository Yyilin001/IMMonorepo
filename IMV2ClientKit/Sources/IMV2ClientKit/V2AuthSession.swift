import Foundation
import IMV2Core

/// 包含敏感材料的设备凭证元组。
///
/// 不得写入日志、分析事件或用户可见错误。初始化只检查令牌非空和日期有限，不验证服务端签发或当前有效期。
public struct V2AuthCredentials: Codable, Equatable, Sendable {
    /// 凭证所属用户。
    public let userID: UserID
    /// 凭证绑定设备。
    public let deviceID: DeviceID
    /// 敏感访问令牌。
    public let accessToken: String
    /// 访问令牌期限。
    public let accessTokenExpiresAt: Date
    /// 敏感刷新凭证。
    public let refreshCredential: String
    /// 独立设备撤销凭证。
    public let revocationCredential: V2DeviceRevocationCredential
    /// 撤销凭证期限。
    public let revocationCredentialExpiresAt: Date

    /// 构造认证流程使用的完整数据值。
    ///
    /// - Parameters:
    ///   - userID: 凭证所属用户。
    ///   - deviceID: 凭证绑定设备。
    ///   - accessToken: 敏感访问令牌。
    ///   - accessTokenExpiresAt: 访问令牌期限。
    ///   - refreshCredential: 敏感刷新凭证。
    ///   - revocationCredential: 独立设备撤销凭证。
    ///   - revocationCredentialExpiresAt: 撤销凭证期限。
    /// - Throws: 访问或刷新令牌为空，或任一期限非有限时抛出 malformedCredentials。
    ///
    /// 不读取当前时钟，有限的已到期日期仍可构造。
    public init(
        userID: UserID,
        deviceID: DeviceID,
        accessToken: String,
        accessTokenExpiresAt: Date,
        refreshCredential: String,
        revocationCredential: V2DeviceRevocationCredential,
        revocationCredentialExpiresAt: Date
    ) throws {
        guard !accessToken.isEmpty, !refreshCredential.isEmpty,
              accessTokenExpiresAt.timeIntervalSinceReferenceDate.isFinite,
              revocationCredentialExpiresAt.timeIntervalSinceReferenceDate.isFinite
        else { throw V2AuthSessionError.malformedCredentials }
        self.userID = userID
        self.deviceID = deviceID
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshCredential = refreshCredential
        self.revocationCredential = revocationCredential
        self.revocationCredentialExpiresAt = revocationCredentialExpiresAt
    }
}

/// 凭证及待完成轮换、撤销交接的原子持久化记录。
///
/// 生产存储应将完整记录写入同一 Keychain 项，避免刷新操作身份与被轮换凭证分离。
/// 待撤销标识先于独立撤销发件箱保存，冷启动应完成交接而不能直接恢复登录权限。
public struct V2AuthCredentialRecord: Codable, Equatable, Sendable {
    /// 一致的设备凭证元组。
    public let credentials: V2AuthCredentials
    /// 已持久化但尚待完成的刷新身份。
    public let pendingRefreshOperationID: UUID?
    /// 已开始、待交接到独立撤销队列的操作身份。
    public let pendingRevocationOperationID: UUID?

    /// 构造认证流程使用的完整数据值。
    ///
    /// - Parameters:
    ///   - credentials: 一致的设备凭证元组。
    ///   - pendingRefreshOperationID: 已持久化但尚待完成的刷新身份。
    ///   - pendingRevocationOperationID: 已开始、待交接到独立撤销队列的操作身份。
    ///
    /// 仅保存字段，不执行认证、网络或持久化操作。
    public init(credentials: V2AuthCredentials, pendingRefreshOperationID: UUID? = nil,
                pendingRevocationOperationID: UUID? = nil) {
        self.credentials = credentials
        self.pendingRefreshOperationID = pendingRefreshOperationID
        self.pendingRevocationOperationID = pendingRevocationOperationID
    }

    /// 复制记录并设置待刷新操作身份，保留当前凭证和待撤销标识，不直接执行持久化。
    func withPendingRefreshOperation(_ operationID: UUID) -> V2AuthCredentialRecord {
        .init(credentials: credentials, pendingRefreshOperationID: operationID,
              pendingRevocationOperationID: pendingRevocationOperationID)
    }

    /// 用新凭证创建记录并清除待刷新标识，保留待撤销标识；调用方负责原子保存。
    func clearingPendingRefreshOperation(with credentials: V2AuthCredentials) -> V2AuthCredentialRecord {
        .init(credentials: credentials, pendingRevocationOperationID: pendingRevocationOperationID)
    }
}

/// 凭证存储的暂时不可用、损坏和失效错误分类。
public enum V2CredentialStoreError: Error, Equatable, Sendable {
    /// 受保护数据或 Keychain 服务暂时不可用，不等于凭证已被服务端拒绝。
    case unavailable
    /// 存储记录格式不符合凭证模型。
    case malformedRecord
    /// 存储凭证已永久失效。
    case permanentlyInvalidated
    /// 未分类的平台存储状态码，不携带凭证内容。
    case unexpectedStatus(Int32)
}

/// 完整凭证记录的异步存储边界；实现必须保证一次保存不会拆分凭证与待处理操作身份。
public protocol V2CredentialStore: Sendable {
    /// 读取完整记录，不存在时返回 nil；暂时不可用和记录损坏应通过可区分的错误报告。
    func load() async throws -> V2AuthCredentialRecord?
    /// 原子保存完整凭证记录；失败时不能报告成功或留下各字段分别更新的混合状态。
    func save(_ record: V2AuthCredentialRecord) async throws
    /// 删除持久化凭证记录，失败通过错误报告；不在此执行远端设备撤销。
    func delete() async throws
}

/// 设备凭证轮换请求，携带稳定操作身份以支持相同轮换的重试。
public struct V2RefreshRequest: Equatable, Sendable {
    /// 当前用户。
    public let userID: UserID
    /// 当前设备。
    public let deviceID: DeviceID
    /// 当前敏感刷新凭证。
    public let refreshCredential: String
    /// 设备撤销凭证。
    public let revocationCredential: V2DeviceRevocationCredential
    /// 跨本次轮换重试稳定的身份。
    public let operationID: UUID

    /// 构造认证流程使用的完整数据值。
    ///
    /// - Parameters:
    ///   - userID: 当前用户。
    ///   - deviceID: 当前设备。
    ///   - refreshCredential: 当前敏感刷新凭证。
    ///   - revocationCredential: 设备撤销凭证。
    ///   - operationID: 跨本次轮换重试稳定的身份。
    ///
    /// 仅保存字段，不执行认证、网络或持久化操作。
    public init(userID: UserID, deviceID: DeviceID, refreshCredential: String, revocationCredential: V2DeviceRevocationCredential, operationID: UUID) {
        self.userID = userID
        self.deviceID = deviceID
        self.refreshCredential = refreshCredential
        self.revocationCredential = revocationCredential
        self.operationID = operationID
    }
}

/// 不透明的进程内会话所有权标识，不含凭证，也不等同于服务端持久化设备代际。
public struct V2AuthSessionEpoch: Hashable, Sendable {
    /// 创建该代际的认证会话实例身份。
    fileprivate let owner: UUID
    /// 该实例内部的会话代际计数。
    fileprivate let generation: UInt64
}

/// 供实时握手使用的一致、临时凭证视图。
///
/// 访问令牌只在会话协调器和认证传输之间传递，不应交给界面、分析或另行持久化。
public struct V2ClientRealtimeCredentials: Sendable {
    /// 与令牌同一次读取的用户。
    public let userID: UserID
    /// 与令牌同一次读取的设备。
    public let deviceID: DeviceID
    /// 仅用于本次认证连接的访问令牌。
    public let accessToken: String
    /// 可选本地会话代际，生产协调器用它检查延迟结果是否仍可采用。
    public let sessionEpoch: V2AuthSessionEpoch?

    /// 构造认证流程使用的完整数据值。
    ///
    /// - Parameters:
    ///   - userID: 与令牌同一次读取的用户。
    ///   - deviceID: 与令牌同一次读取的设备。
    ///   - accessToken: 仅用于本次认证连接的访问令牌。
    ///   - sessionEpoch: 可选本地会话代际，生产协调器用它检查延迟结果是否仍可采用。
    ///
    /// 仅保存字段，不执行认证、网络或持久化操作。
    public init(userID: UserID, deviceID: DeviceID, accessToken: String, sessionEpoch: V2AuthSessionEpoch? = nil) {
        self.userID = userID
        self.deviceID = deviceID
        self.accessToken = accessToken
        self.sessionEpoch = sessionEpoch
    }
}

/// 刷新传输的明确认证拒绝分类。
public enum V2AuthTransportError: Error, Equatable, Sendable {
    /// 服务端已明确拒绝该凭证，不能按普通暂时网络故障继续重试。
    case terminalRejection
}

/// 设备凭证轮换的网络边界，暂时失败与明确拒绝必须保留不同错误语义。
public protocol V2AuthTransport: Sendable {
    /// 提交稳定轮换请求并返回新凭证；明确拒绝使用 terminalRejection，其他错误保留给会话重试策略处理。
    func refresh(_ request: V2RefreshRequest) async throws -> V2AuthCredentials
}

/// 认证会话的可观察阶段，不包含访问令牌或刷新凭证。
public enum V2AuthSessionState: Equatable, Sendable {
    /// 尚未完成本地凭证恢复。
    case uninitialized
    /// 正在建立或接纳新的会话。
    case establishing
    /// 当前持有已认证凭证，仅公开访问令牌期限。
    case authenticated(accessTokenExpiresAt: Date)
    /// 正在轮换访问凭证。
    case refreshing
    /// 凭证当前不可读取或使用，不直接等同于退出登录。
    case credentialsUnavailable
    /// 当前没有可用的已认证会话，需要重新认证。
    case unauthenticated
}

/// 特定账户代际的完整观察快照。
///
/// 代际结束后，其终态应被保留并结束观察，不能被后续账户状态在有界缓冲中覆盖。
public struct V2AuthSessionSnapshot: Equatable, Sendable {
    /// 观察代际的结束原因：需要认证、凭证删除仍待完成，或被新代际替换。
    public enum EndReason: Equatable, Sendable {
        case authenticationRequired, credentialDeletionPending, superseded
    }
    /// 观察代际的状态：活动阶段、正在结束或携带原因的最终结束。
    public enum Status: Equatable, Sendable {
        case active(V2AuthSessionState), ending, ended(EndReason)
    }
    /// 该快照所属的进程内账户代际。
    public let epoch: V2AuthSessionEpoch
    /// 本代际完整状态。
    public let status: Status
}

/// 认证会话对调用者报告的凭证、身份和代际错误。
public enum V2AuthSessionError: Error, Equatable, Sendable {
    /// 当前没有可用的已认证会话，需要重新认证。
    case unauthenticated
    /// 凭证当前不可读取或使用，不直接等同于退出登录。
    case credentialsUnavailable
    /// 凭证为空或必要时间值无效。
    case malformedCredentials
    /// 返回或接纳的设备身份与当前会话要求不匹配。
    case deviceMismatch
    /// 异步操作所属会话代际已失效，不能继续采用其结果。
    case sessionInvalidated
}

/// 设备凭证、刷新轮换及会话代际的唯一所有者。
///
/// 通过 actor 隔离内存状态，并用独立 I/O 队列串行化跨挂起点的存储副作用。刷新由多个调用者共享，单个等待者取消不会取消整个轮换。
/// 新登录和退出推进代际，使迟到的加载、刷新和认证结果不能重新接管当前会话。
public actor V2AuthSession: V2ClientMediaEdgeCredentialProvider, V2ClientPushEndpointCredentialProvider, V2ClientDeviceSessionCredentialProvider {
    /// 完整凭证记录的持久化边界，所有副作用通过 credentialIO 排队执行。
    private let credentialStore: any V2CredentialStore
    /// 设备凭证轮换传输，不负责本地记录保存。
    private let transport: any V2AuthTransport
    /// 独立于当前登录生命周期的持久化撤销交接入口。
    private let revocationScheduler: any V2DeviceRevocationScheduling
    /// 生成新刷新或撤销操作身份的可注入工厂。
    private let makeUUID: @Sendable () -> UUID
    /// 访问令牌到期判断使用的可注入时钟。
    private let now: @Sendable () -> Date

    /// 当前内存凭证快照，可能包含尚待完成的刷新身份。
    private var record: V2AuthCredentialRecord?
    /// 当前认证阶段，变更后向当前代际观察者发布快照。
    private var state: V2AuthSessionState = .uninitialized {
        didSet { publishCurrentState() }
    }
    /// 当前生命周期是否已处理本地记录，避免重复恢复。
    private var didLoad = false
    /// 区分不同认证会话实例的进程内身份。
    private let epochOwner = UUID()
    /// 本实例的会话代际计数，推进时使旧异步结果失效。
    private var sessionGeneration: UInt64 = 0
    /// 最后一项存储副作用的完成任务；后继操作先等待它结束，即使前项失败。
    private var credentialIOTail: (id: UUID, task: Task<Void, Never>)?
    /// 终态清理尚未完成的标记，凭证访问时必须优先重试删除交接。
    private var pendingTerminalDeletion = false
    /// 同一代际共享的恢复任务及其独立完成身份。
    private var loadOperation: (id: UUID, generation: UInt64, task: V2SharedOperation<Void>)?
    /// 本代际唯一的共享轮换任务，包含持久化操作身份。
    private var refreshOperation: RefreshOperation?
    /// 绑定固定账户代际的状态流发送端。
    private struct Observer {
        /// 该订阅唯一允许接收的代际。
        let epoch: V2AuthSessionEpoch
        /// 向订阅者发送快照及结束信号的流续体。
        let continuation: AsyncStream<V2AuthSessionSnapshot>.Continuation
    }
    /// 尚未结束的代际观察者，按订阅 UUID 保存。
    private var observers: [UUID: Observer] = [:]
    /// 本次终态清理需要通知的源代际，可能早于当前内部计数。
    private var terminalSourceEpoch: V2AuthSessionEpoch?
    /// 最近结束代际及原因，供迟到订阅与恢复分类使用；不保存全部历史。
    private var lastEnded: (epoch: V2AuthSessionEpoch, reason: V2AuthSessionSnapshot.EndReason)?

    /// 注入凭证持久化、轮换传输及独立设备撤销队列。
    ///
    /// - Parameters:
    ///   - credentialStore: 原子保存完整记录的存储。
    ///   - transport: 执行服务端凭证轮换的传输。
    ///   - revocationScheduler: 接收旧设备会话撤销任务的持久化调度器。
    ///   - makeUUID: 新刷新或撤销操作身份的生成器。
    ///   - now: 判断访问令牌是否到期的时钟。
    ///
    /// 初始化不读取凭证或发起网络请求。
    public init(
        credentialStore: any V2CredentialStore,
        transport: any V2AuthTransport,
        revocationScheduler: any V2DeviceRevocationScheduling,
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
        self.revocationScheduler = revocationScheduler
        self.makeUUID = makeUUID
        self.now = now
    }

    /// 读取内存中的当前认证阶段，不触发凭证恢复或刷新。
    public func currentState() -> V2AuthSessionState { state }

    /// 观察指定代际的状态，立即提供当前快照，仅缓冲最新一项。
    ///
    /// - Parameter epoch: 希望观察的本地会话代际。
    /// - Returns: 该代际结束时先发送终态再结束的流；未知旧代际立即以 superseded 结束。
    ///
    /// 仅保留最近结束代际的原因。订阅结束会移除观察者，不会终止认证会话。
    public func sessionUpdates(for epoch: V2AuthSessionEpoch) -> AsyncStream<V2AuthSessionSnapshot> {
        let stream = AsyncStream<V2AuthSessionSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        if epoch == currentEpoch(), !pendingTerminalDeletion {
            observers[id] = .init(epoch: epoch, continuation: stream.continuation)
            stream.continuation.yield(.init(epoch: epoch, status: .active(state)))
        } else if let ended = lastEnded, ended.epoch == epoch {
            stream.continuation.yield(.init(epoch: epoch, status: .ended(ended.reason)))
            stream.continuation.finish()
        } else if pendingTerminalDeletion, epoch == terminalSourceEpoch {
            observers[id] = .init(epoch: epoch, continuation: stream.continuation)
            stream.continuation.yield(.init(epoch: epoch, status: .ending))
        } else {
            let reason = lastEnded?.epoch == epoch ? lastEnded!.reason : .superseded
            stream.continuation.yield(.init(epoch: epoch, status: .ended(reason)))
            stream.continuation.finish()
        }
        stream.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream.stream
    }

    /// 移除结束的状态订阅，不改变认证会话。
    private func removeObserver(_ id: UUID) { observers[id] = nil }

    /// 仅向当前代际发布活动状态；终态删除待完成时抑制活动快照，避免覆盖结束过程。
    private func publishCurrentState() {
        guard !pendingTerminalDeletion else { return }
        let epoch = currentEpoch()
        for observer in observers.values where observer.epoch == epoch {
            observer.continuation.yield(.init(epoch: epoch, status: .active(state)))
        }
    }

    /// 记录最近终态，向对应代际发送 ended 后结束其流并移除观察者。
    private func finishObservers(for epoch: V2AuthSessionEpoch, reason: V2AuthSessionSnapshot.EndReason) {
        lastEnded = (epoch, reason)
        for (id, observer) in observers where observer.epoch == epoch {
            observer.continuation.yield(.init(epoch: epoch, status: .ended(reason)))
            observer.continuation.finish()
            observers[id] = nil
        }
    }

    /// 记住清理源代际并发送 ending，后续清理成功或失败再发送终态。
    private func beginTerminalObservation(from epoch: V2AuthSessionEpoch) {
        terminalSourceEpoch = epoch
        for observer in observers.values where observer.epoch == epoch {
            observer.continuation.yield(.init(epoch: epoch, status: .ending))
        }
    }

    /// 将清理结果发送给已记录的源代际，不向新账户代际传播。
    private func finishTerminalObservation(_ reason: V2AuthSessionSnapshot.EndReason) {
        if let epoch = terminalSourceEpoch { finishObservers(for: epoch, reason: reason) }
    }

    /// 恢复本地凭证状态，不主动轮换访问令牌。
    ///
    /// - Returns: 恢复后的阶段；无凭证或恢复流程确定需要重新认证时返回 unauthenticated。
    /// - Throws: 存储暂时不可用、代际变化或其他恢复错误。
    ///
    /// 遇到待撤销记录时会先交接撤销任务并删除记录，不能将其恢复为登录状态。
    public func restoreState() async throws -> V2AuthSessionState {
        do { try await loadIfNeeded() }
        catch V2AuthSessionError.unauthenticated { return .unauthenticated }
        return state
    }


    /// 读取本实例当前的进程内代际标识，不建立会话或改变凭证。
    public func currentEpoch() -> V2AuthSessionEpoch { .init(owner: epochOwner, generation: sessionGeneration) }

    /// 校验异步操作仍属于当前代际。
    ///
    /// - Parameter epoch: 操作开始时捕获的代际。
    /// - Throws: 不属于当前代际时抛出 sessionInvalidated；此检查本身不验证认证阶段。
    public func requireCurrentEpoch(_ epoch: V2AuthSessionEpoch) throws {
        guard epoch == currentEpoch() else { throw V2AuthSessionError.sessionInvalidated }
    }

    /// 校验代际及可继续认证业务的状态。
    ///
    /// 当前代际处于 authenticated 或 refreshing 时通过；尚未建立的会话不通过。
    /// 最近结束的旧代际按结束原因报告未认证或存储不可用，其余旧代际报告失效。
    /// - Throws: unauthenticated、credentialsUnavailable 或 sessionInvalidated。
    public func requireAuthenticatedEpoch(_ epoch: V2AuthSessionEpoch) throws {
        if epoch != currentEpoch() {
            if let ended = lastEnded, ended.epoch == epoch {
                switch ended.reason {
                case .authenticationRequired: throw V2AuthSessionError.unauthenticated
                case .credentialDeletionPending: throw V2AuthSessionError.credentialsUnavailable
                case .superseded: break
                }
            }
            throw V2AuthSessionError.sessionInvalidated
        }
        switch state {
        case .authenticated, .refreshing: return
        case .unauthenticated: throw V2AuthSessionError.unauthenticated
        case .credentialsUnavailable: throw V2AuthSessionError.credentialsUnavailable
        case .uninitialized, .establishing: throw V2AuthSessionError.sessionInvalidated
        }
    }

    /// 为新的登录意图预留代际，清除内存凭证并进入 establishing。
    ///
    /// - Returns: 后续异步注册结果提交时必须携带的代际。
    ///
    /// 此步骤不删除持久化旧凭证；实际接纳新凭证时负责旧会话交接。
    public func beginEstablishment() -> V2AuthSessionEpoch {
        advanceGeneration()
        pendingTerminalDeletion = false
        record = nil
        didLoad = true
        state = .establishing
        return currentEpoch()
    }

    /// 确认任务未取消且预期代际仍有效后，为登录意图预留新代际。
    ///
    /// - Parameter expectedEpoch: 异步注册准备开始前捕获的代际。
    /// - Returns: 新建立流程的代际。
    /// - Throws: 任务取消或 sessionInvalidated，避免迟到的登录准备撤销后续退出意图。
    public func beginEstablishment(ifCurrent expectedEpoch: V2AuthSessionEpoch) throws -> V2AuthSessionEpoch {
        try Task.checkCancellation()
        try requireCurrentEpoch(expectedEpoch)
        return beginEstablishment()
    }

    /// 推进代际以使已有异步工作失效，保留现有凭证供已授权的退出清理使用。
    ///
    /// 调用方应先持久化退出意图。本方法不删除凭证，也不表示远端撤销完成；没有内存凭证时允许后续重新加载。
    public func invalidateOutstandingWork() {
        advanceGeneration()
        if let record {
            state = .authenticated(accessTokenExpiresAt: record.credentials.accessTokenExpiresAt)
        } else {
            didLoad = false
            state = .uninitialized
        }
    }

    /// 仅在指定代际仍处于 establishing 时放弃建立流程，重置为可重新加载；不会删除持久化凭证。
    public func abandonEstablishment(ifCurrent epoch: V2AuthSessionEpoch) {
        guard epoch == currentEpoch(), state == .establishing else { return }
        didLoad = false
        state = .uninitialized
    }

    /// 预留新的登录代际并持久化可信注册边界提供的凭证。
    ///
    /// - Parameter credentials: 已由账户或设备注册流程获得的完整凭证。
    /// - Throws: 代际失效或凭证持久化失败。
    ///
    /// 调用方不得绕过本 actor 直接写入凭证存储，以免破坏刷新与账户切换的顺序。
    public func establish(_ credentials: V2AuthCredentials) async throws {
        let epoch = beginEstablishment()
        try await establish(credentials, ifCurrent: epoch)
    }

    /// 在预留代际仍有效时保存新凭证，保存完成后进入 authenticated。
    ///
    /// - Parameters:
    ///   - credentials: 可信注册边界提供的凭证。
    ///   - epoch: 建立流程预留的代际。
    /// - Throws: sessionInvalidated 或 credentialsUnavailable。
    ///
    /// 不自行检查令牌当前有效期；覆盖其他用户或设备前先持久化其撤销交接。
    public func establish(_ credentials: V2AuthCredentials, ifCurrent epoch: V2AuthSessionEpoch) async throws {
        try requireCurrentEpoch(epoch)
        try await save(.init(credentials: credentials), generation: epoch.generation)
        state = .authenticated(accessTokenExpiresAt: credentials.accessTokenExpiresAt)
    }

    /// 等待已排队存储副作用后，比较持久化记录的用户、设备及撤销凭证身份。
    ///
    /// - Returns: 记录存在、没有待撤销标识且会话身份一致时为 true；不要求访问令牌仍与输入相同。
    /// - Throws: 存储读取或代际校验错误，调用方应保留其恢复回执。
    ///
    /// 用于避免迟到的重复注册结果撤销已被新代际接纳的同一设备会话。
    func ownsCredentialSession(_ credentials: V2AuthCredentials) async throws -> Bool {
        let stored = try await credentialIO(generation: sessionGeneration) { try await $0.load() }
        guard let stored, stored.pendingRevocationOperationID == nil else { return false }
        return stored.credentials.userID == credentials.userID && stored.credentials.deviceID == credentials.deviceID &&
            stored.credentials.revocationCredential == credentials.revocationCredential &&
            stored.credentials.revocationCredentialExpiresAt == credentials.revocationCredentialExpiresAt
    }

    /// 恢复记录并取得同一代际的一致凭证元组。
    ///
    /// 访问令牌期限严格晚于当前时钟才直接使用，恰好到期或已到期则刷新；刷新返回后再次校验代际。
    /// - Throws: 无凭证、存储不可用、轮换失败或代际失效。
    private func coherentCredentials() async throws -> (V2AuthCredentials, V2AuthSessionEpoch) {
        try await loadIfNeeded()
        guard let record else { throw V2AuthSessionError.unauthenticated }
        let epoch = currentEpoch()
        let credentials = record.credentials.accessTokenExpiresAt > now() ? record.credentials : try await refresh()
        try requireCurrentEpoch(epoch)
        return (credentials, epoch)
    }

    /// 返回一致凭证中的访问令牌，必要时恢复记录或共享刷新；错误沿认证流程传播。
    public func accessToken() async throws -> String { try await coherentCredentials().0.accessToken }

    /// 从一次一致读取生成媒体服务使用的访问令牌与设备身份，必要时刷新凭证。
    public func mediaEdgeCredentials() async throws -> V2ClientMediaEdgeCredentials {
        let (credentials, _) = try await coherentCredentials()
        return .init(accessToken: credentials.accessToken, deviceID: credentials.deviceID)
    }

    /// 生成推送端点管理凭证，复用一致的令牌与设备读取路径及其错误语义。
    public func pushEndpointCredentials() async throws -> V2ClientPushEndpointCredentials {
        let credentials = try await mediaEdgeCredentials()
        return .init(accessToken: credentials.accessToken, deviceID: credentials.deviceID)
    }

    /// 生成设备会话管理凭证，复用一致的令牌与设备读取路径及其错误语义。
    public func deviceSessionCredentials() async throws -> V2ClientDeviceSessionCredentials {
        let credentials = try await mediaEdgeCredentials()
        return .init(accessToken: credentials.accessToken, deviceID: credentials.deviceID)
    }

    /// 从一次一致读取生成实时握手元组及所属代际，供协调器在网络握手后再次校验所有权。
    public func realtimeCredentials() async throws -> V2ClientRealtimeCredentials {
        let (credentials, epoch) = try await coherentCredentials()
        return .init(userID: credentials.userID, deviceID: credentials.deviceID,
                     accessToken: credentials.accessToken, sessionEpoch: epoch)
    }

    /// 执行或等待本代际共享的凭证轮换，即使访问令牌尚未到期也可主动调用。
    ///
    /// - Returns: 已完整持久化的新凭证。
    /// - Throws: 加载、轮换、存储、等待取消或代际校验错误。
    ///
    /// 冷启动复用持久化的待刷新操作身份，暂时传输失败保留该身份供重试。单个调用者取消等待不取消共享轮换。
    public func refresh() async throws -> V2AuthCredentials {
        try await loadIfNeeded()
        guard let currentRecord = record else { throw V2AuthSessionError.unauthenticated }
        let operation: RefreshOperation
        if let existing = refreshOperation {
            operation = existing
        } else {
            operation = startRefresh(from: currentRecord)
            refreshOperation = operation
        }
        let credentials = try await operation.task.value
        try ensureGeneration(operation.sessionGeneration)
        return credentials
    }

    /// 处理业务 HTTP 401，仅当代际、设备及被拒绝令牌仍对应当前记录时刷新。
    ///
    /// 旧令牌的迟到响应直接返回，不能触发下一次轮换；共享刷新前后均检查任务取消及代际。
    /// - Throws: 任务取消、代际失效、无凭证、设备不匹配或轮换错误。
    func refreshAfterHTTPUnauthorized(ifCurrent epoch: V2AuthSessionEpoch,
                                      rejectedAccessToken: String, deviceID: DeviceID) async throws {
        try Task.checkCancellation()
        try requireCurrentEpoch(epoch)
        guard let record else { throw V2AuthSessionError.unauthenticated }
        guard record.credentials.deviceID == deviceID else { throw V2AuthSessionError.deviceMismatch }
        guard record.credentials.accessToken == rejectedAccessToken else { return }
        _ = try await refresh()
        try Task.checkCancellation()
        try requireCurrentEpoch(epoch)
    }

    /// 结束当前会话并执行撤销交接与凭证删除；存储失败保留待删除状态并抛出错误。
    public func handleTerminalRejection() async throws { try await clearForTerminalState() }

    /// 仅允许当前代际的明确拒绝结束会话。
    ///
    /// - Parameters:
    ///   - epoch: 被拒绝请求所属代际。
    ///   - rejectedAccessToken: 可选被拒绝令牌；提供时还要求令牌仍相同且没有正在进行的刷新。
    /// - Throws: 所有权不再匹配时抛出 sessionInvalidated；清理失败报告存储不可用。
    ///
    /// 避免旧 TLS 握手结果终止正在轮换或已取得新令牌的会话。
    public func handleTerminalRejection(ifCurrent epoch: V2AuthSessionEpoch, rejectedAccessToken: String? = nil) async throws {
        try requireCurrentEpoch(epoch)
        if let rejectedAccessToken {
            // A TLS attempt may refer to a predecessor access token even
            // within the same session epoch. A refresh in flight owns the
            // successor decision; its old handshake cannot revoke that result.
            guard refreshOperation == nil, record?.credentials.accessToken == rejectedAccessToken else {
                throw V2AuthSessionError.sessionInvalidated
            }
        }
        try await clearForTerminalState()
    }

    /// 仅在 credentialsUnavailable 时清空内存加载状态，使下一次访问重试存储；不删除持久化记录。
    public func retryCredentialStoreAccess() {
        guard state == .credentialsUnavailable else { return }
        didLoad = false
        record = nil
        loadOperation = nil
        state = .uninitialized
    }

    /// 推进代际并释放共享恢复引用、取消共享刷新；普通替换还将旧观察者结束为 superseded，终态清理则保留源代际观察流程。
    private func advanceGeneration(endingCurrentEpoch: Bool = false) {
        if !endingCurrentEpoch {
            if let terminalSourceEpoch { finishObservers(for: terminalSourceEpoch, reason: .superseded) }
            for epoch in Set(observers.values.map(\.epoch)) { finishObservers(for: epoch, reason: .superseded) }
            terminalSourceEpoch = nil
        }
        sessionGeneration &+= 1
        loadOperation = nil
        refreshOperation?.task.cancel()
        refreshOperation = nil
    }

    /// 要求内部计数仍与操作启动时一致，否则抛出 sessionInvalidated。
    private func ensureGeneration(_ generation: UInt64) throws {
        guard generation == sessionGeneration else { throw V2AuthSessionError.sessionInvalidated }
    }

    /// 将实际存储副作用排在上一项完成之后，并在执行前后校验代际。
    ///
    /// 已开始的旧保存会先完成，再轮到后续保存或删除，避免旧写入最后覆盖新会话。
    /// - Throws: 代际变化或存储操作本身的错误。
    private func credentialIO<T: Sendable>(
        generation: UInt64,
        _ work: @escaping @Sendable (any V2CredentialStore) async throws -> T
    ) async throws -> T {
        let previous = credentialIOTail?.task
        let id = UUID()
        let task = Task { [credentialStore] in
            await previous?.value
            try self.ensureGeneration(generation)
            do {
                let result = try await work(credentialStore)
                try self.ensureGeneration(generation)
                return result
            } catch {
                try self.ensureGeneration(generation)
                throw error
            }
        }
        credentialIOTail = (id, Task { _ = await task.result })
        defer { if credentialIOTail?.id == id { credentialIOTail = nil } }
        return try await task.value
    }

    /// 按需复用本代际的恢复任务，建立新会话期间拒绝加载旧记录。
    ///
    /// 待终态删除优先于普通恢复；已加载但存储不可用时明确报告错误。单个等待者取消不取消共享加载。
    /// - Throws: 代际失效、存储不可用、取消或恢复流程错误。
    private func loadIfNeeded() async throws {
        guard state != .establishing else { throw V2AuthSessionError.sessionInvalidated }
        if pendingTerminalDeletion { try await deleteCurrentRecord(generation: sessionGeneration); return }
        guard !didLoad else {
            if state == .credentialsUnavailable { throw V2AuthSessionError.credentialsUnavailable }
            return
        }
        let generation = sessionGeneration
        let operation: (id: UUID, generation: UInt64, task: V2SharedOperation<Void>)
        if let existing = loadOperation, existing.generation == generation { operation = existing }
        else {
            let id = UUID()
            operation = (id, generation, V2SharedOperation {
                do { try await self.loadRecord(generation: generation) }
                catch { await self.finishLoad(id: id); throw error }
                await self.finishLoad(id: id)
            })
            loadOperation = operation
        }
        try await operation.task.value
    }

    /// 仅清除身份仍匹配的加载任务引用，避免旧完成回调清除后续恢复。
    private func finishLoad(id: UUID) {
        if loadOperation?.id == id { loadOperation = nil }
    }

    /// 通过串行 I/O 读取记录；待撤销标识触发交接删除，普通记录恢复到内存。
    ///
    /// 损坏或永久失效记录进入删除流程，暂时不可访问则进入 credentialsUnavailable。
    /// 读取成功不会立即刷新已到期的访问令牌，轮换在实际取用凭证时处理。
    private func loadRecord(generation: UInt64) async throws {
        do {
            let loaded = try await credentialIO(generation: generation) { try await $0.load() }
            if loaded?.pendingRevocationOperationID != nil {
                pendingTerminalDeletion = true
                beginTerminalObservation(from: currentEpoch())
                try await deleteCurrentRecord(generation: generation)
                return
            }
            record = loaded
            didLoad = true
            state = loaded.map { .authenticated(accessTokenExpiresAt: $0.credentials.accessTokenExpiresAt) } ?? .unauthenticated
        } catch let error as V2CredentialStoreError {
            switch error {
            case .malformedRecord, .permanentlyInvalidated:
                pendingTerminalDeletion = true
                beginTerminalObservation(from: currentEpoch())
                try await deleteCurrentRecord(generation: generation)
                throw V2AuthSessionError.unauthenticated
            case .unavailable, .unexpectedStatus:
                state = .credentialsUnavailable
                throw V2AuthSessionError.credentialsUnavailable
            }
        }
    }

    /// 在同一串行存储操作中检查旧记录并保存新会话。
    ///
    /// 不同用户或设备被替换前，先持久化旧记录的撤销身份并交接队列；同一用户设备已有撤销标记时拒绝直接覆盖。
    /// 成功后才更新内存；当前代际内失败统一报告 credentialsUnavailable，代际变化保留 sessionInvalidated。
    private func save(_ next: V2AuthCredentialRecord, generation: UInt64) async throws {
        do {
            try await credentialIO(generation: generation) { [revocationScheduler, makeUUID] store in
                let prior: V2AuthCredentialRecord?
                do { prior = try await store.load() }
                catch V2CredentialStoreError.malformedRecord { prior = nil }
                catch V2CredentialStoreError.permanentlyInvalidated { prior = nil }
                if let prior {
                    let sameDevice = prior.credentials.deviceID == next.credentials.deviceID &&
                        prior.credentials.userID == next.credentials.userID
                    if sameDevice {
                        guard prior.pendingRevocationOperationID == nil else {
                            throw V2AuthSessionError.sessionInvalidated
                        }
                    } else {
                        // A prior login can remain durable after local-store
                        // setup fails. Replacement must hand it off even if
                        // explicit sign-out never marked that credential.
                        let operationID = prior.pendingRevocationOperationID ?? makeUUID()
                        if prior.pendingRevocationOperationID == nil {
                            try await store.save(.init(credentials: prior.credentials,
                                pendingRefreshOperationID: prior.pendingRefreshOperationID,
                                pendingRevocationOperationID: operationID))
                        }
                        try await revocationScheduler.enqueue(.init(credentials: prior.credentials, operationID: operationID))
                    }
                }
                try await store.save(next)
            }
            record = next
            didLoad = true
        } catch {
            try ensureGeneration(generation)
            state = .credentialsUnavailable
            throw V2AuthSessionError.credentialsUnavailable
        }
    }

    /// 推进代际使旧工作失效，清空内存凭证并开始终态观察，然后等待撤销交接与存储删除。
    private func clearForTerminalState() async throws {
        let source = currentEpoch()
        advanceGeneration(endingCurrentEpoch: true)
        pendingTerminalDeletion = true
        beginTerminalObservation(from: source)
        record = nil
        didLoad = true
        state = .unauthenticated
        try await deleteCurrentRecord(generation: sessionGeneration)
    }

    /// 先持久化稳定撤销身份并入队，再删除原凭证，所有副作用共用同一 I/O 顺序。
    ///
    /// 成功后清除待删除标记并结束为 authenticationRequired；当前代际清理失败保留待删除状态，结束观察为 credentialDeletionPending 并报告存储不可用。
    /// 损坏或永久失效而无法读取的记录仍允许删除。
    private func deleteCurrentRecord(generation: UInt64) async throws {
        do {
            try await credentialIO(generation: generation) { [revocationScheduler, makeUUID] store in
                let stored: V2AuthCredentialRecord?
                do { stored = try await store.load() }
                catch V2CredentialStoreError.malformedRecord { stored = nil }
                catch V2CredentialStoreError.permanentlyInvalidated { stored = nil }
                if let stored {
                    let operationID = stored.pendingRevocationOperationID ?? makeUUID()
                    if stored.pendingRevocationOperationID == nil {
                        try await store.save(.init(credentials: stored.credentials,
                            pendingRefreshOperationID: stored.pendingRefreshOperationID,
                            pendingRevocationOperationID: operationID))
                    }
                    try await revocationScheduler.enqueue(.init(credentials: stored.credentials, operationID: operationID))
                }
                // All effects share one IO owner. A newer login cannot save
                // until this old-session handoff and deletion have drained.
                try await store.delete()
            }
            record = nil
            didLoad = true
            pendingTerminalDeletion = false
            state = .unauthenticated
            finishTerminalObservation(.authenticationRequired)
        } catch {
            try ensureGeneration(generation)
            state = .credentialsUnavailable
            finishTerminalObservation(.credentialDeletionPending)
            throw V2AuthSessionError.credentialsUnavailable
        }
    }

    /// 在首次挂起前固定内存中的操作身份，创建会话拥有的共享轮换任务，并由该任务统一完成状态收尾。
    private func startRefresh(from currentRecord: V2AuthCredentialRecord) -> RefreshOperation {
        let generation = sessionGeneration
        let operationID: UUID
        let recordToPersist: V2AuthCredentialRecord?
        let pendingRecord: V2AuthCredentialRecord
        if let pending = currentRecord.pendingRefreshOperationID {
            operationID = pending
            pendingRecord = currentRecord
            recordToPersist = nil
        } else {
            operationID = makeUUID()
            pendingRecord = currentRecord.withPendingRefreshOperation(operationID)
            recordToPersist = pendingRecord
        }
        // Make the in-memory state use the same operation ID before any await.
        // The actor-owned task writes it durably before contacting the server.
        record = pendingRecord
        let request = V2RefreshRequest(
            userID: pendingRecord.credentials.userID,
            deviceID: pendingRecord.credentials.deviceID,
            refreshCredential: pendingRecord.credentials.refreshCredential,
            revocationCredential: pendingRecord.credentials.revocationCredential,
            operationID: operationID
        )
        state = .refreshing
        // This unstructured task must outlive an individual caller's
        // cancellation so all callers share exactly one credential rotation
        // for the device. It remains actor-owned so every external write is
        // fenced against logout or newly established credentials.
        return .init(
            operationID: operationID,
            sessionGeneration: generation,
            task: V2SharedOperation { [weak self] in
                guard let self else { throw V2AuthSessionError.sessionInvalidated }
                let result: Result<V2AuthCredentials, Error>
                do {
                    result = .success(try await self.performRefresh(
                        operationID: operationID,
                        sessionGeneration: generation,
                        pendingRecord: pendingRecord,
                        recordToPersist: recordToPersist,
                        request: request
                    ))
                } catch { result = .failure(error) }
                // Finalize once inside the shared task. A resumed waiter must
                // never finalize a failed attempt again or disturb a retry
                // that reuses the same durable operation ID.
                return try await self.finish(
                    operationID: operationID,
                    sessionGeneration: generation,
                    sourceRecord: pendingRecord,
                    result: result
                )
            }
        )
    }

    /// 先保存待刷新身份，再请求服务端轮换，校验用户、设备及撤销凭证未被改变。
    ///
    /// 完整保存后继记录并再次校验代际与刷新身份后才返回。此处不额外校验新访问令牌期限是否晚于当前时钟。
    /// - Throws: 存储、传输、身份不匹配、凭证异常或刷新所有权失效。
    private func performRefresh(
        operationID: UUID,
        sessionGeneration: UInt64,
        pendingRecord: V2AuthCredentialRecord,
        recordToPersist: V2AuthCredentialRecord?,
        request: V2RefreshRequest
    ) async throws -> V2AuthCredentials {
        try ensureRefreshIsCurrent(operationID: operationID, sessionGeneration: sessionGeneration)
        if let recordToPersist {
            try await credentialIO(generation: sessionGeneration) { try await $0.save(recordToPersist) }
            try ensureRefreshIsCurrent(operationID: operationID, sessionGeneration: sessionGeneration)
        }

        let refreshed = try await transport.refresh(request)
        guard refreshed.userID == pendingRecord.credentials.userID,
              refreshed.deviceID == pendingRecord.credentials.deviceID
        else { throw V2AuthSessionError.deviceMismatch }
        guard refreshed.revocationCredential == pendingRecord.credentials.revocationCredential,
              refreshed.revocationCredentialExpiresAt == pendingRecord.credentials.revocationCredentialExpiresAt
        else { throw V2AuthSessionError.malformedCredentials }
        try ensureRefreshIsCurrent(operationID: operationID, sessionGeneration: sessionGeneration)

        // A waiter receives success only after the entire successor record is
        // durable; this prevents a process kill from losing a completed refresh
        // rotation. The second fence prevents a stale response from recreating
        // credentials after terminal logout or a new authenticated session.
        let successor = pendingRecord.clearingPendingRefreshOperation(with: refreshed)
        try await credentialIO(generation: sessionGeneration) { try await $0.save(successor) }
        try ensureRefreshIsCurrent(operationID: operationID, sessionGeneration: sessionGeneration)
        return refreshed
    }

    /// 同时校验会话代际与刷新操作身份，拒绝已经替换、结束或失去所有权的轮换结果。
    private func ensureRefreshIsCurrent(operationID: UUID, sessionGeneration: UInt64) throws {
        guard self.sessionGeneration == sessionGeneration,
              refreshOperation?.operationID == operationID
        else { throw V2AuthSessionError.sessionInvalidated }
    }

    /// 统一收尾共享刷新：成功接纳已持久化凭证，明确拒绝进入终态清理，其他失败保留待刷新记录供恢复或重试。
    private func finish(
        operationID: UUID,
        sessionGeneration: UInt64,
        sourceRecord: V2AuthCredentialRecord,
        result: Result<V2AuthCredentials, Error>
    ) async throws -> V2AuthCredentials {
        try ensureRefreshIsCurrent(operationID: operationID, sessionGeneration: sessionGeneration)

        switch result {
        case .success(let refreshed):
            refreshOperation = nil
            record = sourceRecord.clearingPendingRefreshOperation(with: refreshed)
            didLoad = true
            state = .authenticated(accessTokenExpiresAt: refreshed.accessTokenExpiresAt)
            return refreshed
        case .failure(let error):
            refreshOperation = nil
            if error is V2CredentialStoreError {
                state = .credentialsUnavailable
                throw V2AuthSessionError.credentialsUnavailable
            }
            if let transportError = error as? V2AuthTransportError,
               transportError == .terminalRejection
            {
                try await clearForTerminalState()
                throw V2AuthSessionError.unauthenticated
            }
            // The pending record remains intact; neither a network failure nor
            // a malformed server response is permission to log the user out.
            if record != nil { state = .authenticated(accessTokenExpiresAt: sourceRecord.credentials.accessTokenExpiresAt) }
            throw error
        }
    }
}

/// 共享刷新任务的所有权记录，分离持久化操作身份与本地会话代际。
private struct RefreshOperation {
    /// 稳定的服务端轮换操作身份，暂时失败后可复用。
    let operationID: UUID
    /// 本次轮换所属的本地代际。
    let sessionGeneration: UInt64
    /// 执行轮换及统一收尾的共享任务，单个等待取消不终止它。
    let task: V2SharedOperation<V2AuthCredentials>
}

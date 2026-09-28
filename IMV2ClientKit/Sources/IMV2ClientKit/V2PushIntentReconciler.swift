import Foundation
import IMV2Core

/// 单次推送意图协调的结果。
public enum V2PushReconcileResult: Equatable, Sendable {
    /// 当前无需推进。
    case idle
    /// 已向服务端推进一步。
    case advanced
    /// 本次工作已被更新的状态取代。
    case superseded
    /// 已安排重试。
    case retryScheduled
    /// 已暂停等待用户或重新认证介入。
    case paused
}

/// 单个账号与安装绑定的推送意图协调器。
///
/// 本地输入与那一次 HTTP 往返相互独立地合并，因此旧的 PUT 仍在进行时，
/// 用户的关闭操作也能被持久化下来。
public actor V2PushIntentReconciler {
    private struct Token: Sendable {
        let id: UUID; let provider: V2ClientPushEndpointProvider
        let environment: V2ClientPushEndpointEnvironment; let value: String
    }
    private let store: GRDBV2LocalSyncStore
    private let transport: any V2ClientPushIntentPublishing
    private let scope: V2PushIntentScope
    private let ownerID: UUID
    private let now: @Sendable () -> Date
    private var preference: Bool
    private var desired: Bool
    private var token: Token?
    private var inputID = UUID()
    private var persistedInputID: UUID?
    private var inputTask: (UUID, Task<Void, any Error>)?
    private var flight: (UUID, Task<V2PushReconcileResult, any Error>)?
    private var runTask: (UUID, Task<Void, any Error>)?
    private var stopped = false
    private var signingOut = false

    /// 激活一个新的推送所有者并返回协调器。
    ///
    /// 调用方必须在获取之前与本次等待之后校验自身的认证生命周期状态；
    /// 这里不会对陈旧的比较并交换结果自动重试。
    ///
    /// - Parameters:
    ///   - store: 本地同步存储。
    ///   - transport: 推送意图传输实现。
    ///   - scope: 目标作用域。
    ///   - initialPreference: 初始偏好开关。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Returns: 已激活的协调器。
    /// - Throws: 任务取消或存储失败时抛出。
    public static func activate(store: GRDBV2LocalSyncStore, transport: any V2ClientPushIntentPublishing,
                                scope: V2PushIntentScope, initialPreference: Bool, now: @escaping @Sendable () -> Date = Date.init) async throws -> V2PushIntentReconciler {
        try Task.checkCancellation()
        let previous = try await store.inspectPushIntent(scope: scope)
        try Task.checkCancellation()
        let owner = UUID()
        let state = try await store.activatePushIntent(scope: scope, ownerID: owner, initialPreference: initialPreference, replacing: previous)
        try Task.checkCancellation()
        return .init(store: store, transport: transport, state: state, now: now)
    }

    private init(store: GRDBV2LocalSyncStore, transport: any V2ClientPushIntentPublishing, state: V2LocalPushIntent, now: @escaping @Sendable () -> Date) {
        self.store = store; self.transport = transport; scope = state.scope; ownerID = state.ownerID
        preference = state.preferenceEnabled; desired = state.desiredEnabled; self.now = now
        persistedInputID = inputID
    }

    /// 订阅该所有者的意图变更。
    ///
    /// - Returns: 推送意图变更流。
    public nonisolated func updates() -> AsyncThrowingStream<V2LocalPushIntent, any Error> {
        store.pushIntentUpdates(scope: scope, ownerID: ownerID)
    }

    /// 读取当前推送意图。
    ///
    /// - Returns: 当前意图。
    /// - Throws: 记录缺失或所有者已过期时抛出。
    public func state() async throws -> V2LocalPushIntent {
        try await store.pushIntent(scope: scope, ownerID: ownerID)
    }

    /// 设置推送开关。
    ///
    /// 期望状态发生变化时会清除已暂存的内存令牌引用。
    ///
    /// - Parameter enabled: 目标开关状态。
    /// - Throws: 协调器已停止或正在登出时抛出 `CancellationError`；其余失败来自持久化。
    public func setEnabled(_ enabled: Bool) async throws {
        guard !stopped, !signingOut else { throw CancellationError() }
        if desired != enabled { token = nil }
        preference = enabled; desired = enabled; inputID = UUID()
        try await persistInputs()
    }

    /// 接收系统推送令牌并暂存其引用。
    ///
    /// 未开启推送时忽略；令牌内容需非空、不超过 4096 字节且不含空白与控制字符。
    ///
    /// - Parameters:
    ///   - provider: 推送提供方。
    ///   - environment: 运行环境。
    ///   - value: 令牌内容。
    /// - Throws: 协调器已停止或正在登出时抛出 `CancellationError`；
    ///   令牌不合法时抛出 ``V2ClientPushEndpointError/invalidRegistration``。
    public func receiveToken(provider: V2ClientPushEndpointProvider, environment: V2ClientPushEndpointEnvironment, value: String) async throws {
        guard !stopped, !signingOut else { throw CancellationError() }
        guard desired else { return }
        guard !value.isEmpty, value.utf8.count <= 4_096, value.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0) }) else { throw V2ClientPushEndpointError.invalidRegistration }
        if token?.provider == provider, token?.environment == environment, token?.value == value {
            try await persistInputs()
            return
        }
        token = .init(id: UUID(), provider: provider, environment: environment, value: value); inputID = UUID()
        try await persistInputs()
    }

    /// 在调用方清除凭据之前持久化最终的关闭状态。
    ///
    /// 之后到达的令牌回调无法逆转该所有者的登出决定。
    ///
    /// - Throws: 协调器已停止时抛出 `CancellationError`；其余失败来自持久化。
    public func prepareSignOut() async throws {
        guard !stopped else { throw CancellationError() }
        signingOut = true; desired = false; token = nil; inputID = UUID()
        try await persistInputs()
    }

    /// 仅在用户显式操作或重新认证后重启会话；陈旧状态绝不会自动重新接管。
    ///
    /// - Throws: 协调器已停止时抛出 `CancellationError`；其余失败来自持久化。
    public func restartSession() async throws {
        guard !stopped else { throw CancellationError() }
        try await persistInputs()
        let current = try await state()
        try Task.checkCancellation()
        _ = try await store.restartPushIntentSession(expected: current)
    }

    /// 启动按调度节奏持续协调的循环，直到任务被取消。
    ///
    /// - Throws: 协调器已停止时抛出 `CancellationError`；循环内部失败时抛出底层错误。
    public func run() async throws {
        guard !stopped else { throw CancellationError() }
        let current: (UUID, Task<Void, any Error>)
        if let runTask { current = runTask }
        else {
            current = (UUID(), Task { [self] in
                try await V2CommandRetryScheduler(schedule: store.pushIntentSchedule(scope: scope, ownerID: ownerID), flush: { [self] in _ = try await flushOnce() }, now: now).run()
            })
            runTask = current
        }
        let result = await withTaskCancellationHandler { await current.1.result } onCancel: {
            current.1.cancel()
            Task { await self.stop() }
        }
        if runTask?.0 == current.0 { runTask = nil }
        try Task.checkCancellation()
        try result.get()
    }

    /// 执行一次协调推进。
    ///
    /// 同一时刻只允许一次在途推进，重复调用会等待同一结果。
    ///
    /// - Returns: 本次协调结果。
    /// - Throws: 协调器已停止或任务取消时抛出 `CancellationError`。
    public func flushOnce() async throws -> V2PushReconcileResult {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let current: (UUID, Task<V2PushReconcileResult, any Error>)
        if let flight { current = flight }
        else { current = (UUID(), Task { [self] in try await flushOwned() }); flight = current }
        let result = await current.1.result
        if flight?.0 == current.0 { flight = nil }
        try Task.checkCancellation()
        return try result.get()
    }

    /// 停止协调器并等待在途任务收敛。
    ///
    /// 停止会取消输入保存、意图推送与循环任务，但不会清除已持久化的意图。
    public func stop() async {
        stopped = true; token = nil
        let running = runTask, sending = flight, saving = inputTask
        running?.1.cancel(); sending?.1.cancel(); saving?.1.cancel()
        _ = await saving?.1.result; _ = await sending?.1.result; _ = await running?.1.result
    }

    private func persistInputs() async throws {
        guard !stopped else { throw CancellationError() }
        while persistedInputID != inputID {
            let current: (UUID, Task<Void, any Error>)
            if let inputTask { current = inputTask }
            else { current = (UUID(), Task { [self] in try await persistLatestInput() }); inputTask = current }
            let result = await current.1.result
            if inputTask?.0 == current.0 { inputTask = nil }
            try Task.checkCancellation()
            try result.get()
            guard !stopped else { throw CancellationError() }
        }
    }

    private func persistLatestInput() async throws {
        while persistedInputID != inputID {
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            let id = inputID, pref = preference, target = desired, reference = token?.id
            let current = try await state()
            try Task.checkCancellation()
            guard id == inputID else { continue }
            let saved = try await store.savePushInput(preferenceEnabled: pref, desiredEnabled: target, tokenReference: reference, expected: current)
            if saved { persistedInputID = id }
        }
    }

    private func flushOwned() async throws -> V2PushReconcileResult {
        try await persistInputs()
        try Task.checkCancellation()
        let current = try await state()
        guard !stopped else { throw CancellationError() }
        guard current.pending, current.pauseReason == nil, !current.waitingForToken, current.nextAttemptAt <= now() else { return .idle }
        do {
            if current.claim == nil {
                let epoch = try await transport.intentEpoch(deviceID: scope.deviceID)
                try Task.checkCancellation()
                return try await store.savePushClaim(.init(requestID: UUID(), expectedEpoch: epoch), expected: current) ? .advanced : .superseded
            }
            if current.epoch == nil, let claim = current.claim {
                let epoch = try await transport.claimIntentSession(deviceID: scope.deviceID, claim: claim)
                try Task.checkCancellation()
                return try await store.completePushClaim(epoch: epoch, expected: current) ? .advanced : .superseded
            }
            guard let version = current.version else { throw V2LocalPushIntentError.invalidState }
            let intent: V2ClientPushIntent
            if current.desiredEnabled {
                guard let token, token.id == current.tokenReference else { return .superseded }
                intent = .enabled(provider: token.provider, environment: token.environment, token: token.value)
            } else { intent = .disabled }
            try await transport.publishIntent(deviceID: scope.deviceID, version: version, intent: intent)
            try Task.checkCancellation()
            return try await store.acknowledgePushIntent(current) ? .advanced : .superseded
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            let pause: V2PushIntentPauseReason?
            switch error {
            case V2ClientPushEndpointError.authorizationDenied: pause = .authorization
            case V2ClientPushEndpointError.staleIntent, V2ClientPushEndpointError.intentVersionRequired: pause = .staleSession
            case V2ClientPushEndpointError.intentConflict, V2ClientPushEndpointError.invalidRegistration, V2ClientPushEndpointError.invalidResponse, is V2PushIntentVersionError: pause = .conflictingIntent
            default: pause = nil
            }
            if let pause {
                let saved = try await store.pausePushIntent(pause, expected: current)
                if pause == .authorization { throw error }
                return saved ? .paused : .superseded
            }
            var delay = min(60, pow(2, Double(min(current.attemptCount, 6))))
            var serviceMinimum: TimeInterval?
            if case V2ClientPushEndpointError.rateLimited(let minimum) = error, minimum.isFinite, minimum > 0 { serviceMinimum = minimum }
            if let minimum = (error as? V2HTTPFailure)?.retryAfter?.timeIntervalSince(now()), minimum.isFinite, minimum > 0 { serviceMinimum = minimum }
            if let serviceMinimum {
                delay = max(delay, serviceMinimum)
                try await store.preserveSupersededPushServiceCooldown(until: now().addingTimeInterval(serviceMinimum), expected: current)
            }
            return try await store.retryPushIntent(at: now().addingTimeInterval(delay), expected: current) ? .retryScheduled : .superseded
        }
    }
}

import Foundation
import IMV2ClientKit
import Observation
import UIKit

/// 推送开关偏好的存储能力。
///
/// 用户偏好会在账号缓存退役后继续保留；远端意图与确认仍以 SQLite 为权威。
/// 只有当前活动存储接受了持久化快照之后，才会在主线程上写入界面状态。
@MainActor
protocol V2PushWakePreferenceStoring: AnyObject {
    /// 查询推送开关偏好。
    ///
    /// - Returns: 当前是否开启推送。
    func isEnabled() -> Bool

    /// 设置推送开关偏好。
    ///
    /// - Parameter enabled: 目标开关状态。
    func setEnabled(_ enabled: Bool)
}

/// 基于 `UserDefaults` 的推送开关偏好存储。
@MainActor
final class V2UserDefaultsPushWakePreferenceStore: V2PushWakePreferenceStoring {
    private let defaults: UserDefaults
    private let key: String
    /// 以偏好存储与键名构造。
    ///
    /// - Parameters:
    ///   - defaults: 偏好存储，默认标准存储。
    ///   - key: 偏好键。
    init(defaults: UserDefaults = .standard, key: String) { self.defaults = defaults; self.key = key }
    func isEnabled() -> Bool { defaults.bool(forKey: key) }
    func setEnabled(_ enabled: Bool) { defaults.set(enabled, forKey: key) }
}

/// 远程通知注册能力。
///
/// UIKit 的注册请求是主线程副作用；其回调由 `V2AppPushDelegate` 持有，
/// 后者只把不透明令牌转交给当前活动的设置存储。
@MainActor
protocol V2RemoteNotificationRegistering: AnyObject {
    /// 向系统发起远程通知注册。
    func registerForRemoteNotifications()
}

/// 推送设备令牌接收能力。
@MainActor
protocol V2PushDeviceTokenReceiving: AnyObject {
    /// 接收系统下发的 APNs 令牌。
    ///
    /// - Parameter token: 不透明设备令牌。
    func receiveAPNSToken(_ token: String) async

    /// 处理远程通知注册失败。
    func remoteNotificationRegistrationFailed() async
}

/// 后台推送处理能力。
///
/// 后台推送只是「请运行已认证同步路径」的有损请求，
/// 它本身既不会包含聊天消息，也不会确认聊天消息。
@MainActor
protocol V2PushWakeHandling: AnyObject {
    /// 处理一次后台推送唤醒。
    ///
    /// - Returns: 后台抓取结果。
    func handlePushWake() async -> UIBackgroundFetchResult
}

/// 推送唤醒设置错误。
enum V2PushWakeSettingsError: Error { case endpointRemovalPending }

@MainActor
@Observable
final class V2PushWakeSettingsStore {
    enum State: Equatable { case loading, disabled, waitingForToken, registering, enabled, retryableFailure }
    private let reconciler: V2PushIntentReconciler
    private let preferences: any V2PushWakePreferenceStoring
    private weak var remoteNotificationRegistrar: (any V2RemoteNotificationRegistering)?
    private let environment: V2ClientPushEndpointEnvironment
    private(set) var state: State = .loading
    private(set) var isEnabled = false
    private(set) var feedback: String?
    private(set) var isSigningOut = false
    private var stopped = false
    private var lifecycle = UUID()
    private var inputID: UUID?
    private var tokenFailed = false
    private var lastSnapshot: V2LocalPushIntent?
    private var runner: Task<Void, Never>?
    private var observer: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?

    init(reconciler: V2PushIntentReconciler, preferences: any V2PushWakePreferenceStoring, remoteNotificationRegistrar: any V2RemoteNotificationRegistering,
         environment: V2ClientPushEndpointEnvironment) {
        self.reconciler = reconciler; self.preferences = preferences; self.remoteNotificationRegistrar = remoteNotificationRegistrar
        self.environment = environment
    }

    isolated deinit { runner?.cancel(); observer?.cancel() }

    func activate() async {
        guard !stopped, observer == nil else { return }
        let id = lifecycle
        do {
            let value = try await reconciler.state()
            guard id == lifecycle, !Task.isCancelled else { return }
            apply(value)
            observer = Task { [weak self, reconciler] in
                do {
                    for try await value in reconciler.updates() {
                        guard let self, self.lifecycle == id, !Task.isCancelled else { return }
                        if self.inputID == nil { self.apply(value) }
                    }
                } catch {
                    guard let self, self.lifecycle == id, !Task.isCancelled else { return }
                    self.fail("暂时无法读取后台同步唤醒设置，请重试。")
                }
            }
            startRunner()
            if value.desiredEnabled { requestFreshToken() }
        } catch { if id == lifecycle { fail("暂时无法读取后台同步唤醒设置，请重试。") } }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !stopped, !isSigningOut, !Task.isCancelled else { return }
        let id = UUID(); inputID = id
        isEnabled = enabled; state = .registering; feedback = nil; tokenFailed = false
        do {
            try await reconciler.setEnabled(enabled)
            let value = try await reconciler.state()
            guard inputID == id, !stopped else { return }
            inputID = nil; apply(value)
            if value.desiredEnabled && value.waitingForToken { requestFreshToken() }
        } catch {
            guard inputID == id, !stopped else { return }
            let saved = try? await reconciler.state()
            guard inputID == id, !stopped else { return }
            inputID = nil
            if let saved { apply(saved) }
            if saved?.preferenceEnabled != enabled { fail("设置尚未保存，请重试。") }
        }
    }

    func receiveAPNSToken(_ token: String) async {
        guard !stopped, !isSigningOut, isEnabled else { return }
        let id = lifecycle
        tokenFailed = false
        do {
            try await reconciler.receiveToken(provider: .apns, environment: environment, value: token)
            let value = try await reconciler.state()
            guard id == lifecycle, inputID == nil else { return }
            apply(value)
        } catch {
            guard id == lifecycle, isEnabled, inputID == nil else { return }
            fail("后台同步唤醒注册尚未完成，请重试。")
        }
    }

    func remoteNotificationRegistrationFailed() async {
        guard !stopped, !isSigningOut, isEnabled else { return }
        let id = lifecycle
        do {
            let current = try await reconciler.state()
            guard id == lifecycle, isEnabled, !isSigningOut, current.waitingForToken, inputID == nil,
                  current.revision >= (lastSnapshot?.revision ?? 0) else { return }
            tokenFailed = true
            fail("此设备暂无法获取后台同步唤醒令牌，请稍后重试。")
        } catch { if id == lifecycle { fail("暂时无法读取后台同步唤醒设置，请重试。") } }
    }

    func retry() async {
        guard !stopped, !isSigningOut, inputID == nil else { return }
        let id = lifecycle
        do {
            try await reconciler.setEnabled(isEnabled)
            let value = try await reconciler.state()
            if value.pauseReason != nil { try await reconciler.restartSession() }
            guard id == lifecycle else { return }
            tokenFailed = false
            startRunner()
            let current = try await reconciler.state()
            guard id == lifecycle else { return }
            apply(current)
            if current.desiredEnabled && current.waitingForToken { requestFreshToken() }
        } catch { if id == lifecycle { fail("暂时无法重试后台同步唤醒设置。") } }
    }

    func deactivateForSignOut() async throws {
        guard !stopped else { throw CancellationError() }
        isSigningOut = true; inputID = nil; isEnabled = false; state = .registering; feedback = nil
        do {
            try await Self.removeEndpoint(using: reconciler)
            state = .disabled
        } catch {
            fail("后台同步唤醒端点尚未移除，请联网后重试退出登录。")
            throw error
        }
    }

    static func removeEndpoint(using reconciler: V2PushIntentReconciler) async throws {
        try await reconciler.prepareSignOut()
        // One epoch read, one claim, one publish, plus a superseded old flight.
        for _ in 0..<4 {
            try Task.checkCancellation()
            let current = try await reconciler.state()
            if !current.desiredEnabled && !current.pending { return }
            let result = try await reconciler.flushOnce()
            if result == .retryScheduled || result == .paused || result == .idle { break }
        }
        let current = try await reconciler.state()
        guard !current.desiredEnabled, !current.pending else { throw V2PushWakeSettingsError.endpointRemovalPending }
    }

    func stop() async {
        if let stopTask { await stopTask.value; return }
        stopped = true; lifecycle = UUID(); inputID = nil
        let run = runner, observe = observer
        runner = nil; observer = nil
        run?.cancel(); observe?.cancel()
        let task = Task { [reconciler] in
            await reconciler.stop()
            await run?.value; await observe?.value
        }
        stopTask = task
        await task.value
    }

    private func startRunner() {
        guard runner == nil, !stopped else { return }
        let id = lifecycle
        runner = Task { [weak self, reconciler] in
            do { try await reconciler.run() }
            catch is CancellationError { }
            catch {
                guard let self, self.lifecycle == id else { return }
                self.fail("后台同步唤醒暂时无法同步，请重试。")
            }
            guard let self, self.lifecycle == id else { return }
            self.runner = nil
        }
    }

    private func apply(_ value: V2LocalPushIntent) {
        if let prior = lastSnapshot {
            guard value.ownerID == prior.ownerID, value.revision >= prior.revision else { return }
            if value.revision == prior.revision {
                guard (value.epoch ?? 0) >= (prior.epoch ?? 0) else { return }
                if value.epoch == prior.epoch {
                    guard value.acknowledgedRevision >= prior.acknowledgedRevision else { return }
                    if value.acknowledgedRevision == prior.acknowledgedRevision {
                        guard value.attemptCount >= prior.attemptCount else { return }
                        if prior.pauseReason != nil && value.pauseReason == nil { return }
                    }
                }
            }
        }
        lastSnapshot = value
        preferences.setEnabled(value.preferenceEnabled)
        if isSigningOut && value.desiredEnabled { return }
        isEnabled = isSigningOut ? false : value.preferenceEnabled
        feedback = nil
        if value.pauseReason != nil { fail("后台同步唤醒设置已暂停，请重试。") }
        else if value.attemptCount > 0 && value.pending { fail("设置尚未同步，将自动重试。") }
        else if value.waitingForToken {
            if tokenFailed { fail("此设备暂无法获取后台同步唤醒令牌，请稍后重试。") }
            else { state = .waitingForToken }
        } else if value.pending { state = .registering }
        else { state = value.desiredEnabled ? .enabled : .disabled }
    }

    private func requestFreshToken() {
        guard isEnabled, !isSigningOut else { return }
        tokenFailed = false
        remoteNotificationRegistrar?.registerForRemoteNotifications()
    }
    private func fail(_ message: String) { state = .retryableFailure; feedback = message }
}

/// 承载 `UIApplication` 回调边界的应用推送委托。
///
/// 它绝不记录 APNs 令牌或注册错误：两者都属于敏感端点材料。
@MainActor
final class V2AppPushDelegate: NSObject, UIApplicationDelegate, V2RemoteNotificationRegistering {
    private(set) var store: V2AppStore!

    override convenience init() { self.init(makeStore: { V2AppStore.launched(remoteNotificationRegistrar: $0) }) }

    init(makeStore: (V2AppPushDelegate) -> V2AppStore) {
        super.init()
        store = makeStore(self)
        tokenReceiver = store
        wakeHandler = store
    }

    weak var tokenReceiver: (any V2PushDeviceTokenReceiving)?
    weak var wakeHandler: (any V2PushWakeHandling)?

    func application(_: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        do {
            V2BackgroundTransferEvents.handle(identifier: identifier,
                root: try V2BackgroundTransferCoordinator.defaultRoot(), completion: completionHandler)
        } catch { completionHandler() }
    }

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { [weak self] in
            await self?.tokenReceiver?.receiveAPNSToken(token)
        }
    }

    func application(_: UIApplication, didFailToRegisterForRemoteNotificationsWithError _: Error) {
        Task { [weak self] in
            await self?.tokenReceiver?.remoteNotificationRegistrationFailed()
        }
    }

    func application(
        _: UIApplication,
        didReceiveRemoteNotification _: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { [weak self] in
            guard let handler = self?.wakeHandler else {
                completionHandler(.noData)
                return
            }
            completionHandler(await handler.handlePushWake())
        }
    }
}

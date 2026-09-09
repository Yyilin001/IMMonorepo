import Foundation
import IMV2ClientKit
import Observation
import UIKit

/// User preference survives account cache retirement. Remote intent and
/// acknowledgement remain authoritative in SQLite. MainActor writes happen
/// only after this active store accepts a durable snapshot.
@MainActor
protocol V2PushWakePreferenceStoring: AnyObject {
    func isEnabled() -> Bool
    func setEnabled(_ enabled: Bool)
}

@MainActor
final class V2UserDefaultsPushWakePreferenceStore: V2PushWakePreferenceStoring {
    private let defaults: UserDefaults
    private let key: String
    init(defaults: UserDefaults = .standard, key: String) { self.defaults = defaults; self.key = key }
    func isEnabled() -> Bool { defaults.bool(forKey: key) }
    func setEnabled(_ enabled: Bool) { defaults.set(enabled, forKey: key) }
}

/// UIKit's registration request is a main-thread side effect. Its callback is
/// owned by `V2AppPushDelegate`, which forwards the opaque token only to the
/// active settings store.
@MainActor
protocol V2RemoteNotificationRegistering: AnyObject {
    func registerForRemoteNotifications()
}

@MainActor
protocol V2PushDeviceTokenReceiving: AnyObject {
    func receiveAPNSToken(_ token: String) async
    func remoteNotificationRegistrationFailed() async
}

/// A background Push is only a lossy request to run the authenticated sync
/// path. It never contains or acknowledges a chat message by itself.
@MainActor
protocol V2PushWakeHandling: AnyObject {
    func handlePushWake() async -> UIBackgroundFetchResult
}

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

/// This adapter contains the UIApplication callback boundary. It never logs
/// the APNs token or registration error; both are sensitive endpoint material.
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

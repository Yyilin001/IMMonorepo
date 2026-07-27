import Foundation
import IMV2ClientKit
import Observation
import UIKit

/// Only the user's desired wake policy is persisted locally. APNs tokens are
/// intentionally ephemeral: they move directly from UIApplicationDelegate to
/// the authenticated account edge and never enter UserDefaults, Keychain,
/// analytics, logs, or a view model.
protocol V2PushWakePreferenceStoring: Sendable {
    func isEnabled() async -> Bool
    func setEnabled(_ enabled: Bool) async
}

actor V2UserDefaultsPushWakePreferenceStore: V2PushWakePreferenceStoring {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func isEnabled() -> Bool { defaults.bool(forKey: key) }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: key)
    }
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

@MainActor
@Observable
final class V2PushWakeSettingsStore {
    enum State: Equatable {
        case loading
        case disabled
        case waitingForToken
        case registering
        case enabled
        case retryableFailure
    }

    private let preferences: any V2PushWakePreferenceStoring
    private let endpointClient: any V2ClientPushEndpointRegistering
    private weak var remoteNotificationRegistrar: (any V2RemoteNotificationRegistering)?
    private let environment: V2ClientPushEndpointEnvironment

    private(set) var state: State = .loading
    private(set) var isEnabled = false
    private(set) var feedback: String?
    private var preferenceGeneration: UInt64 = 0
    private var endpointOperationGeneration: UInt64 = 0

    init(
        preferences: any V2PushWakePreferenceStoring,
        endpointClient: any V2ClientPushEndpointRegistering,
        remoteNotificationRegistrar: any V2RemoteNotificationRegistering,
        environment: V2ClientPushEndpointEnvironment
    ) {
        self.preferences = preferences
        self.endpointClient = endpointClient
        self.remoteNotificationRegistrar = remoteNotificationRegistrar
        self.environment = environment
    }

    /// Replays only the non-secret preference after session restoration. An
    /// enabled setting obtains a fresh system token rather than retaining an
    /// old endpoint token across an app restart.
    func activate() async {
        preferenceGeneration &+= 1
        let generation = preferenceGeneration
        endpointOperationGeneration &+= 1
        let persistedEnabled = await preferences.isEnabled()
        guard generation == preferenceGeneration else { return }
        isEnabled = persistedEnabled
        guard isEnabled else {
            state = .disabled
            feedback = nil
            return
        }
        requestFreshToken()
    }

    func setEnabled(_ desiredValue: Bool) async {
        guard desiredValue != isEnabled || state == .retryableFailure else { return }
        preferenceGeneration &+= 1
        let generation = preferenceGeneration
        endpointOperationGeneration &+= 1
        let endpointGeneration = endpointOperationGeneration
        feedback = nil
        isEnabled = desiredValue
        await preferences.setEnabled(desiredValue)
        guard generation == preferenceGeneration else { return }
        if desiredValue {
            requestFreshToken()
            return
        }

        do {
            try await endpointClient.remove()
            guard generation == preferenceGeneration,
                  endpointGeneration == endpointOperationGeneration,
                  !isEnabled
            else { return }
            state = .disabled
        } catch is CancellationError {
            guard generation == preferenceGeneration,
                  endpointGeneration == endpointOperationGeneration,
                  !isEnabled
            else { return }
            state = .retryableFailure
            feedback = "后台同步唤醒设置尚未同步，请稍后重试。"
        } catch {
            // The disabled preference remains durable. A later activation or
            // explicit retry issues DELETE again, which is safe and device scoped.
            guard generation == preferenceGeneration,
                  endpointGeneration == endpointOperationGeneration,
                  !isEnabled
            else { return }
            state = .retryableFailure
            feedback = "后台同步唤醒设置尚未同步，请稍后重试。"
        }
    }

    func receiveAPNSToken(_ token: String) async {
        guard isEnabled else { return }
        endpointOperationGeneration &+= 1
        let endpointGeneration = endpointOperationGeneration
        state = .registering
        feedback = nil
        do {
            try await endpointClient.register(provider: .apns, environment: environment, token: token)
            guard endpointGeneration == endpointOperationGeneration, isEnabled else { return }
            state = .enabled
        } catch is CancellationError {
            guard endpointGeneration == endpointOperationGeneration, isEnabled else { return }
            state = .retryableFailure
            feedback = "后台同步唤醒注册被取消，请重试。"
        } catch {
            guard endpointGeneration == endpointOperationGeneration, isEnabled else { return }
            state = .retryableFailure
            feedback = "无法注册后台同步唤醒，请稍后重试。"
        }
    }

    func remoteNotificationRegistrationFailed() async {
        guard isEnabled else { return }
        state = .retryableFailure
        feedback = "此设备暂无法获取后台同步唤醒令牌，请稍后重试。"
    }

    /// Signing out must remove the server-side device endpoint while the
    /// current credential is still usable. The user preference itself remains
    /// scoped to that user and is not copied to a later account on this device.
    func deactivateForSignOut() async {
        guard isEnabled || state != .disabled else { return }
        preferenceGeneration &+= 1
        endpointOperationGeneration &+= 1
        isEnabled = false
        state = .disabled
        feedback = nil
        try? await endpointClient.remove()
    }

    private func requestFreshToken() {
        guard isEnabled else { return }
        state = .waitingForToken
        remoteNotificationRegistrar?.registerForRemoteNotifications()
    }
}

/// This adapter contains the UIApplication callback boundary. It never logs
/// the APNs token or registration error; both are sensitive endpoint material.
@MainActor
final class V2AppPushDelegate: NSObject, UIApplicationDelegate, V2RemoteNotificationRegistering {
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

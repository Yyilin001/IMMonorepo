import Foundation
import IMV2ClientKit
import Testing
@testable import IMApp

@MainActor
struct V2PushWakeSettingsTests {
    @Test("disabled preference never asks UIKit for a token")
    func disabledActivationDoesNotRegister() async {
        let preferences = PushWakePreferences(enabled: false)
        let endpoint = PushEndpointClientFake()
        let remote = RemoteNotificationRegistrarFake()
        let store = V2PushWakeSettingsStore(
            preferences: preferences,
            endpointClient: endpoint,
            remoteNotificationRegistrar: remote,
            environment: .development
        )

        await store.activate()

        #expect(store.isEnabled == false)
        #expect(store.state == .disabled)
        #expect(remote.registerRequests == 0)
        #expect(await endpoint.operations().isEmpty)
    }

    @Test("enabling requests a fresh token and registers it only after callback")
    func enabledRegistrationUsesCallbackToken() async {
        let preferences = PushWakePreferences(enabled: false)
        let endpoint = PushEndpointClientFake()
        let remote = RemoteNotificationRegistrarFake()
        let store = V2PushWakeSettingsStore(
            preferences: preferences,
            endpointClient: endpoint,
            remoteNotificationRegistrar: remote,
            environment: .production
        )

        await store.activate()
        await store.setEnabled(true)

        #expect(await preferences.value() == true)
        #expect(store.isEnabled == true)
        #expect(store.state == .waitingForToken)
        #expect(remote.registerRequests == 1)
        #expect(await endpoint.operations().isEmpty)

        await store.receiveAPNSToken("opaque-apns-token")

        #expect(store.state == .enabled)
        #expect(await endpoint.operations() == [.register(provider: .apns, environment: .production, token: "opaque-apns-token")])
    }

    @Test("disabling persists intent and removes only the current device endpoint")
    func disablingRemovesEndpoint() async {
        let preferences = PushWakePreferences(enabled: true)
        let endpoint = PushEndpointClientFake()
        let remote = RemoteNotificationRegistrarFake()
        let store = V2PushWakeSettingsStore(
            preferences: preferences,
            endpointClient: endpoint,
            remoteNotificationRegistrar: remote,
            environment: .development
        )

        await store.activate()
        await store.setEnabled(false)

        #expect(await preferences.value() == false)
        #expect(store.isEnabled == false)
        #expect(store.state == .disabled)
        #expect(await endpoint.operations() == [.remove])
        #expect(await preferences.pendingEndpointRemoval() == false)
    }

    @Test("关闭失败的端点删除会在下次启动时重试")
    func failedDisableRemovalRetriesOnNextActivation() async {
        let preferences = PushWakePreferences(enabled: true)
        let failingEndpoint = PushEndpointClientFake(removeError: PushWakeTestError.failed)
        let remote = RemoteNotificationRegistrarFake()
        let failingStore = V2PushWakeSettingsStore(
            preferences: preferences,
            endpointClient: failingEndpoint,
            remoteNotificationRegistrar: remote,
            environment: .development
        )

        await failingStore.activate()
        await failingStore.setEnabled(false)

        #expect(await preferences.value() == false)
        #expect(await preferences.pendingEndpointRemoval())
        #expect(failingStore.state == .retryableFailure)

        let recoveringEndpoint = PushEndpointClientFake()
        let recoveringStore = V2PushWakeSettingsStore(
            preferences: preferences,
            endpointClient: recoveringEndpoint,
            remoteNotificationRegistrar: remote,
            environment: .development
        )
        await recoveringStore.activate()

        #expect(recoveringStore.isEnabled == false)
        #expect(recoveringStore.state == .disabled)
        #expect(await recoveringEndpoint.operations() == [.remove])
        #expect(await preferences.pendingEndpointRemoval() == false)
    }

    @Test("registration failure preserves enabled intent for a later retry")
    func registrationFailureIsRetryable() async {
        let preferences = PushWakePreferences(enabled: false)
        let endpoint = PushEndpointClientFake(registerError: PushWakeTestError.failed)
        let remote = RemoteNotificationRegistrarFake()
        let store = V2PushWakeSettingsStore(
            preferences: preferences,
            endpointClient: endpoint,
            remoteNotificationRegistrar: remote,
            environment: .development
        )

        await store.setEnabled(true)
        await store.receiveAPNSToken("opaque-apns-token")

        #expect(await preferences.value() == true)
        #expect(store.isEnabled == true)
        #expect(store.state == .retryableFailure)
        #expect(store.feedback == "无法注册后台同步唤醒，请稍后重试。")
    }

    @Test("取消的旧删除不能覆盖新的启用设置")
    func lateRemoveDoesNotOverrideANewerEnable() async {
        let preferences = PushWakePreferences(enabled: true)
        let endpoint = SuspendingPushEndpointClient()
        let remote = RemoteNotificationRegistrarFake()
        let store = V2PushWakeSettingsStore(
            preferences: preferences,
            endpointClient: endpoint,
            remoteNotificationRegistrar: remote,
            environment: .development
        )
        await store.activate()

        let disable = Task { await store.setEnabled(false) }
        await endpoint.waitUntilRemoving()
        await store.setEnabled(true)
        disable.cancel()
        await endpoint.completeRemove()
        await disable.value

        #expect(await preferences.value())
        #expect(store.isEnabled)
        #expect(store.state == .waitingForToken)
        #expect(remote.registerRequests == 2)
    }

    @Test("迟到的 APNs 注册结果不能覆盖后续关闭")
    func lateRegistrationDoesNotOverrideDisable() async {
        let preferences = PushWakePreferences(enabled: false)
        let endpoint = SuspendingPushEndpointClient()
        let remote = RemoteNotificationRegistrarFake()
        let store = V2PushWakeSettingsStore(
            preferences: preferences,
            endpointClient: endpoint,
            remoteNotificationRegistrar: remote,
            environment: .development
        )
        await store.setEnabled(true)

        let registration = Task { await store.receiveAPNSToken("opaque-apns-token") }
        await endpoint.waitUntilRegistering()
        let disable = Task { await store.setEnabled(false) }
        await endpoint.waitUntilRemoving()
        await endpoint.completeRemove()
        await disable.value
        await endpoint.completeRegistration()
        await registration.value

        #expect(await preferences.value() == false)
        #expect(store.isEnabled == false)
        #expect(store.state == .disabled)
        #expect(store.feedback == nil)
    }

    @Test("sign out removes the endpoint without clearing a user scoped preference")
    func signOutRemovesEndpoint() async throws {
        let preferences = PushWakePreferences(enabled: true)
        await preferences.setPendingEndpointRemoval(true)
        let endpoint = PushEndpointClientFake()
        let remote = RemoteNotificationRegistrarFake()
        let store = V2PushWakeSettingsStore(
            preferences: preferences,
            endpointClient: endpoint,
            remoteNotificationRegistrar: remote,
            environment: .development
        )

        await store.activate()
        try await store.deactivateForSignOut()

        #expect(await preferences.value() == true)
        #expect(store.isEnabled == false)
        #expect(store.state == .disabled)
        #expect(await endpoint.operations() == [.remove])
        #expect(await preferences.pendingEndpointRemoval() == false)
    }

    @Test("sign out retains credentials until the endpoint is removed")
    func signOutEndpointRemovalFailureRemainsRetryable() async {
        let preferences = PushWakePreferences(enabled: true)
        let endpoint = PushEndpointClientFake(removeError: PushWakeTestError.failed)
        let remote = RemoteNotificationRegistrarFake()
        let store = V2PushWakeSettingsStore(
            preferences: preferences,
            endpointClient: endpoint,
            remoteNotificationRegistrar: remote,
            environment: .development
        )

        await store.activate()
        await #expect(throws: PushWakeTestError.failed) {
            try await store.deactivateForSignOut()
        }

        #expect(await preferences.value() == true)
        #expect(store.isEnabled == false)
        #expect(store.state == .retryableFailure)
        #expect(store.feedback == "后台同步唤醒端点尚未移除，请联网后重试退出登录。")
        #expect(await endpoint.operations() == [.remove])
    }
}

private actor PushWakePreferences: V2PushWakePreferenceStoring {
    private var enabled: Bool
    private var pendingRemoval = false

    init(enabled: Bool) { self.enabled = enabled }

    func isEnabled() -> Bool { enabled }
    func setEnabled(_ enabled: Bool) { self.enabled = enabled }
    func hasPendingEndpointRemoval() -> Bool { pendingRemoval }
    func setPendingEndpointRemoval(_ pending: Bool) { pendingRemoval = pending }
    func value() -> Bool { enabled }
    func pendingEndpointRemoval() -> Bool { pendingRemoval }
}

@MainActor
private final class RemoteNotificationRegistrarFake: V2RemoteNotificationRegistering {
    private(set) var registerRequests = 0
    func registerForRemoteNotifications() { registerRequests += 1 }
}

private enum PushWakeTestError: Error, Sendable { case failed }

private actor PushEndpointClientFake: V2ClientPushEndpointRegistering {
    enum Operation: Equatable, Sendable {
        case register(provider: V2ClientPushEndpointProvider, environment: V2ClientPushEndpointEnvironment, token: String)
        case remove
    }

    private let registerError: Error?
    private let removeError: Error?
    private var values: [Operation] = []

    init(registerError: Error? = nil, removeError: Error? = nil) {
        self.registerError = registerError
        self.removeError = removeError
    }

    func register(
        provider: V2ClientPushEndpointProvider,
        environment: V2ClientPushEndpointEnvironment,
        token: String
    ) throws {
        values.append(.register(provider: provider, environment: environment, token: token))
        if let registerError { throw registerError }
    }

    func remove() throws {
        values.append(.remove)
        if let removeError { throw removeError }
    }

    func operations() -> [Operation] { values }
}

private actor SuspendingPushEndpointClient: V2ClientPushEndpointRegistering {
    private var registerWaiter: CheckedContinuation<Void, Never>?
    private var removeWaiter: CheckedContinuation<Void, Never>?
    private var registrationCompletion: CheckedContinuation<Void, Never>?
    private var removalCompletion: CheckedContinuation<Void, Never>?

    func register(
        provider _: V2ClientPushEndpointProvider,
        environment _: V2ClientPushEndpointEnvironment,
        token _: String
    ) async throws {
        registerWaiter?.resume()
        registerWaiter = nil
        await withCheckedContinuation { registrationCompletion = $0 }
    }

    func remove() async throws {
        removeWaiter?.resume()
        removeWaiter = nil
        await withCheckedContinuation { removalCompletion = $0 }
    }

    func waitUntilRegistering() async {
        guard registrationCompletion == nil else { return }
        await withCheckedContinuation { registerWaiter = $0 }
    }

    func waitUntilRemoving() async {
        guard removalCompletion == nil else { return }
        await withCheckedContinuation { removeWaiter = $0 }
    }

    func completeRegistration() {
        registrationCompletion?.resume()
        registrationCompletion = nil
    }

    func completeRemove() {
        removalCompletion?.resume()
        removalCompletion = nil
    }
}

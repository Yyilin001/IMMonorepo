import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2PushWakeSettingsTests {
    @Test("disabled activation settles remote state without asking UIKit for a token")
    func disabledActivation() async throws {
        let f = try await Fixture.make(enabled: false)
        await f.settings.activate()
        try await wait { f.settings.state == .disabled }
        #expect(!f.settings.isEnabled && f.registrar.registerRequests == 0)
        #expect(await f.remote.enabled == false)
        await f.close()
    }

    @Test("enabled intent requests an OS token and automatically observes registration completion")
    func enabledCallback() async throws {
        let f = try await Fixture.make(enabled: false)
        await f.settings.activate()
        await f.settings.setEnabled(true)
        #expect(f.settings.isEnabled && f.settings.state == .waitingForToken)
        #expect(f.registrar.registerRequests == 1)
        await f.settings.receiveAPNSToken("opaque-apns-token")
        try await wait { f.settings.state == .enabled }
        #expect(try await f.engine.state().preferenceEnabled)
        #expect(await f.remote.token == "opaque-apns-token")
        await f.settings.remoteNotificationRegistrationFailed()
        #expect(f.settings.state == .enabled)
        await f.close()
    }

    @Test("a disable persists while registration is suspended and later becomes the final remote state")
    func disableDuringRegistration() async throws {
        let f = try await Fixture.make(enabled: true)
        await f.remote.holdPublication()
        await f.settings.activate()
        await f.settings.receiveAPNSToken("old-token")
        try await wait { await f.remote.waiting }
        await f.settings.setEnabled(false)
        #expect(!f.settings.isEnabled)
        #expect(try await f.engine.state().desiredEnabled == false)
        await f.remote.release()
        try await wait { f.settings.state == .disabled }
        #expect(await f.remote.enabled == false)
        let versions = await f.remote.versions
        #expect(versions.count == 2 && versions[1].revision > versions[0].revision)
        await f.close()
    }

    @Test("a failed disable survives owner restart and stale legacy preference cannot enable it")
    func failedDisableRestarts() async throws {
        let f = try await Fixture.make(enabled: true)
        await f.remote.failNext()
        await f.settings.activate()
        await f.settings.setEnabled(false)
        try await wait { f.settings.state == .retryableFailure }
        await f.settings.stop()
        let engine = try await V2PushIntentReconciler.activate(store: f.local, transport: f.remote, scope: f.scope, initialPreference: true)
        let next = V2PushWakeSettingsStore(reconciler: engine, preferences: f.preference, remoteNotificationRegistrar: f.registrar, environment: .development)
        await next.activate()
        try await wait { next.state == .disabled }
        #expect(!next.isEnabled && !f.preference.isEnabled())
        #expect(try await engine.state().preferenceEnabled == false)
        await next.stop(); try await f.local.close()
    }

    @Test("registration failure keeps enabled intent and the UI observes automatic retry")
    func retryObserved() async throws {
        let f = try await Fixture.make(enabled: true)
        await f.remote.failNext()
        await f.settings.activate()
        await f.settings.receiveAPNSToken("token")
        try await wait { f.settings.state == .retryableFailure }
        #expect(f.settings.isEnabled && f.settings.feedback != nil)
        try await wait { f.settings.state == .enabled }
        #expect(f.settings.feedback == nil)
        await f.close()
    }

    @Test("system token failure exposes retry and asks UIKit for a fresh token")
    func tokenRetry() async throws {
        let f = try await Fixture.make(enabled: true)
        await f.settings.activate()
        await f.settings.remoteNotificationRegistrationFailed()
        #expect(f.settings.state == .retryableFailure)
        await f.settings.retry()
        #expect(f.registrar.registerRequests == 2)
        #expect(f.settings.state == .waitingForToken)
        await f.close()
    }

    @Test("sign out confirms disabled intent while preserving user preference and ignores late token")
    func signOut() async throws {
        let f = try await Fixture.make(enabled: true)
        await f.settings.activate()
        try await f.settings.deactivateForSignOut()
        await f.settings.receiveAPNSToken("late-token")
        let value = try await f.engine.state()
        #expect(value.preferenceEnabled && !value.desiredEnabled && !value.pending)
        #expect(f.preference.isEnabled())
        #expect(f.settings.state == .disabled && !f.settings.isEnabled && f.settings.isSigningOut)
        #expect(await f.remote.enabled == false)
        await f.close()
    }

    @Test("sign out failure remains pending instead of reporting removal success")
    func signOutFailure() async throws {
        let f = try await Fixture.make(enabled: true)
        await f.remote.failNext()
        await f.settings.activate()
        await #expect(throws: V2PushWakeSettingsError.endpointRemovalPending) { try await f.settings.deactivateForSignOut() }
        let value = try await f.engine.state()
        #expect(value.preferenceEnabled && !value.desiredEnabled && value.pending)
        #expect(f.settings.state == .retryableFailure && !f.settings.isEnabled)
        await f.close()
    }

    @Test("stopping the store drains old HTTP work and rejects late callbacks")
    func stopLateResult() async throws {
        let f = try await Fixture.make(enabled: true)
        await f.remote.holdPublication()
        await f.settings.activate()
        await f.settings.receiveAPNSToken("old-token")
        try await wait { await f.remote.waiting }
        let before = f.settings.state
        let stopping = Task { await f.settings.stop() }
        try await wait { await f.remote.cancelled }
        var secondStarted = false
        var secondCompleted = false
        let secondStop = Task { secondStarted = true; await f.settings.stop(); secondCompleted = true }
        try await wait { secondStarted }
        #expect(!secondCompleted)
        await f.remote.release()
        await stopping.value
        await secondStop.value
        #expect(secondCompleted)
        await f.settings.receiveAPNSToken("later-token")
        #expect(f.settings.state == before)
        #expect(try await f.engine.state().pending)
        try await f.local.close()
    }

    private func wait(_ condition: @escaping @MainActor () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("bounded state wait expired")
        throw V2PushWakeSettingsError.endpointRemovalPending
    }

    @MainActor
    private struct Fixture {
        let local: GRDBV2LocalSyncStore
        let scope: V2PushIntentScope
        let engine: V2PushIntentReconciler
        let settings: V2PushWakeSettingsStore
        let remote: PushSettingsRemote
        let registrar: RemoteNotificationRegistrarFake
        let preference: PushSettingsPreference
        static func make(enabled: Bool) async throws -> Self {
            let binding = V2LocalInstallationBinding(value: UUID())
            let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
            let bootstrapper = V2LocalStoreBootstrapper(bindingStore: PushSettingsBinding(binding: binding))
            let local = try await bootstrapper.open(databaseURL: FileManager.default.temporaryDirectory.appending(path: "push-settings-\(UUID()).sqlite"), userID: user)
            let scope = try V2PushIntentScope(userID: user, deviceID: device, installation: binding)
            let remote = PushSettingsRemote(), registrar = RemoteNotificationRegistrarFake()
            let engine = try await V2PushIntentReconciler.activate(store: local, transport: remote, scope: scope, initialPreference: enabled)
            let preference = PushSettingsPreference(enabled: enabled)
            let settings = V2PushWakeSettingsStore(reconciler: engine, preferences: preference, remoteNotificationRegistrar: registrar, environment: .production)
            return .init(local: local, scope: scope, engine: engine, settings: settings, remote: remote, registrar: registrar, preference: preference)
        }
        func close() async { await settings.stop(); try? await local.close() }
    }
}

private actor PushSettingsBinding: V2InstallationBindingStore {
    let binding: V2LocalInstallationBinding
    init(binding: V2LocalInstallationBinding) { self.binding = binding }
    func load() -> V2LocalInstallationBinding? { binding }
    func save(_: V2LocalInstallationBinding) {}
    func delete() {}
}

@MainActor
private final class RemoteNotificationRegistrarFake: V2RemoteNotificationRegistering {
    var registerRequests = 0
    func registerForRemoteNotifications() { registerRequests += 1 }
}

private actor PushSettingsRemote: V2ClientPushIntentPublishing {
    var versions: [V2PushIntentVersion] = []
    var enabled = false
    var token: String?
    var cancelled = false
    private var hold = false
    private var failure = false
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func holdPublication() { hold = true }
    func failNext() { failure = true }
    func release() { continuation?.resume(); continuation = nil }
    func markCancelled() { cancelled = true }
    func intentEpoch(deviceID: DeviceID) -> UInt64 { 0 }
    func claimIntentSession(deviceID: DeviceID, claim: V2PushIntentSessionClaim) -> UInt64 { claim.expectedEpoch + 1 }
    func publishIntent(deviceID: DeviceID, version: V2PushIntentVersion, intent: V2ClientPushIntent) async throws {
        if hold {
            hold = false
            await withTaskCancellationHandler { await withCheckedContinuation { continuation = $0 } } onCancel: {
                Task { await self.markCancelled() }
            }
        }
        if failure { failure = false; throw V2ClientPushEndpointError.networkFailure }
        versions.append(version)
        switch intent {
        case .disabled: enabled = false; token = nil
        case .enabled(_, _, let token): enabled = true; self.token = token
        }
    }
}

@MainActor
private final class PushSettingsPreference: V2PushWakePreferenceStoring {
    private var enabled: Bool
    init(enabled: Bool) { self.enabled = enabled }
    func isEnabled() -> Bool { enabled }
    func setEnabled(_ enabled: Bool) { self.enabled = enabled }
}

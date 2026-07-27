import Testing
@testable import IMApp

@MainActor
struct V2AppStoreTests {
    @Test("UI test startup mode bypasses device state and remains signed out")
    func uiTestingStartupModeStaysSignedOut() async {
        let store = V2AppStore(startupMode: .uiTestingSignedOut)

        await store.restore()

        #expect(store.route == .signedOut)
        #expect(store.authenticationMessage == nil)
    }

    @Test("本地账号 UI 集成模式保留配置但不恢复历史登录态")
    func uiTestingLiveLocalAccountModeDoesNotRestorePersistedSession() {
        #expect(V2AppStore.StartupMode.production.restoresPersistedSession)
        #expect(!V2AppStore.StartupMode.uiTestingSignedOut.restoresPersistedSession)
        #expect(!V2AppStore.StartupMode.uiTestingLiveLocalAccount.restoresPersistedSession)
        #expect(!V2AppStore.StartupMode.uiTestingLiveLocalAccountCleanup.restoresPersistedSession)
        #expect(V2AppStore.StartupMode.uiTestingLiveLocalAccount.needsRuntimeConfiguration)
        #expect(V2AppStore.StartupMode.uiTestingLiveLocalAccountCleanup.needsRuntimeConfiguration)
        #expect(!V2AppStore.StartupMode.uiTestingSignedOut.needsRuntimeConfiguration)
        #expect(V2AppStore.StartupMode.uiTestingLiveLocalAccount.usesLiveLocalAccountE2ETestScope)
        #expect(V2AppStore.StartupMode.uiTestingLiveLocalAccountCleanup.usesLiveLocalAccountE2ETestScope)
        #expect(!V2AppStore.StartupMode.production.usesLiveLocalAccountE2ETestScope)
    }
}

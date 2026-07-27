import Testing
@testable import IMApp

@MainActor
struct V2AppStoreTests {
    @Test("实时启动任务结束后允许新的前台尝试")
    func completedRealtimeAttemptReleasesTheGate() {
        var gate = V2RealtimeAttemptGate()

        let first = gate.begin(ifApplicationActive: true)
        #expect(first != nil)
        guard let first else { return }
        #expect(gate.hasInFlightAttempt)
        let concurrentAttempt = gate.begin(ifApplicationActive: true)
        #expect(concurrentAttempt == nil)

        let released = gate.finish(generation: first)
        #expect(released)
        #expect(!gate.hasInFlightAttempt)
        let second = gate.begin(ifApplicationActive: true)
        #expect(second != nil)
        guard let second else { return }
        #expect(second > first)
    }

    @Test("已取消实时启动的迟到完成不能释放新任务")
    func staleRealtimeAttemptCompletionCannotReleaseNewAttempt() {
        var gate = V2RealtimeAttemptGate()

        let first = gate.begin(ifApplicationActive: true)
        #expect(first != nil)
        guard let first else { return }
        gate.cancel()
        let second = gate.begin(ifApplicationActive: true)
        #expect(second != nil)
        guard let second else { return }

        let staleCompletionWasIgnored = !gate.finish(generation: first)
        #expect(staleCompletionWasIgnored)
        #expect(gate.hasInFlightAttempt)
        #expect(gate.matchesCurrentGeneration(second))
        let currentCompletionReleasedGate = gate.finish(generation: second)
        #expect(currentCompletionReleasedGate)
    }

    @Test("旧登录尝试不能覆盖新的认证流程")
    func staleAuthenticationAttemptCannotOwnTheCurrentRoute() {
        var gate = V2AuthenticationAttemptGate()

        let first = gate.begin()
        let second = gate.begin()

        #expect(second > first)
        #expect(!gate.matchesCurrentGeneration(first))
        #expect(gate.matchesCurrentGeneration(second))
    }

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

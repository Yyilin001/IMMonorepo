import Foundation

extension V2AppStore {
    /// 由应用委托在任何场景或回调之前构造应用存储。
    ///
    /// 调试期的启动隔离必须对界面启动与无界面启动保持一致，
    /// 因此启动模式与端到端测试作用域都由同一组启动参数推导。
    ///
    /// - Parameter remoteNotificationRegistrar: 远程通知注册实现。
    /// - Returns: 已按启动参数配置好的应用存储。
    static func launched(remoteNotificationRegistrar: any V2RemoteNotificationRegistering) -> V2AppStore {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let startupMode: StartupMode
        if arguments.contains("-v2-mock-preview") {
            startupMode = .uiTestingSignedOut
        } else if arguments.contains("-v2-ui-testing-live-local-account") {
            startupMode = arguments.contains("-v2-ui-testing-cleanup-local-account")
                ? .uiTestingLiveLocalAccountCleanup
                : arguments.contains("-v2-ui-testing-restore-local-account")
                    ? .uiTestingLiveLocalAccountRestore : .uiTestingLiveLocalAccount
        } else if arguments.contains("-v2-ui-testing-signed-out") {
            startupMode = .uiTestingSignedOut
        } else { startupMode = .production }
        let scope: V2LiveLocalAccountE2ETestScope?
        if startupMode.usesLiveLocalAccountE2ETestScope,
           let index = arguments.firstIndex(of: "-v2-ui-testing-e2e-scope"), index + 1 < arguments.count {
            scope = .init(rawValue: arguments[index + 1])
        } else { scope = nil }
        return .init(startupMode: startupMode, liveLocalAccountE2ETestScope: scope,
                     debugForcesUnavailableRealtimeForLiveLocalAccountE2E: startupMode.usesLiveLocalAccountE2ETestScope && arguments.contains("-v2-ui-testing-unavailable-realtime"),
                     remoteNotificationRegistrar: remoteNotificationRegistrar)
        #else
        return .init(remoteNotificationRegistrar: remoteNotificationRegistrar)
        #endif
    }
}

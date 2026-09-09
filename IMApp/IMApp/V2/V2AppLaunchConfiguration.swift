import Foundation

extension V2AppStore {
    /// Constructed by the application delegate before any scene or callback.
    /// Debug launch isolation must be identical for UI and headless starts.
    static func launched(remoteNotificationRegistrar: any V2RemoteNotificationRegistering) -> V2AppStore {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let startupMode: StartupMode
        if arguments.contains("-v2-ui-testing-live-local-account") {
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

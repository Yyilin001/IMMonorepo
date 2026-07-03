//
//  IMAppApp.swift
//  IMApp
//
//  Created by yy on 2026/3/25.
//

import SwiftUI

@main
struct IMAppApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(IMAppDelegate.self) private var appDelegate
    @State private var authManager: AuthManager

    init() {
        IMPerformanceSignpost.event("AppInitStarted")
        let configuration = AppNetworkConfiguration.publicGateway
        _authManager = State(
            initialValue: AuthManager(
                network: configuration.makeNetworkEnvironment(),
                imConnectionConfiguration: configuration.makeIMTCPConfiguration(),
                timelineCatchUpConfiguration: configuration.timelineCatchUpConfiguration
            )
        )
        IMPerformanceSignpost.event("AppInitFinished")
    }

    var body: some Scene {
        WindowGroup {
            ContentView(authManager: authManager)
                .onAppear {
                    IMPerformanceSignpost.event("RootContentAppeared")
                }
                .onChange(of: scenePhase) { _, newPhase in
                    Task {
                        let signpost = IMPerformanceSignpost.begin("AppScenePhaseTransition")
                        defer {
                            IMPerformanceSignpost.end("AppScenePhaseTransition", signpost)
                        }
                        switch newPhase {
                        case .active:
                            await authManager.appDidBecomeActive()
                        case .background:
                            await authManager.appDidEnterBackground()
                        default:
                            break
                        }
                    }
                }
        }
    }
}

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
        let configuration = AppNetworkConfiguration.publicGateway
        _authManager = State(
            initialValue: AuthManager(
                network: configuration.makeNetworkEnvironment(),
                imConnectionConfiguration: configuration.makeIMTCPConfiguration(),
                timelineCatchUpConfiguration: configuration.timelineCatchUpConfiguration
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(authManager: authManager)
                .onChange(of: scenePhase) { _, newPhase in
                    Task {
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

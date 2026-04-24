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
    @StateObject private var authManager: AuthManager

    init() {
        let configuration = AppNetworkConfiguration.local
        _authManager = StateObject(
            wrappedValue: AuthManager(
                network: configuration.makeNetworkEnvironment(),
                imConnectionConfiguration: configuration.makeIMTCPConfiguration()
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authManager)
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

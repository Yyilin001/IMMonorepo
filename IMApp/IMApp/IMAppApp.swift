//
//  IMAppApp.swift
//  IMApp
//
//  Created by yy on 2026/3/25.
//

import SwiftUI

@main
struct IMAppApp: App {
    @UIApplicationDelegateAdaptor(V2AppPushDelegate.self) private var appPushDelegate

    var body: some Scene {
        WindowGroup {
            V2RootView(appPushDelegate: appPushDelegate)
        }
    }
}

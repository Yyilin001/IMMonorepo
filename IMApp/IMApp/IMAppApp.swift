//
//  IMAppApp.swift
//  IMApp
//
//  Created by yy on 2026/3/25.
//

import SwiftUI

/// 应用入口。
///
/// 它把推送代理接入 SwiftUI 生命周期，并把根视图的创建交给 `V2RootView`。
@main
struct IMAppApp: App {
    @UIApplicationDelegateAdaptor(V2AppPushDelegate.self) private var appPushDelegate

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-v2-mock-preview") {
                V2MockPreview().tint(V2VisualStyle.accent)
            } else {
                V2RootView(appPushDelegate: appPushDelegate).tint(V2VisualStyle.accent)
            }
            #else
            V2RootView(appPushDelegate: appPushDelegate).tint(V2VisualStyle.accent)
            #endif
        }
    }
}

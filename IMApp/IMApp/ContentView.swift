//
//  ContentView.swift
//  IMApp
//
//  Created by yy on 2026/3/25.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var authManager: AuthManager

    var body: some View {
        Group {
            switch authManager.phase {
            case .launching:
                ProgressView("正在恢复登录状态…")
                    .progressViewStyle(.circular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .signedOut(let message):
                LoginView(message: message)

            case .signedIn(let user):
                SignedInTabView(user: user)
            }
        }
        .background(Color(.systemGroupedBackground))
    }
}

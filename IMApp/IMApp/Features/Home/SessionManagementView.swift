import SwiftUI
import IMClientKit

struct SessionManagementView: View {
    @EnvironmentObject private var authManager: AuthManager

    var body: some View {
        List {
            Section("活跃设备") {
                if authManager.isLoadingSessions && authManager.sessions.isEmpty {
                    ProgressView("正在加载设备列表…")
                } else {
                    ForEach(authManager.sessions) { session in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(session.deviceName ?? "未知设备")
                                    .font(.headline)
                                if session.isCurrent {
                                    Text("当前设备")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.accentColor.opacity(0.14))
                                        .clipShape(Capsule())
                                }
                            }

                            Text(session.platform ?? "平台信息不可用")
                                .foregroundStyle(.secondary)

                            if let appVersion = session.appVersion {
                                Text("App 版本 \(appVersion)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            if let lastSeenAt = session.lastSeenAt {
                                Text("最近活跃于 \(lastSeenAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            Text("刷新令牌过期于 \(session.refreshExpiresAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .swipeActions(allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task {
                                    await authManager.signOut(sessionID: session.id, isCurrent: session.isCurrent)
                                }
                            } label: {
                                Text(session.isCurrent ? "退出当前" : "退出此设备")
                            }
                        }
                    }
                }
            }

            if let message = authManager.sessionsMessage, !message.isEmpty {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("操作") {
                Button("刷新设备列表") {
                    Task {
                        await authManager.loadSessions()
                    }
                }

                Button("退出当前设备", role: .destructive) {
                    Task {
                        await authManager.signOutCurrentDevice()
                    }
                }

                Button("退出所有设备", role: .destructive) {
                    Task {
                        await authManager.logoutAllSessions()
                    }
                }
            }
        }
        .navigationTitle("设备管理")
        .task {
            await authManager.loadSessions()
        }
        .refreshable {
            await authManager.loadSessions()
        }
    }
}

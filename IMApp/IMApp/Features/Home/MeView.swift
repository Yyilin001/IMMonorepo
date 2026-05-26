import SwiftUI
import IMClientKit

struct MeView: View {
    let sessionStore: AppSessionStore
    let user: AuthUser
    let imConnectionStatus: AuthManager.IMConnectionStatus
    let reloadProfile: () async -> Void
    let updateProfile: (String?, UserAvatarPreset?) async -> Bool
    let logout: () async -> Void
    let openProfile: () -> Void
    let openSessions: () -> Void
    let openPrivacy: () -> Void
    let openFileTransfer: () -> Void
    let openNetworkStatus: () -> Void
    let openDiagnostics: () -> Void

    var body: some View {
        List {
            Section {
                HStack(spacing: AppSpacing.large) {
                    UserAvatarView(
                        displayName: activeUser.preferredDisplayName,
                        email: activeUser.email,
                        avatarPreset: activeUser.avatarPreset,
                        size: 64
                    )

                    VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                        Text(activeUser.preferredDisplayName)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)

                        Text(activeUser.email)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .padding(.vertical, AppSpacing.small)
                .accessibilityIdentifier("me.profileSummary")

                Button {
                    openProfile()
                } label: {
                    AppListActionRow(
                        title: "编辑资料",
                        subtitle: sessionStore.isUpdatingProfile ? "正在保存资料" : nil,
                        systemImage: "person.crop.circle",
                        tint: .blue
                    )
                }
                .buttonStyle(.plain)
                .disabled(sessionStore.isUpdatingProfile)
                .accessibilityIdentifier("me.editProfileButton")

                if let message = sessionStore.profileMessage, !message.isEmpty {
                    AppStatusBanner(message: message, tone: .info)
                        .accessibilityIdentifier("me.profileStatus")
                }
            }

            Section {
                Button {
                    openSessions()
                } label: {
                    AppListActionRow(
                        title: "设备管理",
                        subtitle: "查看和管理已登录设备",
                        systemImage: "iphone.gen2",
                        tint: .indigo
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("me.sessionsButton")

                Button(role: .destructive) {
                    Task {
                        await logout()
                    }
                } label: {
                    AppListActionRow(
                        title: "退出登录",
                        subtitle: nil,
                        systemImage: "rectangle.portrait.and.arrow.right",
                        tint: .red,
                        showsChevron: false
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("me.logoutButton")
            } header: {
                AppSectionHeader(title: "账号与设备")
            }

            Section {
                Button {
                    openPrivacy()
                } label: {
                    AppListActionRow(
                        title: "隐私与安全",
                        subtitle: "黑名单和联系人关系管理",
                        systemImage: "lock.shield",
                        tint: .green
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("me.privacyButton")
            } header: {
                AppSectionHeader(title: "隐私与安全")
            }

            Section {
                Button {
                    openNetworkStatus()
                } label: {
                    AppListActionRow(
                        title: "网络状态",
                        subtitle: "服务器与 IM 长连接",
                        systemImage: "network",
                        tint: statusColor
                    ) {
                        statusSummary
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("me.networkStatusButton")

                Button {
                    openFileTransfer()
                } label: {
                    AppListActionRow(
                        title: "文件传输",
                        subtitle: "上传和下载服务端文件",
                        systemImage: "arrow.up.arrow.down.circle",
                        tint: .orange
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("me.fileTransferButton")

            #if DEBUG
                Button {
                    openDiagnostics()
                } label: {
                    AppListActionRow(
                        title: "开发诊断",
                        subtitle: "本地联调与探测工具",
                        systemImage: "waveform.path.ecg.rectangle",
                        tint: .purple
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("me.diagnosticsButton")
            #endif
            } header: {
                AppSectionHeader(title: "高级工具")
            }
        }
        .navigationTitle("我的")
        .background(AppSurface.groupedBackground)
        .refreshable {
            await reloadProfile()
        }
    }

    private var activeUser: AuthUser {
        sessionStore.currentUser ?? user
    }

    private var statusSummary: some View {
        HStack(spacing: 7) {
            Image(systemName: statusIcon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(statusColor)
                .frame(width: 22, height: 22)
                .background(statusColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(statusText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }

    private var statusText: String {
        switch (sessionStore.serverStatus, imConnectionStatus) {
        case (.online, .connected):
            return "在线"
        case (.offline, _):
            return "离线"
        case (_, .failed):
            return "异常"
        case (_, .connecting):
            return "连接中"
        case (.unknown, _), (_, .disconnected):
            return "待确认"
        }
    }

    private var statusColor: Color {
        switch statusText {
        case "在线":
            return .green
        case "连接中":
            return .blue
        case "离线", "异常":
            return .orange
        default:
            return .secondary
        }
    }

    private var statusIcon: String {
        switch statusText {
        case "在线":
            return "checkmark.circle.fill"
        case "连接中":
            return "arrow.trianglehead.2.clockwise"
        case "离线":
            return "wifi.slash"
        case "异常":
            return "exclamationmark.triangle.fill"
        default:
            return "questionmark.circle"
        }
    }
}

struct PrivacySecurityView: View {
    let openBlockedUsers: () -> Void

    var body: some View {
        List {
            Section {
                Button {
                    openBlockedUsers()
                } label: {
                    AppListActionRow(
                        title: "黑名单",
                        subtitle: "管理已屏蔽用户",
                        systemImage: "hand.raised.fill",
                        tint: .red
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("me.blockedUsersButton")
            }
        }
        .navigationTitle("隐私与安全")
    }
}

struct NetworkStatusView: View {
    let sessionStore: AppSessionStore
    let imConnectionStatus: AuthManager.IMConnectionStatus
    let reconnectIMConnection: () async -> Void

    var body: some View {
        List {
            Section("服务器") {
                statusRow(
                    title: serverStatusTitle,
                    message: serverStatusMessage,
                    systemImage: serverStatusIcon,
                    tint: serverStatusColor
                )
            }

            Section("IM 长连接") {
                statusRow(
                    title: imConnectionStatusTitle,
                    message: imConnectionStatusMessage,
                    systemImage: imConnectionStatusIcon,
                    tint: imConnectionStatusColor
                )

                if imConnectionStatus != .connected {
                    Button {
                        Task {
                            await reconnectIMConnection()
                        }
                    } label: {
                        Label("重新连接", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .navigationTitle("网络状态")
    }

    private func statusRow(title: String, message: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var serverStatusTitle: String {
        switch sessionStore.serverStatus {
        case .unknown:
            return "尚未确认服务器状态"
        case .online:
            return "服务器连接正常"
        case .offline:
            return "服务器暂时不可用"
        }
    }

    private var serverStatusMessage: String {
        switch sessionStore.serverStatus {
        case .unknown:
            return "客户端会继续保留当前登录状态。"
        case .online:
            return "当前请求可以正常访问后端接口。"
        case .offline(let message):
            return "\(message) 已保留当前登录状态。"
        }
    }

    private var serverStatusIcon: String {
        switch sessionStore.serverStatus {
        case .unknown:
            return "questionmark.circle"
        case .online:
            return "checkmark.circle.fill"
        case .offline:
            return "wifi.slash"
        }
    }

    private var serverStatusColor: Color {
        switch sessionStore.serverStatus {
        case .unknown:
            return .secondary
        case .online:
            return .green
        case .offline:
            return .orange
        }
    }

    private var imConnectionStatusTitle: String {
        switch imConnectionStatus {
        case .disconnected:
            return "IM 连接未建立"
        case .connecting:
            return "IM 正在连接"
        case .connected:
            return "IM 已在线"
        case .failed:
            return "IM 连接失败"
        }
    }

    private var imConnectionStatusMessage: String {
        switch imConnectionStatus {
        case .disconnected:
            return "当前仅保留 HTTP 登录态，还没有 TCP 长连接。"
        case .connecting:
            return "正在使用当前 access token 建立 TCP 握手。"
        case .connected:
            return "TCP 握手已完成，可以接收实时消息和服务端事件。"
        case .failed(let message):
            return message
        }
    }

    private var imConnectionStatusIcon: String {
        switch imConnectionStatus {
        case .disconnected:
            return "bolt.slash"
        case .connecting:
            return "arrow.trianglehead.2.clockwise"
        case .connected:
            return "bolt.horizontal.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var imConnectionStatusColor: Color {
        switch imConnectionStatus {
        case .disconnected:
            return .secondary
        case .connecting:
            return .blue
        case .connected:
            return .green
        case .failed:
            return .orange
        }
    }
}

struct DiagnosticsView: View {
    let probeManager: ProbeManager

    var body: some View {
        List {
            Section("随机请求测试") {
                Button(probeManager.isTrafficTestRunning ? "停止测试" : "开始测试") {
                    probeManager.toggleTrafficTest()
                }
                .tint(probeManager.isTrafficTestRunning ? .orange : .blue)

                statusRow(title: "当前状态", value: probeManager.trafficTestStatus)
                statusRow(title: "成功次数", value: "\(probeManager.trafficTestSuccessCount)")
                statusRow(title: "限流次数", value: "\(probeManager.trafficTestRateLimitedCount)")
                statusRow(title: "失败次数", value: "\(probeManager.trafficTestFailureCount)")
                statusRow(title: "最近请求", value: lastRequestText)
            }

            Section("并发请求测试") {
                Button(probeManager.isConcurrentTestRunning ? "并发中" : "并发测试") {
                    probeManager.runConcurrentTest()
                }
                .disabled(probeManager.isConcurrentTestRunning)

                statusRow(title: "当前状态", value: probeManager.concurrentTestStatus)
                statusRow(title: "成功次数", value: "\(probeManager.concurrentTestSuccessCount)")
                statusRow(title: "限流次数", value: "\(probeManager.concurrentTestRateLimitedCount)")
                statusRow(title: "失败次数", value: "\(probeManager.concurrentTestFailureCount)")
                statusRow(title: "最近测试", value: lastConcurrentTestText)
            }

            Section("持续压测") {
                Button(probeManager.isLoadTestRunning ? "停止压测" : "持续压测") {
                    probeManager.toggleLoadTest()
                }
                .tint(probeManager.isLoadTestRunning ? .red : .pink)

                statusRow(title: "当前状态", value: probeManager.loadTestStatus)
                statusRow(title: "成功次数", value: "\(probeManager.loadTestSuccessCount)")
                statusRow(title: "限流次数", value: "\(probeManager.loadTestRateLimitedCount)")
                statusRow(title: "失败次数", value: "\(probeManager.loadTestFailureCount)")
                statusRow(title: "最近请求", value: lastLoadTestText)
            }
        }
        .navigationTitle("开发诊断")
    }

    private var lastRequestText: String {
        guard let lastRequestAt = probeManager.trafficTestLastRequestAt else {
            return "暂无"
        }

        return lastRequestAt.formatted(date: .omitted, time: .standard)
    }

    private var lastConcurrentTestText: String {
        guard let lastRunAt = probeManager.concurrentTestLastRunAt else {
            return "暂无"
        }

        return lastRunAt.formatted(date: .omitted, time: .standard)
    }

    private var lastLoadTestText: String {
        guard let lastRequestAt = probeManager.loadTestLastRequestAt else {
            return "暂无"
        }

        return lastRequestAt.formatted(date: .omitted, time: .standard)
    }

    private func statusRow(title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

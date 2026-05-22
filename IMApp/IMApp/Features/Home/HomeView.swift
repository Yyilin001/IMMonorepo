import SwiftUI
import IMClientKit

struct HomeView: View {
    let sessionStore: AppSessionStore
    let probeManager: ProbeManager

    let user: AuthUser
    let imConnectionStatus: AuthManager.IMConnectionStatus
    let reloadProfile: () async -> Void
    let updateProfile: (String?, UserAvatarPreset?) async -> Bool
    let reconnectIMConnection: () async -> Void
    let logout: () async -> Void

    @State private var isPresentingEditProfile = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("已登录")
                    .font(.largeTitle.bold())

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        UserAvatarView(
                            displayName: activeUser.preferredDisplayName,
                            email: activeUser.email,
                            avatarPreset: activeUser.avatarPreset,
                            size: 60
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(activeUser.preferredDisplayName)
                                .font(.title3.weight(.semibold))

                            Text(activeUser.email)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }

                    if let message = sessionStore.profileMessage, !message.isEmpty {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }

                    HStack(spacing: 12) {
                        Button("编辑资料") {
                            isPresentingEditProfile = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(sessionStore.isUpdatingProfile)

                        Button("刷新资料") {
                            Task {
                                await reloadProfile()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(sessionStore.isUpdatingProfile)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))

                HStack(spacing: 10) {
                    Image(systemName: serverStatusIcon)
                        .foregroundStyle(serverStatusColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(serverStatusTitle)
                            .font(.headline)
                        Text(serverStatusMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: imConnectionStatusIcon)
                            .foregroundStyle(imConnectionStatusColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(imConnectionStatusTitle)
                                .font(.headline)
                            Text(imConnectionStatusMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if imConnectionStatus != .connected {
                        Button("重连 IM") {
                            Task {
                                await reconnectIMConnection()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))

                VStack(alignment: .leading, spacing: 12) {
                    Label(activeUser.email, systemImage: "person.crop.circle.fill")
                    Label("受保护接口：GET /api/me", systemImage: "lock.shield")
                    Label("访问令牌会自动续期", systemImage: "arrow.trianglehead.clockwise")
                    Label("登录后会自动建立 TCP IM 连接", systemImage: "bolt.horizontal.circle")
                }
                .font(.body)
                .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button(probeManager.isTrafficTestRunning ? "停止测试" : "开始测试") {
                        probeManager.toggleTrafficTest()
                    }
                    .buttonStyle(.bordered)
                    .tint(probeManager.isTrafficTestRunning ? .orange : .blue)

                    Button(probeManager.isConcurrentTestRunning ? "并发中" : "并发测试") {
                        probeManager.runConcurrentTest()
                    }
                    .buttonStyle(.bordered)
                    .disabled(probeManager.isConcurrentTestRunning)

                    Button(probeManager.isLoadTestRunning ? "停止压测" : "持续压测") {
                        probeManager.toggleLoadTest()
                    }
                    .buttonStyle(.bordered)
                    .tint(probeManager.isLoadTestRunning ? .red : .pink)

                    Button("退出登录") {
                        Task {
                            await logout()
                        }
                    }
                    .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Label("随机请求测试", systemImage: "waveform.path.ecg.rectangle")
                        .font(.headline)

                    Text("点击后会以 2 到 8 秒的随机间隔访问一次 `/api/me`，用于观察客户端在持续请求下的登录态和自动续期表现。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    statusRow(title: "当前状态", value: probeManager.trafficTestStatus)
                    statusRow(title: "成功次数", value: "\(probeManager.trafficTestSuccessCount)")
                    statusRow(title: "限流次数", value: "\(probeManager.trafficTestRateLimitedCount)")
                    statusRow(title: "失败次数", value: "\(probeManager.trafficTestFailureCount)")
                    statusRow(title: "最近请求", value: lastRequestText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))

                VStack(alignment: .leading, spacing: 14) {
                    Label("并发请求测试", systemImage: "bolt.horizontal.circle")
                        .font(.headline)

                    Text("点击后会一次性并发发起 8 个 `/api/me` 请求，用于观察并发下的登录态保持、自动续期和失败回退表现。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    statusRow(title: "当前状态", value: probeManager.concurrentTestStatus)
                    statusRow(title: "成功次数", value: "\(probeManager.concurrentTestSuccessCount)")
                    statusRow(title: "限流次数", value: "\(probeManager.concurrentTestRateLimitedCount)")
                    statusRow(title: "失败次数", value: "\(probeManager.concurrentTestFailureCount)")
                    statusRow(title: "最近测试", value: lastConcurrentTestText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))

                VStack(alignment: .leading, spacing: 14) {
                    Label("持续压测", systemImage: "flame")
                        .font(.headline)

                    Text("点击后会以 6 路并发持续访问 `/api/me`，每个 worker 在两次请求之间随机等待 150 到 600 毫秒，可用于观察高频请求下的自动续期、离线保留和接口稳定性。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    statusRow(title: "当前状态", value: probeManager.loadTestStatus)
                    statusRow(title: "成功次数", value: "\(probeManager.loadTestSuccessCount)")
                    statusRow(title: "限流次数", value: "\(probeManager.loadTestRateLimitedCount)")
                    statusRow(title: "失败次数", value: "\(probeManager.loadTestFailureCount)")
                    statusRow(title: "最近请求", value: lastLoadTestText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))

                quickEntryRow(
                    title: "消息 Tab 已提供完整会话和实时链路",
                    systemImage: "message.badge.waveform",
                    tint: .blue
                )

                quickEntryRow(
                    title: "文件 Tab 提供上传、下载和断点续传",
                    systemImage: "arrow.up.arrow.down.circle",
                    tint: .green
                )

                quickEntryRow(
                    title: "设备 Tab 可管理当前账号的活跃会话",
                    systemImage: "iphone.gen2",
                    tint: .orange
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("首页")
        .sheet(isPresented: $isPresentingEditProfile) {
            EditProfileSheet(
                initialEmail: activeUser.email,
                initialDisplayName: activeUser.displayName,
                initialAvatarPreset: activeUser.avatarPreset,
                isSubmitting: sessionStore.isUpdatingProfile,
                message: sessionStore.profileMessage,
                onSubmit: { displayName, avatarPreset in
                    await updateProfile(displayName, avatarPreset)
                }
            )
        }
    }

    private func quickEntryRow(title: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 28)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
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

    private var activeUser: AuthUser {
        sessionStore.currentUser ?? user
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
            return "TCP 握手已完成，可以接收 heartbeat 和服务端踢线事件。"
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

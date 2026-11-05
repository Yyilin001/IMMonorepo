import SwiftUI
import IMV2ClientKit

/// Compact account-level status; details remain live while the sheet is open.
struct V2ConnectionStatusButton: View {
    @Bindable var store: V2AppStore
    var navigationTitle: String? = nil
    @State private var showsDetails = false

    private var title: String {
        switch store.realtimeCoverage?.connectionState {
        case .connected: return "已连接"
        case .disconnected: return "连接已断开"
        case .connecting, nil: return "正在连接"
        }
    }

    private var symbol: String {
        switch store.realtimeCoverage?.connectionState {
        case .connected: return "checkmark.icloud"
        case .disconnected: return "icloud.slash"
        case .connecting, nil: return "arrow.triangle.2.circlepath"
        }
    }

    private var statusColor: Color {
        switch store.realtimeCoverage?.connectionState {
        case .connected: return .green
        case .disconnected: return .red
        case .connecting, nil: return .blue
        }
    }

    private var notificationTitle: String {
        guard store.realtimeCoverage?.connectionState == .connected else { return "实时接收未就绪" }
        switch store.realtimeCoverage?.state {
        case .ready: return "实时接收正常"
        case .recovering where store.realtimeCoverage?.reason != .installing: return "正在恢复实时接收"
        default: return "正在准备实时接收"
        }
    }

    private var notificationDescription: String {
        "实时订阅就绪后才能及时接收新消息和状态变化。网络已连接不代表订阅或历史消息同步已经完成。"
    }

    private var syncTitle: String {
        if store.accountWorkPaused { return "同步已暂停" }
        guard store.realtimeCoverage?.connectionState == .connected else { return "等待连接后继续同步" }
        switch store.realtimeCoverage?.syncPhase {
        case .live: return "已同步"
        case .retryWaiting: return "等待重试同步"
        case .reconciling, .catchingUp: return "正在同步"
        case .idle, .establishingCoverage, nil: return "正在准备同步"
        }
    }

    var body: some View {
        Button { showsDetails = true } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.subheadline)
                    .foregroundStyle(statusColor)
                if let navigationTitle {
                    Text(navigationTitle).font(.headline).foregroundStyle(.primary)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("连接与同步状态")
        .accessibilityValue(title)
        .accessibilityHint("查看当前状态和详细说明")
        .accessibilityIdentifier("v2.connection-status")
        .sheet(isPresented: $showsDetails) {
            NavigationStack {
                Form {
                    Section {
                        Label {
                            Text(title)
                        } icon: {
                            Image(systemName: symbol).foregroundStyle(statusColor)
                        }
                        .font(.headline)
                    }
                    Section("实时订阅") {
                        Text(notificationTitle)
                        Text(notificationDescription).foregroundStyle(.secondary)
                    }
                    Section("数据同步") {
                        Text(syncTitle)
                        if store.accountWorkPaused {
                            Text("账户后台同步已暂停，已保存的操作会保留。你可以尝试重新连接。")
                                .foregroundStyle(.secondary)
                            Button(store.isResumingAccountWork ? "正在重新连接…" : "重新连接") {
                                Task { await store.resumeAccountWork() }
                            }
                            .disabled(store.isResumingAccountWork)
                            .accessibilityIdentifier("v2.account-work.resume")
                        } else {
                            Text("此状态表示当前消息同步进度。每条消息是否发送成功，请以聊天中的发送状态为准。")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .v2GroupedPageSurface()
                .navigationTitle("连接与同步")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showsDetails = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

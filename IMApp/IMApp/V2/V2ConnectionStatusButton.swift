import SwiftUI

/// Compact account-level status; details remain live while the sheet is open.
struct V2ConnectionStatusButton: View {
    @Bindable var store: V2AppStore
    var navigationTitle: String? = nil
    @State private var showsDetails = false

    private var title: String {
        if store.isResumingAccountWork { return "正在重新连接" }
        if store.accountWorkPaused { return "同步已暂停" }
        switch store.realtimeCoverage?.state {
        case .ready: return "实时通知正常"
        case .recovering: return "实时通知正在恢复"
        case .disconnected: return "实时通知未连接"
        case nil: return "正在准备连接"
        }
    }

    private var symbol: String {
        if store.isResumingAccountWork { return "arrow.triangle.2.circlepath" }
        if store.accountWorkPaused { return "exclamationmark.icloud" }
        switch store.realtimeCoverage?.state {
        case .ready: return "checkmark.icloud"
        case .recovering, nil: return "arrow.triangle.2.circlepath"
        case .disconnected: return "icloud.slash"
        }
    }

    private var statusColor: Color {
        if store.isResumingAccountWork { return .blue }
        if store.accountWorkPaused { return .orange }
        switch store.realtimeCoverage?.state {
        case .ready: return .green
        case .recovering, nil: return .blue
        case .disconnected: return .red
        }
    }

    private var notificationDescription: String {
        switch store.realtimeCoverage?.state {
        case .ready: return "实时通知已就绪。每条消息是否发送成功，请以聊天中的发送状态为准。"
        case .recovering: return "实时通知正在恢复，可继续发送消息。新消息和状态变化可能延迟显示，请以聊天中的发送状态为准。"
        case .disconnected: return "实时通知连接已断开，暂时无法及时接收新消息和状态变化。应用会在连接恢复后继续同步。"
        case nil: return "正在准备实时通知连接，连接状态确认后会自动更新。"
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
                    Section("实时通知") {
                        Text(notificationDescription).foregroundStyle(.secondary)
                    }
                    Section("账户同步") {
                        if store.accountWorkPaused {
                            Text("账户后台同步已暂停，已保存的操作会保留。你可以尝试重新连接。")
                                .foregroundStyle(.secondary)
                            Button(store.isResumingAccountWork ? "正在重新连接…" : "重新连接") {
                                Task { await store.resumeAccountWork() }
                            }
                            .disabled(store.isResumingAccountWork)
                            .accessibilityIdentifier("v2.account-work.resume")
                        } else {
                            Text("账户同步未暂停，已保存的操作将按当前连接状态继续处理。")
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

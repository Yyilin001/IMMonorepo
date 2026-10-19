import IMV2ClientKit
import IMV2Core
import SwiftUI

struct V2PendingGroupAvatarsView: View {
    @State private var store: V2PendingGroupAvatarsStore
    @State private var selection: V2PendingGroupAvatarsStore.Selection?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase

    init(store: V2PendingGroupAvatarsStore) { _store = State(initialValue: store) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("这里保留你尚未处理完的群头像更改。即使已经退群，也可确认结果或停止原操作。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                switch store.state {
                case .inactive, .loading:
                    ProgressView("正在读取…")
                case .failed:
                    Text("暂时无法读取记录，请刷新后重试。")
                case .loaded(let page):
                    if page.entries.isEmpty {
                        ContentUnavailableView("没有待处理的群头像", systemImage: "checkmark.circle")
                            .accessibilityIdentifier("v2.group.avatar.pending.empty")
                    } else {
                        Section("待处理更改") {
                            ForEach(page.entries) { entry in
                                Button {
                                    selection = .init(roomID: entry.intent.command.roomID, operationID: entry.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(entry.intent.command.mutation.mediaID == nil ? "移除群头像" : "更换群头像")
                                            .foregroundStyle(.primary)
                                        Text(status(entry.intent)).foregroundStyle(.secondary)
                                        Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityHint("打开这次更改的处理选项")
                                .accessibilityIdentifier("v2.group.avatar.pending.item")
                            }
                        }
                        if page.next != nil {
                            Button("下一批") { store.nextPage() }
                                .accessibilityIdentifier("v2.group.avatar.pending.next")
                        }
                    }
                }
                Section {
                    Button(store.isFirstPage ? "刷新" : "返回首批") { store.refresh() }
                        .accessibilityIdentifier("v2.group.avatar.pending.refresh")
                }
            }
            .navigationTitle("待处理群头像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("v2.group.avatar.pending.done")
                }
            }
            .sheet(item: $selection, onDismiss: { store.refreshCurrentPage() }) { value in
                V2GroupAvatarManagementView(store: store.managementStore(for: value))
            }
        }
        .task(id: phase) {
            if phase == .active { await store.observe() }
            else { store.suspend() }
        }
        .onDisappear { selection = nil; store.suspend() }
    }

    private func status(_ intent: V2GroupAvatarIntent) -> String {
        if intent.stage == .closed { return "已确认未生效，等待你的决定" }
        if intent.submissionStarted { return "结果待确认" }
        return intent.stage == .needsAttention ? "准备未完成" : "正在准备"
    }
}

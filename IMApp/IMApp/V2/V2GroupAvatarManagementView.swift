import Foundation
import IMV2ClientKit
import IMV2Core
import SwiftUI
import UniformTypeIdentifiers

struct V2GroupAvatarManagementView: View {
    private enum Modal: Equatable { case chooseImage, remove }
    @State private var store: V2GroupAvatarManagementStore
    @State private var modal: Modal?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.v2AvatarPipeline) private var pipeline

    init(store: V2GroupAvatarManagementStore) { _store = State(initialValue: store) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        V2AuthorizedGroupAvatarView(roomID: store.roomID, size: 88)
                        Spacer()
                    }
                    accessDescription
                    Button("选择新头像", systemImage: "photo") { modal = .chooseImage }
                        .disabled(!store.canUpload)
                        .accessibilityIdentifier("v2.group.avatar.choose")
                    Button("移除群头像", role: .destructive) { modal = .remove }
                        .disabled(!store.canRemove)
                        .accessibilityIdentifier("v2.group.avatar.remove")
                }
                if !store.pending.isEmpty {
                    Section("待处理更改") {
                        ForEach(store.pending) { intent in pendingRow(intent) }
                    }
                }
                if let focus = store.focusedOperationID, store.didReadPending, !store.pending.contains(where: { $0.id == focus }) {
                    Section { Text("选中的更改已处理完成。").accessibilityIdentifier("v2.group.avatar.focus-completed") }
                }
                if store.isPerformingAction { Section { ProgressView("正在处理…") } }
                if let feedback = store.feedback {
                    Section { Text(feedback).foregroundStyle(.secondary).accessibilityIdentifier("v2.group.avatar.feedback") }
                }
                Section {
                    Button("刷新状态", systemImage: "arrow.clockwise") { store.refresh() }
                        .disabled(store.isPerformingAction)
                        .accessibilityIdentifier("v2.group.avatar.refresh")
                }
            }
            .navigationTitle("群头像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("v2.group.avatar.done")
                }
            }
        }
        .fileImporter(isPresented: modalBinding(.chooseImage), allowedContentTypes: [.jpeg, .png], allowsMultipleSelection: false) { result in
            modal = nil
            if case .success(let urls) = result, let url = urls.first { store.importImage(from: url) }
        }
        .confirmationDialog("移除当前群头像？", isPresented: modalBinding(.remove), titleVisibility: .visible) {
            Button("移除", role: .destructive) { store.remove() }
        }
        .task(id: phase) {
            if phase == .active { await store.observe() }
            else { store.suspend() }
        }
        .task(id: store.deadline) {
            guard let deadline = store.deadline else { return }
            do { try await ContinuousClock().sleep(until: deadline); try Task.checkCancellation(); store.expirePermission(deadline) }
            catch { }
        }
        .task(id: store.authority?.state.revision) {
            guard store.authority != nil else { return }
            await pipeline?.groups.invalidate(roomID: store.roomID)
        }
        .task(id: store.presentationInvalidationGeneration) {
            guard store.presentationInvalidationGeneration > 0 else { return }
            await pipeline?.groups.invalidate(roomID: store.roomID)
        }
        .onDisappear { modal = nil; store.suspend() }
    }

    @ViewBuilder private var accessDescription: some View {
        if let authority = store.displayAuthority {
            if store.isStale { Text("显示上次读取的状态，请刷新后再管理群头像。") }
            else if !authority.canManage { Text("只有群主可以更改群头像。") }
            else if let maximum = authority.maximumUploadBytes {
                Text("JPEG 或 PNG，最大 \(ByteCountFormatter.string(fromByteCount: maximum, countStyle: .file))。关闭页面后，已保存的更改仍会继续处理。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else { Text("暂时无法上传新头像，请稍后刷新。") }
        } else if case .forbidden = store.snapshot?.access {
            Text("当前无法访问群头像，已有更改仍可确认结果。")
        } else { Text("请刷新以获取当前头像和管理权限。") }
    }

    @ViewBuilder private func pendingRow(_ intent: V2GroupAvatarIntent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if intent.id == store.focusedOperationID {
                Text("选中的更改").font(.caption).foregroundStyle(.secondary)
            }
            if intent.stage == .closed {
                Text("服务器已确认这次更改未生效")
                Button("重新提交") { store.replace(intent) }
                    .disabled(!store.canReplace(intent))
                    .accessibilityIdentifier("v2.group.avatar.retry-closed")
                Button("放弃", role: .destructive) { store.act(intent, action: .abandon) }
                    .disabled(store.isPerformingAction)
                    .accessibilityIdentifier("v2.group.avatar.abandon")
            } else if intent.submissionStarted {
                Text(intent.recoveryAction == .closeIfAbsent ? "正在确认这次更改能否停止" : "更改尚未确认")
                Button("确认结果") { store.act(intent, action: .query) }
                    .disabled(store.isPerformingAction)
                    .accessibilityIdentifier("v2.group.avatar.query")
                Button("停止这次更改", role: .destructive) { store.act(intent, action: .closeIfAbsent) }
                    .disabled(store.isPerformingAction)
                    .accessibilityIdentifier("v2.group.avatar.close")
            } else {
                Text(intent.stage == .needsAttention ? "头像准备未完成" : "正在准备群头像")
                if intent.stage == .needsAttention {
                    Button("继续准备") { store.act(intent, action: .retry) }
                        .disabled(store.isPerformingAction)
                }
                Button("取消这次更改", role: .destructive) { store.act(intent, action: .cancel) }
                    .disabled(store.isPerformingAction)
                    .accessibilityIdentifier("v2.group.avatar.cancel-preparation")
            }
        }
        // Form's automatic style treats the whole row as one action. These
        // recovery choices must each dispatch only their own frozen operation.
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func modalBinding(_ value: Modal) -> Binding<Bool> {
        .init(get: { modal == value }, set: { if !$0, modal == value { modal = nil } })
    }
}

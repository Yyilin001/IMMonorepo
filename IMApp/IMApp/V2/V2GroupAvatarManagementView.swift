import Foundation
import IMV2ClientKit
import IMV2Core
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct V2GroupAvatarManagementView: View {
    private enum Modal: Equatable { case chooseImage, chooseResource, remove, library }
    @State private var store: V2GroupAvatarManagementStore
    @State private var modal: Modal?
    @State private var isReadingPhoto = false
    @State private var selectedPhoto: V2NormalizedPhoto?
    @State private var processor = V2ProfileAvatarImageProcessor()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.v2AvatarPipeline) private var pipeline
    @Environment(\.v2ResourceManagement) private var resources

    init(store: V2GroupAvatarManagementStore) { _store = State(initialValue: store) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    V2AuthorizedGroupAvatarView(roomID: store.roomID, size: 144)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                Section {
                    Button("从相册选择", systemImage: "photo.on.rectangle") { modal = .library }
                        .disabled(!store.canUpload || isReadingPhoto)
                        .accessibilityIdentifier("v2.group.avatar.library")
                    if resources != nil {
                        Button("从聊天图片选择", systemImage: "bubble.left.and.text.bubble.right") { modal = .chooseResource }
                            .disabled(!store.canChange).accessibilityIdentifier("v2.group.avatar.choose-resource")
                    }
                    Button("从文件选择", systemImage: "folder") { modal = .chooseImage }
                        .disabled(!store.canUpload).accessibilityIdentifier("v2.group.avatar.choose")
                } footer: { accessDescription }
                if store.displayAuthority?.state.mediaID != nil {
                    Section {
                        Button("移除群头像", role: .destructive) { modal = .remove }
                            .disabled(!store.canRemove).accessibilityIdentifier("v2.group.avatar.remove")
                    }
                }
                if isReadingPhoto { Section { ProgressView("正在读取照片…") } }
                if !store.drafts.isEmpty {
                    Section("本机头像草稿") {
                        ForEach(store.drafts) { image in
                            V2GroupAvatarDraftRow(store: store, image: image)
                        }
                    }
                }
                if !store.pending.isEmpty {
                    Section("头像更新") {
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
            }
            .v2GroupedPageSurface()
            .refreshable { store.refresh() }
            .navigationTitle("群头像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("v2.group.avatar.done")
                }
            }
        }
        .v2PhotoLibraryPicker(isPresented: modalBinding(.library), isImporting: $isReadingPhoto, maximumSelectionCount: 1) { selectedPhoto = $0 }
        .sheet(isPresented: Binding(get: { selectedPhoto != nil }, set: { if !$0 { selectedPhoto = nil } })) {
            if let selectedPhoto {
                NavigationStack {
                    V2ProfileAvatarCropView(photo: selectedPhoto, processor: processor) { photo in
                        guard store.canUpload else { return "当前无法更改群头像，请关闭后刷新重试。" }
                        store.importPhoto(photo)
                        return nil
                    }
                }
            }
        }
        .fileImporter(isPresented: modalBinding(.chooseImage), allowedContentTypes: [.jpeg, .png], allowsMultipleSelection: false) { result in
            modal = nil
            if case .success(let urls) = result, let url = urls.first { store.importImage(from: url) }
        }
        .sheet(isPresented: modalBinding(.chooseResource)) {
            if let resources { V2AvatarResourcePicker(service: resources) { value in modal = nil; store.useResource(value) } }
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
                Text("JPEG 或 PNG，最大 \(ByteCountFormatter.string(fromByteCount: maximum, countStyle: .file))。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else { Text("暂时无法上传新头像，请稍后刷新。") }
        } else if case .forbidden = store.snapshot?.access {
            Text("当前无法访问群头像。")
        } else { Text("请刷新以获取当前头像和管理权限。") }
    }

    @ViewBuilder private func pendingRow(_ intent: V2GroupAvatarIntent) -> some View {
        HStack(spacing: 12) {
            if intent.stage == .closed || intent.stage == .needsAttention {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text("头像未更新，原头像仍保留")
            } else {
                ProgressView()
                Text("正在更新头像…")
            }
        }.accessibilityIdentifier("v2.group.avatar.updating")
        if intent.stage == .closed {
            Button("重新尝试", systemImage: "arrow.clockwise") { store.replace(intent) }
                .disabled(!store.canReplace(intent)).accessibilityIdentifier("v2.group.avatar.retry-closed")
            Button("取消这次更改", role: .destructive) { store.act(intent, action: .abandon) }
                .disabled(store.isPerformingAction).accessibilityIdentifier("v2.group.avatar.abandon")
        } else if !intent.submissionStarted {
            if intent.stage == .needsAttention {
                Button("重新尝试", systemImage: "arrow.clockwise") { store.act(intent, action: .retry) }
                    .disabled(!store.canRetryPreparation(intent)).accessibilityIdentifier("v2.group.avatar.retry")
            }
            Button("取消这次更改", role: .destructive) { store.act(intent, action: .cancel) }
                .disabled(store.isPerformingAction).accessibilityIdentifier("v2.group.avatar.cancel-preparation")
        } else {
            Text("可以离开此页面，恢复连接后会继续更新。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func modalBinding(_ value: Modal) -> Binding<Bool> {
        .init(get: { modal == value }, set: { if !$0, modal == value { modal = nil } })
    }
}

private struct V2GroupAvatarDraftRow: View {
    let store: V2GroupAvatarManagementStore
    let image: V2StagedConversationAttachment
    @Environment(\.v2MediaThumbnailCache) private var cache
    @State private var preview: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let preview {
                    Image(uiImage: preview).resizable().scaledToFill()
                        .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("头像草稿预览")
                }
                VStack(alignment: .leading) {
                    Text(image.displayName)
                    Text(image.availability == .local ? "仅存本机，尚未提交" : "原件不可用，请移除后重新选择")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button("继续提交") { store.submitDraft(image) }
                .disabled(!store.canUpload || image.availability != .local)
                .accessibilityIdentifier("v2.group.avatar.draft.submit")
            Button("移除草稿", role: .destructive) { store.discardDraft(image) }
                .disabled(store.isPerformingAction)
                .accessibilityIdentifier("v2.group.avatar.draft.discard")
        }
        .buttonStyle(.bordered)
        .task(id: image.localAssetID) {
            guard let cache else { return }
            let result = await store.preview(image, cache: cache)
            guard !Task.isCancelled else { return }
            preview = result
        }
    }
}

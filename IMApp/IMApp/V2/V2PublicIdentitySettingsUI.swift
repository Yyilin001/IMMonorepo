import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class V2PublicIdentitySettingsStore {
    private let service: any V2ProfileIntentManaging
    private let attachmentStager: (any V2ConversationAttachmentStaging)?
    private var observationTask: Task<Void, Never>?
    private var confirmedDisplayName: String?
    private var savedAvatarDraft: V2ProfileAvatarUpload?
    private var pendingObservation: (id: UUID, savedName: String)?
    private(set) var profileUserID: UserID?

    private(set) var handle = ""
    var displayName = ""
    private(set) var currentAvatar: V2AvatarReference?
    private(set) var stagedAvatar: V2StagedConversationAttachment?
    private(set) var feedback: String?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var needsAttention = false
    private(set) var canReplacePending = false
    private var revision: V2ProfileRevision?
    private var removesAvatar = false

    init(
        service: any V2ProfileIntentManaging,
        attachmentStager: (any V2ConversationAttachmentStaging)?
    ) {
        self.service = service
        self.attachmentStager = attachmentStager
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if let profile = try await service.localProfile() {
                try Task.checkCancellation()
                apply(profile, preserveDraft: hasEditingDraft)
            }
        } catch is CancellationError { return }
        catch { feedback = "无法读取本机资料，请稍后重试。" }
        do {
            let persisted = try await service.pendingIntent()
            try Task.checkCancellation()
            if let persisted {
                if !hasEditingDraft {
                    if case .set(let name) = persisted.patch.displayName { displayName = name }
                    if case .remove = persisted.patch.avatar { removesAvatar = true }
                    savedAvatarDraft = persisted.avatarUpload
                }
                if revision == nil { revision = persisted.expectedRevision }
                let savedName: String
                if case .set(let name) = persisted.patch.displayName { savedName = name }
                else { savedName = confirmedDisplayName ?? displayName }
                pendingObservation = (persisted.id, savedName)
                feedback = "正在恢复保存进度。"
                observe(persisted.id, savedName: savedName)
            } else if let pendingObservation {
                observe(pendingObservation.id, savedName: pendingObservation.savedName)
            }
        } catch is CancellationError { return }
        catch { feedback = "无法恢复本机保存进度，编辑内容已保留。" }
        do {
            let profile = try await service.refreshProfile()
            try Task.checkCancellation()
            apply(profile, preserveDraft: hasEditingDraft)
            if pendingObservation == nil { feedback = nil }
        } catch is CancellationError { return }
        catch {
            // A failed refresh must retain confirmed local content and editing drafts.
            if pendingObservation == nil {
                feedback = profileUserID == nil ? "无法读取个人资料，请稍后重试。" : "暂时无法刷新，已保留本机资料。"
            }
        }
    }

    private var hasEditingDraft: Bool {
        (confirmedDisplayName.map { displayName != $0 } ?? !displayName.isEmpty) || stagedAvatar != nil || removesAvatar
    }

    func selectAvatar(at url: URL) async {
        guard !isSaving, let attachmentStager else {
            feedback = "头像上传当前不可用。"
            return
        }
        do {
            let staged = try await attachmentStager.stageImportedFile(at: url)
            guard staged.contentType.hasPrefix("image/") else {
                await attachmentStager.discard(staged)
                feedback = "请选择图片文件。"
                return
            }
            if let previous = stagedAvatar { await attachmentStager.discard(previous) }
            stagedAvatar = staged
            savedAvatarDraft = nil
            removesAvatar = false
            feedback = "已选择新头像，保存后生效。"
        } catch is CancellationError {
        } catch {
            feedback = "无法读取这张图片。"
        }
    }

    func removeAvatar() async {
        guard !isSaving else { return }
        if let stagedAvatar, let attachmentStager { await attachmentStager.discard(stagedAvatar) }
        stagedAvatar = nil
        savedAvatarDraft = nil
        removesAvatar = true
        feedback = "头像将在保存后移除。"
    }

    func save() async {
        guard !isSaving, let revision else { return }
        isSaving = true
        defer { isSaving = false }
        let savedName = displayName
        do {
            let avatar: V2ProfileAvatarPatch = removesAvatar ? .remove : .unchanged
            let name: V2ProfileDisplayNamePatch = savedName == confirmedDisplayName ? .unchanged : .set(savedName)
            let source = try stagedAvatar.map { try V2ProfileAvatarUpload(id: $0.id, fileURL: $0.fileURL, displayName: $0.displayName, contentType: $0.contentType, byteCount: $0.byteCount) }
            // The upload dependency is persisted before any transfer begins.
            let patch = try V2ProfilePatch(displayName: name, avatar: source.map { .set(.init(mediaID: .init(uuid: $0.id))) } ?? avatar)
            let intent = try await service.enqueue(expectedRevision: revision, patch: patch, avatarUpload: source)
            // The account intent now owns the staged source. Keep its preview
            // reference until commit/discard rather than reverting to old avatar.
            savedAvatarDraft = source
            stagedAvatar = nil
            removesAvatar = false
            feedback = "已保存，等待同步。"
            pendingObservation = (intent.id, savedName)
            observe(intent.id, savedName: savedName)
        } catch is CancellationError {
        } catch {
            feedback = "未能保存到本机，编辑内容已保留。"
        }
    }

    func resumePendingSave() async {
        guard let pendingObservation, !isSaving else { return }
        isSaving = true; defer { isSaving = false }
        do {
            let next = try await service.resumeOrReapply(intentID: pendingObservation.id)
            self.pendingObservation = (next.id, pendingObservation.savedName)
            needsAttention = false
            observe(next.id, savedName: pendingObservation.savedName)
        } catch { feedback = "无法继续保存，编辑内容已保留。" }
    }
    func discardPendingSave() async {
        guard let pendingObservation, canReplacePending, !isSaving else { return }
        do {
            try await service.discard(intentID: pendingObservation.id)
            stopObserving()
            self.pendingObservation = nil
            savedAvatarDraft = nil
            canReplacePending = false
            needsAttention = false
            feedback = "已丢弃保存操作，文字编辑仍保留。"
        } catch { feedback = "无法丢弃仍在确认的操作。" }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    private func observe(_ id: UUID, savedName: String) {
        stopObserving()
        observationTask = Task { [weak self, service] in
            do {
                for try await status in await service.observe(intentID: id) {
                    try Task.checkCancellation()
                    guard let self else { return }
                    self.needsAttention = status.phase == .needsAttention || status.phase == .closed
                    self.canReplacePending = status.canReplace
                    switch status.phase {
                    case .waitingToSubmit: self.feedback = "已保存，等待同步。"
                    case .uploading: self.feedback = "正在上传头像。"
                    case .confirming: self.feedback = "正在确认保存结果。"
                    case .committed:
                        self.savedAvatarDraft = nil
                        if let profile = status.currentSnapshot {
                            self.apply(profile, preserveDraft: self.displayName != savedName)
                        }
                        self.feedback = "已保存到服务器。"
                    case .needsAttention: self.feedback = "保存需要处理，编辑内容已保留。"
                    case .closed: self.feedback = "保存操作已关闭，编辑内容已保留。"
                    }
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.feedback = "无法读取保存进度。"
            }
        }
    }

    /// 仅加载来自已认证媒体边缘的设备本地副本，并在主线程之外解码为有界缩略图。
    ///
    /// 视图既不会保留原始压缩文件，也不会保留全分辨率图像。
    func avatarPreviewImage(cache: V2LocalMediaThumbnailCache) async -> UIImage? {
        do {
            guard let fileURL = stagedAvatar?.fileURL ?? savedAvatarDraft?.fileURL else { return nil }
            try Task.checkCancellation()
            let preview = await cache.thumbnail(
                fileURL: fileURL,
                maximumPixelSize: 256
            )?.image
            try Task.checkCancellation()
            return preview
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }
    }

    var canSave: Bool {
        revision != nil && !isSaving && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (displayName != confirmedDisplayName || stagedAvatar != nil || removesAvatar)
    }

    var avatarPresentationKey: String {
        if removesAvatar { return "removed" }
        if let stagedAvatar { return "staged-\(stagedAvatar.id.uuidString)" }
        if let savedAvatarDraft { return "saved-\(savedAvatarDraft.id.uuidString)" }
        return currentAvatar?.mediaID.rawValue ?? "none"
    }

    var currentAvatarKey: V2ProfileViewLookupKey? {
        guard !removesAvatar, savedAvatarDraft == nil, currentAvatar != nil, let profileUserID else { return nil }
        return .init(userID: profileUserID, context: .relationship)
    }

    private func apply(_ profile: V2ProfileView, preserveDraft: Bool = false) {
        guard revision.map({ profile.revision >= $0 }) ?? true else { return }
        profileUserID = profile.userID
        handle = profile.publicIdentity?.handle.description ?? ""
        confirmedDisplayName = profile.publicIdentity?.displayName ?? ""
        if !preserveDraft { displayName = confirmedDisplayName ?? "" }
        currentAvatar = profile.avatar
        revision = profile.revision
    }
}

struct V2PublicIdentitySettingsView: View {
    @Environment(\.v2MediaThumbnailCache) private var thumbnailCache
    @Environment(\.v2AvatarPipeline) private var avatarPipeline
    @Bindable var store: V2PublicIdentitySettingsStore
    @State private var isImportingAvatar = false
    @State private var saveTask: Task<Void, Never>?
    @State private var avatarPreviewImage: UIImage?

    var body: some View {
        Form {
            Section("头像") {
                HStack(spacing: 12) {
                    avatarPreview
                    VStack(alignment: .leading, spacing: 2) {
                        Text(avatarDescription)
                        Text("头像以受控媒体保存；仅有权查看资料的用户可读取。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("选择头像") { isImportingAvatar = true }
                    .disabled(store.isSaving)
                    .accessibilityIdentifier("v2.profile.avatar.choose")
                if store.currentAvatar != nil || store.stagedAvatar != nil {
                    Button("移除头像", role: .destructive) {
                        Task { await store.removeAvatar() }
                    }
                    .disabled(store.isSaving)
                    .accessibilityIdentifier("v2.profile.avatar.remove")
                }
            }
            Section("公开 ID") {
                Text(store.handle.isEmpty ? "正在加载…" : store.handle)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("v2.identity.handle")
                Text("公开 ID 暂不可修改；它与登录账号相互独立。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("显示名称") {
                TextField("显示名称", text: $store.displayName)
                    .accessibilityIdentifier("v2.identity.display-name.edit")
                Button("保存") {
                    saveTask?.cancel()
                    saveTask = Task { await store.save() }
                }
                .disabled(!store.canSave)
                .accessibilityIdentifier("v2.identity.save")
            }
            if store.needsAttention {
                Section("处理保存") {
                    Button(store.canReplacePending ? "重新应用保存的草稿" : "继续确认原操作") { Task { await store.resumePendingSave() } }
                        .disabled(store.isSaving)
                    if store.canReplacePending {
                        Button("丢弃保存操作", role: .destructive) { Task { await store.discardPendingSave() } }
                    }
                }
            }
            if let feedback = store.feedback {
                Section {
                    Text(feedback)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("v2.profile.feedback")
                        .onAppear { announceV2AccessibilityAnnouncement(feedback) }
                        .onChange(of: feedback) { _, updatedFeedback in
                            announceV2AccessibilityAnnouncement(updatedFeedback)
                        }
                }
            }
        }
        .navigationTitle("我的资料")
        .task { await store.load() }
        .task(id: store.avatarPresentationKey) {
            avatarPreviewImage = nil
            if let key = store.currentAvatarKey, let avatarPipeline {
                await avatarPipeline.profiles.invalidate([key])
            }
            guard !Task.isCancelled, let thumbnailCache else { return }
            let preview = await store.avatarPreviewImage(cache: thumbnailCache)
            guard !Task.isCancelled else { return }
            avatarPreviewImage = preview
        }
        .fileImporter(isPresented: $isImportingAvatar, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            Task { await store.selectAvatar(at: url) }
        }
        .onDisappear { store.stopObserving() }
    }

    private var avatarDescription: String {
        if let staged = store.stagedAvatar { return "已选择 \(staged.displayName)" }
        return store.currentAvatarKey == nil ? "未设置" : "已设置"
    }

    @ViewBuilder
    private var avatarPreview: some View {
        if let avatarPreviewImage {
            Image(uiImage: avatarPreviewImage)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(Circle())
                .accessibilityLabel("当前头像")
        } else if store.stagedAvatar == nil, let key = store.currentAvatarKey {
            V2AuthorizedAvatarView(key: key, size: 56)
                .id(store.avatarPresentationKey)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                .accessibilityLabel("未设置头像")
        }
    }
}

import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class V2PublicIdentitySettingsStore {
    private let manager: any V2OwnProfileManaging
    private let attachmentStager: (any V2ConversationAttachmentStaging)?
    private let attachmentUploader: (any V2ConversationAttachmentUploading)?
    private let mediaDownloader: (any V2ConversationMediaDownloading)?

    private(set) var handle = ""
    var displayName = ""
    private(set) var currentAvatar: V2AvatarReference?
    private(set) var stagedAvatar: V2StagedConversationAttachment?
    private(set) var feedback: String?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private var revision: V2ProfileRevision?
    private var removesAvatar = false

    init(
        manager: any V2OwnProfileManaging,
        attachmentStager: (any V2ConversationAttachmentStaging)?,
        attachmentUploader: (any V2ConversationAttachmentUploading)?,
        mediaDownloader: (any V2ConversationMediaDownloading)? = nil
    ) {
        self.manager = manager
        self.attachmentStager = attachmentStager
        self.attachmentUploader = attachmentUploader
        self.mediaDownloader = mediaDownloader
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            apply(try await manager.currentProfile())
            feedback = nil
        } catch is CancellationError {
        } catch {
            feedback = "无法读取个人资料，请稍后重试。"
        }
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
        removesAvatar = true
        feedback = "头像将在保存后移除。"
    }

    func save() async {
        guard !isSaving, let revision else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let avatar: V2AvatarReference?
            if removesAvatar {
                avatar = nil
            } else if let stagedAvatar {
                guard let attachmentUploader else { throw V2OwnProfileClientError.authorizationUnavailable }
                let media = try await attachmentUploader.upload(stagedAvatar)
                avatar = .init(mediaID: media.mediaID)
            } else {
                avatar = currentAvatar
            }
            let profile = try await manager.updateProfile(
                operationID: try .init(UUID().uuidString),
                expectedRevision: revision,
                displayName: displayName,
                avatar: avatar
            )
            // The remote update may complete after this view/task was
            // cancelled. Do not overwrite newer local editing state with a
            // result the caller has explicitly abandoned.
            try Task.checkCancellation()
            if let stagedAvatar, let attachmentStager { await attachmentStager.discard(stagedAvatar) }
            stagedAvatar = nil
            removesAvatar = false
            apply(profile)
            feedback = "个人资料已更新。"
        } catch is CancellationError {
        } catch V2OwnProfileClientError.revisionConflict {
            feedback = "资料已在其他设备更新，请刷新后重试。"
            await load()
        } catch {
            feedback = "无法保存个人资料，请稍后重试。"
        }
    }

    /// Loads only a device-local copy obtained from the authenticated media
    /// edge, then decodes a bounded thumbnail away from MainActor. The view
    /// never retains the original compressed file or a full-resolution image.
    func avatarPreviewImage(cache: V2LocalMediaThumbnailCache) async -> UIImage? {
        do {
            let fileURL: URL
            if let stagedAvatar {
                fileURL = stagedAvatar.fileURL
            } else if let currentAvatar, let mediaDownloader {
                fileURL = try await mediaDownloader.download(.init(mediaID: currentAvatar.mediaID), message: nil).fileURL
            } else {
                return nil
            }
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

    var avatarPresentationKey: String {
        if let stagedAvatar { return "staged-\(stagedAvatar.id.uuidString)" }
        return currentAvatar?.mediaID.rawValue ?? "none"
    }

    private func apply(_ profile: V2ProfileView) {
        handle = profile.publicIdentity?.handle.description ?? ""
        displayName = profile.publicIdentity?.displayName ?? ""
        currentAvatar = profile.avatar
        revision = profile.revision
    }
}

struct V2PublicIdentitySettingsView: View {
    @Environment(\.v2MediaThumbnailCache) private var thumbnailCache
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
                .disabled(store.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSaving)
                .accessibilityIdentifier("v2.identity.save")
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
            guard let thumbnailCache else { return }
            let preview = await store.avatarPreviewImage(cache: thumbnailCache)
            guard !Task.isCancelled else { return }
            avatarPreviewImage = preview
        }
        .fileImporter(isPresented: $isImportingAvatar, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            Task { await store.selectAvatar(at: url) }
        }
        .onDisappear { saveTask?.cancel() }
    }

    private var avatarDescription: String {
        if let staged = store.stagedAvatar { return "已选择 \(staged.displayName)" }
        return store.currentAvatar == nil ? "未设置" : "已设置"
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
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                .accessibilityLabel("未设置头像")
        }
    }
}

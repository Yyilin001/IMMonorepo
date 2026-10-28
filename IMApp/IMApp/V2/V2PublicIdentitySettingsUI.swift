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
    var resourceIntentManager: any V2ProfileIntentManaging { service }
    private let attachmentStager: (any V2ConversationAttachmentStaging)?
    private var observationTask: Task<Void, Never>?
    private var confirmedDisplayName: String?
    private var savedAvatarDraft: V2ProfileAvatarUpload?
    private var savedAvatarImport: V2ProfileAvatarImport?
    private(set) var existingAvatar: V2AvatarResourceSelection?
    var hasPendingAvatarImport: Bool { savedAvatarImport != nil }
    @ObservationIgnored private var didRestoreAvatarSelection = false
    @ObservationIgnored private var avatarSelectionGeneration: UInt64 = 0
    private var pendingObservation: (id: UUID, savedName: String)?
    private(set) var profileUserID: UserID?

    private(set) var handle = ""
    var displayName = ""
    private(set) var currentAvatar: V2AvatarReference?
    private(set) var stagedAvatar: V2StagedConversationAttachment?
    private(set) var feedback: String?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var isSelectingAvatar = false
    var needsAttention: Bool { savePhase == .needsAttention || savePhase == .closed }
    private(set) var canReplacePending = false
    private(set) var savePhase: V2ProfileIntentStatus.Phase?
    private var revision: V2ProfileRevision?
    private var removesAvatar = false

    var isUpdating: Bool {
        pendingObservation != nil && !needsAttention && savePhase != .committed
    }
    var canEdit: Bool { revision != nil && !isSaving && !isSelectingAvatar && !isUpdating && (!needsAttention || canReplacePending) }
    var confirmedAvatarKey: V2ProfileViewLookupKey? {
        guard currentAvatar != nil, let profileUserID else { return nil }
        return .init(userID: profileUserID, context: .relationship)
    }
    func nicknameValidation(_ input: String) -> String? {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "请输入昵称。" }
        guard let profileUserID else { return "资料正在加载，请稍后重试。" }
        do {
            _ = try V2PublicIdentity(userID: profileUserID, handle: .init("profile_edit"), displayName: input, accountKind: .regular)
            return nil
        } catch { return "昵称过长或包含不支持的字符，请修改后再试。" }
    }

    init(
        service: any V2ProfileIntentManaging,
        attachmentStager: (any V2ConversationAttachmentStaging)?
    ) {
        self.service = service
        self.attachmentStager = attachmentStager
    }

    func loadCachedProfile() async {
        do {
            if let profile = try await service.localProfile() {
                try Task.checkCancellation()
                apply(profile, preserveDraft: hasEditingDraft)
            }
        } catch is CancellationError { }
        catch { feedback = "无法读取本机资料，请稍后重试。" }
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
        if !didRestoreAvatarSelection, stagedAvatar == nil, let attachmentStager {
            let generation = avatarSelectionGeneration
            do {
                let selections = try await attachmentStager.selectedAttachments(purpose: .personalAvatar)
                try Task.checkCancellation()
                if generation == avatarSelectionGeneration, !didRestoreAvatarSelection, stagedAvatar == nil {
                    stagedAvatar = selections.last
                    for obsolete in selections.dropLast() { await attachmentStager.discard(obsolete) }
                    didRestoreAvatarSelection = true
                }
            } catch is CancellationError { return }
            catch { feedback = "无法恢复本机头像草稿。" }
        }
        do {
            let persisted = try await service.pendingIntent()
            try Task.checkCancellation()
            if let persisted {
                if !hasEditingDraft {
                    if case .set(let name) = persisted.patch.displayName { displayName = name }
                    if case .remove = persisted.patch.avatar { removesAvatar = true }
                    savedAvatarDraft = persisted.avatarUpload
                    savedAvatarImport = persisted.avatarImport
                }
                if revision == nil { revision = persisted.expectedRevision }
                let savedName: String
                if case .set(let name) = persisted.patch.displayName { savedName = name }
                else { savedName = confirmedDisplayName ?? displayName }
                pendingObservation = (persisted.id, savedName)
                feedback = "正在恢复保存进度。"
                observe(persisted.id, savedName: savedName)
            } else {
                // The durable service may have completed, discarded or superseded
                // the previously observed intent while this page was closed.
                stopObserving()
                pendingObservation = nil
                savedAvatarDraft = nil; savedAvatarImport = nil
                canReplacePending = false
                savePhase = nil
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
        (confirmedDisplayName.map { displayName != $0 } ?? !displayName.isEmpty) || stagedAvatar != nil || existingAvatar != nil || removesAvatar
    }

    func selectAvatarResource(_ selection: V2AvatarResourceSelection) async {
        guard !isSaving else { return }
        avatarSelectionGeneration &+= 1
        didRestoreAvatarSelection = true; isSelectingAvatar = false
        let previous = stagedAvatar
        stagedAvatar = nil; savedAvatarDraft = nil; savedAvatarImport = nil
        existingAvatar = selection; removesAvatar = false
        feedback = "已选择已有图片，保存后生效。"
        if let previous, let attachmentStager { await attachmentStager.discard(previous) }
    }

    func selectAvatar(at url: URL) async {
        _ = await stageAvatar(.file(url))
    }
    private enum AvatarSource { case file(URL), photo(V2NormalizedPhoto) }
    private func stageAvatar(_ source: AvatarSource) async -> Bool {
        guard !isSaving, let attachmentStager else {
            feedback = "头像上传当前不可用。"
            return false
        }
        avatarSelectionGeneration &+= 1
        let generation = avatarSelectionGeneration
        isSelectingAvatar = true
        defer { if generation == avatarSelectionGeneration { isSelectingAvatar = false } }
        do {
            let staged: V2StagedConversationAttachment
            switch source {
            case .file(let url): staged = try await attachmentStager.stageImportedFile(at: url, purpose: .personalAvatar)
            case .photo(let photo): staged = try await attachmentStager.stageNormalizedPhoto(photo, purpose: .personalAvatar)
            }
            guard !Task.isCancelled, generation == avatarSelectionGeneration, !isSaving else {
                await attachmentStager.discard(staged)
                return false
            }
            guard staged.contentType.hasPrefix("image/") else {
                await attachmentStager.discard(staged)
                feedback = "请选择图片文件。"
                return false
            }
            let previous = stagedAvatar
            stagedAvatar = staged
            didRestoreAvatarSelection = true
            savedAvatarDraft = nil
            savedAvatarImport = nil; existingAvatar = nil
            removesAvatar = false
            feedback = "已选择新头像，保存后生效。"
            if let previous { await attachmentStager.discard(previous) }
            return true
        } catch is CancellationError {
        } catch {
            guard generation == avatarSelectionGeneration, !Task.isCancelled else { return false }
            feedback = "无法读取这张图片。"
        }
        return false
    }

    func removeAvatar() async {
        guard !isSaving else { return }
        avatarSelectionGeneration &+= 1
        didRestoreAvatarSelection = true
        isSelectingAvatar = false
        let previous = stagedAvatar
        stagedAvatar = nil
        savedAvatarDraft = nil
        savedAvatarImport = nil; existingAvatar = nil
        removesAvatar = true
        feedback = "头像将在保存后移除。"
        if let previous, let attachmentStager { await attachmentStager.discard(previous) }
    }

    func save() async {
        _ = await persist(.all)
    }
    func saveNickname(_ input: String) async -> Bool {
        if let message = nicknameValidation(input) { feedback = message; return false }
        let name = input.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEdit else { return false }
        if name == confirmedDisplayName {
            displayName = name
            if pendingObservation?.savedName != name, needsAttention, canReplacePending { await cancelPendingChange() }
            return true
        }
        displayName = name
        return await persist(.nickname)
    }
    func saveAvatar(_ photo: V2NormalizedPhoto) async -> Bool {
        guard canEdit, await stageAvatar(.photo(photo)) else { return false }
        displayName = confirmedDisplayName ?? displayName
        return await persist(.avatar)
    }
    func saveAvatarResource(_ selection: V2AvatarResourceSelection) async -> Bool {
        guard canEdit else { return false }
        await selectAvatarResource(selection)
        displayName = confirmedDisplayName ?? displayName
        return await persist(.avatar)
    }
    func removeAndSaveAvatar() async -> Bool {
        guard canEdit else { return false }
        await removeAvatar()
        if currentAvatar == nil {
            removesAvatar = false
            feedback = nil
            if needsAttention, canReplacePending { await cancelPendingChange() }
            return true
        }
        displayName = confirmedDisplayName ?? displayName
        return await persist(.avatar)
    }
    private enum SaveFields: Equatable { case all, nickname, avatar }
    private func persist(_ fields: SaveFields) async -> Bool {
        guard !isSelectingAvatar else { feedback = "正在准备头像，请稍候。"; return false }
        guard fields == .nickname || (stagedAvatar.map({ $0.availability == .local }) ?? true) else { feedback = "头像原件不可用，请重新选择。"; return false }
        guard !isSaving, let revision, !isUpdating else { return false }
        isSaving = true
        defer { isSaving = false }
        let savedName = displayName
        do {
            var expectedRevision = revision
            if let pendingObservation, needsAttention {
                guard canReplacePending else { return false }
                let latest = try await service.refreshProfile()
                apply(latest, preserveDraft: true)
                expectedRevision = latest.revision
                try await service.discard(intentID: pendingObservation.id)
                stopObserving()
                self.pendingObservation = nil
                savedAvatarDraft = nil; savedAvatarImport = nil
                canReplacePending = false
                savePhase = nil
            }
            if fields == .nickname, savedName == confirmedDisplayName {
                savePhase = .committed; feedback = "已保存到服务器。"
                return true
            }
            if fields == .avatar, removesAvatar, currentAvatar == nil {
                removesAvatar = false; savePhase = .committed; feedback = "已保存到服务器。"
                return true
            }
            let includesAvatar = fields != .nickname
            let avatar: V2ProfileAvatarPatch = includesAvatar && removesAvatar ? .remove : .unchanged
            let name: V2ProfileDisplayNamePatch = fields == .avatar || savedName == confirmedDisplayName ? .unchanged : .set(savedName)
            let source = try (includesAvatar ? stagedAvatar : nil).map { try V2ProfileAvatarUpload(id: $0.id, localAssetID: $0.localAssetID, displayName: $0.displayName, contentType: $0.contentType, byteCount: $0.byteCount) }
            let imported = try (includesAvatar ? existingAvatar : nil).map { selection in
                try V2ProfileAvatarImport(id: UUID(), request: .init(operationID: .init(uuid: UUID()), source: selection.importSource,
                    targetUsage: .userAvatar, targetMediaID: .init(uuid: UUID())))
            }
            // The upload dependency is persisted before any transfer begins.
            let patch = try V2ProfilePatch(displayName: name, avatar: imported.map { .set(.init(mediaID: $0.request.targetMediaID)) } ?? source.map { .set(.init(mediaID: .init(uuid: $0.id))) } ?? avatar)
            let intent: V2ProfileIntent
            if let imported { intent = try await service.enqueueImportedAvatar(expectedRevision: expectedRevision, patch: patch, source: imported) }
            else { intent = try await service.enqueue(expectedRevision: expectedRevision, patch: patch, avatarUpload: source) }
            // The account intent now owns the staged source. Keep its preview
            // reference until commit/discard rather than reverting to old avatar.
            savedAvatarDraft = source
            savedAvatarImport = imported
            if includesAvatar { existingAvatar = nil; stagedAvatar = nil; removesAvatar = false }
            feedback = "已保存，等待同步。"
            savePhase = source != nil || imported != nil ? .preparingAvatar : .waitingToSubmit
            pendingObservation = (intent.id, savedName)
            observe(intent.id, savedName: savedName)
            return true
        } catch is CancellationError {
        } catch {
            feedback = "未能保存到本机，编辑内容已保留。"
        }
        return false
    }

    func resumePendingSave() async {
        guard let pendingObservation, !isSaving else { return }
        isSaving = true; defer { isSaving = false }
        do {
            let next = try await service.resumeOrReapply(intentID: pendingObservation.id)
            self.pendingObservation = (next.id, pendingObservation.savedName)
            savedAvatarDraft = next.avatarUpload
            savedAvatarImport = next.avatarImport
            canReplacePending = false
            feedback = "已保存，等待同步。"
            savePhase = next.avatarPreparation == nil ? .waitingToSubmit : .preparingAvatar
            observe(next.id, savedName: pendingObservation.savedName)
        } catch { feedback = "无法继续保存，编辑内容已保留。" }
    }
    func discardPendingSave() async {
        guard let pendingObservation, canReplacePending, !isSaving else { return }
        isSaving = true; defer { isSaving = false }
        do {
            try await service.discard(intentID: pendingObservation.id)
            stopObserving()
            self.pendingObservation = nil
            savedAvatarDraft = nil; savedAvatarImport = nil
            canReplacePending = false
            savePhase = nil
            feedback = "已丢弃保存操作，文字编辑仍保留。"
        } catch { feedback = "无法丢弃仍在确认的操作。" }
    }
    func cancelPendingChange() async {
        await discardPendingSave()
        guard pendingObservation == nil else { return }
        avatarSelectionGeneration &+= 1
        let previous = stagedAvatar
        stagedAvatar = nil; existingAvatar = nil; removesAvatar = false
        displayName = confirmedDisplayName ?? displayName
        feedback = nil
        if let previous, let attachmentStager { await attachmentStager.discard(previous) }
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
                    if !status.sourceRetained, status.phase != .committed {
                        self.pendingObservation = nil; self.savedAvatarDraft = nil; self.savedAvatarImport = nil
                        self.canReplacePending = false
                        self.savePhase = nil
                        self.feedback = "此次保存操作已结束，当前编辑内容已保留。"
                        return
                    }
                    self.canReplacePending = status.canReplace
                    self.savePhase = status.phase
                    switch status.phase {
                    case .waitingToSubmit: self.feedback = "已保存，等待同步。"
                    case .preparingAvatar: self.feedback = "正在准备头像。"
                    case .confirming: self.feedback = "正在确认保存结果。"
                    case .committed:
                        self.savedAvatarDraft = nil; self.savedAvatarImport = nil
                        if let profile = status.currentSnapshot {
                            self.apply(profile, preserveDraft: self.displayName != savedName)
                        }
                        self.feedback = "已保存到服务器。"
                        self.pendingObservation = nil
                        return
                    case .needsAttention:
                        self.feedback = status.intent.workID == nil && status.intent.avatarPreparation != nil
                            ? "头像准备未完成，可重试保存或重新选择图片。"
                            : "保存需要处理，编辑内容已保留。"
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
            guard let attachmentStager else { return nil }
            let context: V2LocalResourceReadContext
            if let stagedAvatar { context = .selection(stagedAvatar.localAssetID) }
            else if savedAvatarDraft != nil, let pendingObservation { context = .profileIntent(pendingObservation.id) }
            else { return nil }
            let lease = try await attachmentStager.borrow(context)
            let fileURL = lease.fileURL
            if Task.isCancelled { await lease.release(); return nil }
            let preview = await cache.thumbnail(
                fileURL: fileURL,
                maximumPixelSize: 256
            )?.image
            await lease.release()
            try Task.checkCancellation()
            return preview
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }
    }

    var canSave: Bool {
        revision != nil && !isSaving && !isSelectingAvatar && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (displayName != confirmedDisplayName || stagedAvatar != nil || existingAvatar != nil || removesAvatar)
    }

    var avatarPresentationKey: String {
        if removesAvatar { return "removed" }
        if let existingAvatar { return "existing-" + existingAvatar.key.mediaID.rawValue }
        if let savedAvatarImport { return "import-" + savedAvatarImport.id.uuidString }
        if let stagedAvatar { return "staged-\(stagedAvatar.id.uuidString)" }
        if let savedAvatarDraft { return "saved-\(savedAvatarDraft.id.uuidString)" }
        return currentAvatar?.mediaID.rawValue ?? "none"
    }

    var currentAvatarKey: V2ProfileViewLookupKey? {
        guard !removesAvatar, savedAvatarDraft == nil, savedAvatarImport == nil, existingAvatar == nil, currentAvatar != nil, let profileUserID else { return nil }
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
    @Bindable var store: V2PublicIdentitySettingsStore
    @Environment(\.v2AvatarPipeline) private var avatarPipeline
    @State private var modal: Modal?
    @State private var actionTask: Task<Void, Never>?
    @State private var copied = false
    @State private var avatarRefreshGeneration = 0
    private enum Modal: String, Identifiable {
        case avatar, nickname, cancelChange
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section {
                Button { modal = .avatar } label: {
                    HStack(spacing: 16) {
                        Text("头像").foregroundStyle(.primary)
                        Spacer()
                        V2ProfileAvatarThumbnail(store: store, size: 64)
                        chevron
                    }.frame(minHeight: 76)
                }
                .disabled(!store.canEdit)
                .accessibilityLabel("更换头像")
                .accessibilityIdentifier("v2.profile.avatar.choose")

                Button { modal = .nickname } label: {
                    HStack(spacing: 16) {
                        Text("昵称").foregroundStyle(.primary)
                        Spacer()
                        Text(store.displayName.isEmpty ? "未设置" : store.displayName)
                            .foregroundStyle(.secondary).lineLimit(1)
                        chevron
                    }.frame(minHeight: 36)
                }
                .disabled(!store.canEdit)
                .accessibilityIdentifier("v2.identity.name.open")

                Button {
                    guard !store.handle.isEmpty else { return }
                    UIPasteboard.general.string = store.handle
                    copied = true
                    announceV2AccessibilityAnnouncement("已复制公开 ID")
                } label: {
                    HStack(spacing: 16) {
                        Text("公开 ID").foregroundStyle(.primary)
                        Spacer()
                        Text(store.handle.isEmpty ? "正在加载…" : store.handle)
                            .foregroundStyle(.secondary).textSelection(.enabled)
                            .accessibilityIdentifier("v2.identity.handle")
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.subheadline).foregroundStyle(copied ? .green : .secondary)
                            .accessibilityHidden(true)
                    }.frame(minHeight: 36)
                }
                .disabled(store.handle.isEmpty)
                .accessibilityHint("复制用于查找和添加好友的公开 ID")
                .accessibilityIdentifier("v2.identity.handle.copy")
            } footer: {
                Text(copied ? "已复制公开 ID" : "公开 ID 用于查找和添加好友，目前不可修改。")
            }

            if let phase = store.savePhase {
                Section {
                    HStack(spacing: 12) {
                        if store.isUpdating { ProgressView().accessibilityHidden(true) }
                        else { Image(systemName: phase == .committed ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(phase == .committed ? .green : .orange).accessibilityHidden(true) }
                        Text(statusText(phase)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("v2.profile.feedback")
                    }
                    if store.needsAttention {
                        Button("重试") { run { await store.resumePendingSave() } }
                            .disabled(store.isSaving).accessibilityIdentifier("v2.profile.save.retry")
                        if store.canReplacePending {
                            Button("取消这次更改", role: .destructive) { modal = .cancelChange }
                                .disabled(store.isSaving)
                        }
                    }
                } footer: {
                    if store.isUpdating { Text("你可以离开此页面，更新会在后台继续。") }
                }
            } else if store.canSave {
                Section {
                    Text("有尚未保存的更改").foregroundStyle(.secondary)
                    if let feedback = store.feedback { Text(feedback).font(.footnote).foregroundStyle(.secondary) }
                    Button("保存更改") { run { await store.save() } }
                        .accessibilityIdentifier("v2.identity.save")
                }
            } else if let feedback = store.feedback {
                Section { Text(feedback).foregroundStyle(.secondary).accessibilityIdentifier("v2.profile.feedback") }
            }
        }
        .v2GroupedPageSurface()
        .navigationTitle("个人资料").navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .refreshable { await store.load() }
        .onChange(of: store.currentAvatar?.mediaID) { _, _ in avatarRefreshGeneration += 1 }
        .task(id: avatarRefreshGeneration) {
            guard avatarRefreshGeneration > 0 else { return }
            if let user = store.profileUserID, let avatarPipeline {
                await avatarPipeline.profiles.invalidate([.init(userID: user, context: .relationship)])
            }
        }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(3)); copied = false } catch { }
        }
        .sheet(item: Binding(get: { modal == .cancelChange ? nil : modal }, set: { modal = $0 })) { item in
            switch item {
            case .avatar: V2ProfileAvatarEditor(store: store)
            case .nickname: V2ProfileNicknameEditor(store: store)
            case .cancelChange: EmptyView()
            }
        }
        .confirmationDialog("取消这次更改？", isPresented: Binding(get: { modal == .cancelChange }, set: { if !$0, modal == .cancelChange { modal = nil } }), titleVisibility: .visible) {
            Button("取消更改", role: .destructive) { run { await store.cancelPendingChange() } }
            Button("继续保留", role: .cancel) { }
        } message: { Text("已生效的昵称和头像不会改变。") }
        .onDisappear { actionTask?.cancel(); store.stopObserving() }
    }
    private var chevron: some View {
        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary).accessibilityHidden(true)
    }
    private func statusText(_ phase: V2ProfileIntentStatus.Phase) -> String {
        switch phase {
        case .waitingToSubmit: "正在保存…"
        case .preparingAvatar: "正在更新头像…"
        case .confirming: "正在确认更新…"
        case .committed: "已保存"
        case .needsAttention, .closed: store.feedback ?? "更新未完成，请重试或重新编辑。"
        }
    }
    private func run(_ operation: @escaping @MainActor () async -> Void) {
        actionTask?.cancel(); actionTask = Task { await operation() }
    }
}

struct V2ProfileAvatarThumbnail: View {
    let store: V2PublicIdentitySettingsStore
    var size: CGFloat = 64
    @Environment(\.v2MediaThumbnailCache) private var thumbnailCache
    @State private var preview: UIImage?
    var body: some View {
        Group {
            if let preview {
                Image(uiImage: preview).resizable().scaledToFill()
                    .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.25))
            } else if let key = store.confirmedAvatarKey {
                V2AuthorizedAvatarView(key: key, size: size).id(store.currentAvatar?.mediaID)
            } else { V2AvatarPlaceholder(title: store.displayName, size: size) }
        }
        .accessibilityLabel("头像")
        .task(id: store.avatarPresentationKey) {
            guard !Task.isCancelled, let thumbnailCache else { return }
            let image = await store.avatarPreviewImage(cache: thumbnailCache)
            guard !Task.isCancelled else { return }
            preview = image
        }
    }
}

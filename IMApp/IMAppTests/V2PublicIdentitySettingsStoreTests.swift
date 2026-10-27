import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2PublicIdentitySettingsStoreTests {
    @Test func existingImageSelectionSavesAnImportWithoutStagingOrUploading() async throws {
        let service = try ProfileIntentServiceFixture(), store = V2PublicIdentitySettingsStore(service: service, attachmentStager: nil)
        await store.load()
        let location = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        let selection = V2AvatarResourceSelection(key: .init(home: .room(location.roomID), mediaID: .init(uuid: UUID())),
            source: .init(location: location, ordinal: 0, createdAt: nil), displayName: "已有头像.png")
        await store.selectAvatarResource(selection)
        #expect(store.canSave && store.stagedAvatar == nil && store.currentAvatarKey == nil)
        await store.save()
        let imported = try #require(await service.savedImport)
        #expect(imported.request.source == selection.importSource && imported.request.targetUsage == .userAvatar)
        #expect(imported.request.targetMediaID != selection.key.mediaID)
        #expect(await service.savedPatch?.avatar == .set(.init(mediaID: imported.request.targetMediaID)))
        #expect(store.existingAvatar == nil && !store.canSave)
        store.stopObserving()
    }
    @Test("avatar selection is recovered from the real original journal after a cold account open")
    func restoresLocalAvatarSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "profile-original-restore-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "avatar.png"); try Data([1,2,3]).write(to: source)
        let fixture = try await V2OriginalResourceTestFixture(root: root)
        let draft = try await fixture.stager.stageImportedFile(at: source, purpose: .personalAvatar)
        _ = try await fixture.stager.stageImportedFile(at: source, purpose: .messageDraft(.init(uuid: UUID())))
        try await fixture.close()
        let restored = try await V2OriginalResourceTestFixture(root: root, scope: fixture.scope)
        let page = V2PublicIdentitySettingsStore(service: try ProfileIntentServiceFixture(), attachmentStager: restored.stager)
        await page.load()
        #expect(page.stagedAvatar?.localAssetID == draft.localAssetID)
        #expect(try await restored.read(.selection(draft.localAssetID)) == Data([1,2,3]))
        await page.removeAvatar()
        await page.load()
        #expect(page.stagedAvatar == nil)
        #expect(try await restored.stager.selectedAttachments(purpose: .personalAvatar).isEmpty)
        page.stopObserving(); try await restored.close()
    }

    @Test("a late import cannot resurrect a removed or cancelled avatar selection", arguments: [false, true])
    func lateImportIsDiscarded(remove: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "profile-original-late-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "avatar.png"); try Data([1,2,3]).write(to: source)
        let fixture = try await V2OriginalResourceTestFixture(root: root)
        let stager = PausedProfileStager(base: fixture.stager)
        let page = V2PublicIdentitySettingsStore(service: try ProfileIntentServiceFixture(), attachmentStager: stager)
        await page.load()
        let selection = Task { await page.selectAvatar(at: source) }
        await stager.entered()
        #expect(page.isSelectingAvatar && !page.canSave)
        if remove { await page.removeAvatar() } else { selection.cancel() }
        await stager.release(); await selection.value
        #expect(page.stagedAvatar == nil && !page.isSelectingAvatar)
        #expect(try await fixture.stager.selectedAttachments(purpose: .personalAvatar).isEmpty)
        #expect(try Data(contentsOf: source) == Data([1,2,3]))
        page.stopObserving(); try await fixture.close()
    }

    @Test func avatarUsesPresentationContext() async throws {
        let avatar = V2AvatarReference(mediaID: .init(uuid: UUID()))
        let service = try ProfileIntentServiceFixture(avatar: avatar)
        let store = V2PublicIdentitySettingsStore(service: service, attachmentStager: nil)
        await store.load()
        #expect(store.currentAvatar == avatar)
        #expect(store.currentAvatarKey == .init(userID: service.profile.userID, context: .relationship))
        await store.removeAvatar()
        #expect(store.currentAvatarKey == nil)
        #expect(store.avatarPresentationKey == "removed")
    }
    @Test func localProfileAppearsBeforeSlowRefreshAndFailureKeepsTypedDraft() async throws {
        let service = try ProfileIntentServiceFixture()
        await service.blockRefresh()
        let store = V2PublicIdentitySettingsStore(service: service, attachmentStager: nil)
        let loading = Task { await store.load() }
        for _ in 0..<10000 { if await service.refreshIsWaiting() { break }; await Task.yield() }
        #expect(await service.refreshIsWaiting())
        #expect(store.displayName == "当前显示名")
        #expect(store.profileUserID == service.profile.userID)
        store.displayName = "网络等待时的草稿"
        await service.failRefresh()
        await loading.value
        #expect(store.displayName == "网络等待时的草稿")
        #expect(store.profileUserID == service.profile.userID)
        #expect(store.feedback == "暂时无法刷新，已保留本机资料。")
    }
    @Test func savePersistsIntentAndRefreshPreservesDraft() async throws {
        let service = try ProfileIntentServiceFixture()
        let store = V2PublicIdentitySettingsStore(service: service, attachmentStager: nil)
        await store.load()
        store.displayName = "本地草稿"
        await store.load()
        #expect(store.displayName == "本地草稿")
        await store.save()
        #expect(store.feedback == "已保存，等待同步。")
        #expect(!store.isSaving)
        store.stopObserving()
        let patch = await service.savedPatch
        #expect(patch?.displayName == .set("本地草稿"))
        #expect(patch?.avatar == .unchanged)
    }
    @Test func newPageRestoresPersistedDraftWithoutReplacingNewTyping() async throws {
        let service = try ProfileIntentServiceFixture()
        let first = V2PublicIdentitySettingsStore(service: service, attachmentStager: nil)
        await first.load()
        first.displayName = "已持久保存的草稿"
        await first.save()
        first.stopObserving()
        let restored = V2PublicIdentitySettingsStore(service: service, attachmentStager: nil)
        await restored.load()
        #expect(restored.displayName == "已持久保存的草稿")
        #expect(restored.feedback == "正在恢复保存进度。")
        restored.stopObserving()
        let editing = V2PublicIdentitySettingsStore(service: service, attachmentStager: nil)
        editing.displayName = "本次新输入"
        await editing.load()
        #expect(editing.displayName == "本次新输入")
        editing.stopObserving()
    }

}

private actor PausedProfileStager: V2ConversationAttachmentStaging {
    let base: V2FileConversationAttachmentStager
    private let starts = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?
    init(base: V2FileConversationAttachmentStager) { self.base = base }
    func stageImportedFile(at sourceURL: URL, purpose: V2LocalResourceAssetPurpose) async throws -> V2StagedConversationAttachment {
        let asset = try await base.stageImportedFile(at: sourceURL, purpose: purpose)
        await withCheckedContinuation { continuation = $0; starts.continuation.yield(()) }
        return asset
    }
    func entered() async { var iterator = starts.stream.makeAsyncIterator(); _ = await iterator.next() }
    func release() { continuation?.resume(); continuation = nil }
    func selectedAttachments(purpose: V2LocalResourceAssetPurpose) async throws -> [V2StagedConversationAttachment] {
        try await base.selectedAttachments(purpose: purpose)
    }
    func borrow(_ context: V2LocalResourceReadContext) async throws -> V2ResourceFileLease { try await base.borrow(context) }
    func discard(_ attachment: V2StagedConversationAttachment) async { await base.discard(attachment) }
}

private actor ProfileIntentServiceFixture: V2ProfileIntentManaging {
    private(set) var savedImport: V2ProfileAvatarImport?
    func enqueueImportedAvatar(expectedRevision: V2ProfileRevision, patch: V2ProfilePatch, source: V2ProfileAvatarImport) async throws -> V2ProfileIntent {
        savedPatch = patch; savedImport = source
        let value = V2ProfileIntent(id: UUID(), accountID: profile.userID, operationID: .init(uuid: UUID()), expectedRevision: expectedRevision,
            patch: patch, avatarPreparation: .serverImport(source), deadline: Date().addingTimeInterval(86400), workID: nil)
        pending = value
        return value
    }
    nonisolated let profile: V2ProfileView
    private var pending: V2ProfileIntent?
    private var shouldBlockRefresh = false
    private var refreshContinuation: CheckedContinuation<V2ProfileView, any Error>?
    private(set) var savedPatch: V2ProfilePatch?
    init(avatar: V2AvatarReference? = nil) throws {
        let user = UserID(uuid: UUID())
        profile = try .init(userID: user, publicIdentity: .init(userID: user, handle: .init("profile_test"), displayName: "当前显示名", accountKind: .regular), avatar: avatar, state: .active, revision: .init(rawValue: 1)!, visibilityRevision: .init(rawValue: 1)!)
    }
    func pendingIntent() async throws -> V2ProfileIntent? { pending }
    func currentProfile() async throws -> V2ProfileView { profile }
    func localProfile() async throws -> V2ProfileView? { profile }
    func refreshProfile() async throws -> V2ProfileView {
        if shouldBlockRefresh { return try await withCheckedThrowingContinuation { refreshContinuation = $0 } }
        return profile
    }
    func blockRefresh() { shouldBlockRefresh = true }
    func refreshIsWaiting() -> Bool { refreshContinuation != nil }
    func failRefresh() { refreshContinuation?.resume(throwing: V2OwnProfileClientError.networkFailure); refreshContinuation = nil }
    func enqueue(expectedRevision: V2ProfileRevision, patch: V2ProfilePatch, avatarUpload: V2ProfileAvatarUpload?) async throws -> V2ProfileIntent {
        savedPatch = patch
        let intent = V2ProfileIntent(id: UUID(), accountID: profile.userID, operationID: .init(uuid: UUID()), expectedRevision: expectedRevision, patch: patch, avatarUpload: avatarUpload, deadline: Date().addingTimeInterval(86400), workID: nil)
        pending = intent
        return intent
    }
    func resumeOrReapply(intentID: UUID) async throws -> V2ProfileIntent { throw V2OperationWorkError.invalidTransition }
    func discard(intentID: UUID) async throws {}
    func observe(intentID: UUID) async -> AsyncThrowingStream<V2ProfileIntentStatus, Error> { .init { $0.finish() } }
}

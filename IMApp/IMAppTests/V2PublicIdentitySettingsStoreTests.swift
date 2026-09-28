import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2PublicIdentitySettingsStoreTests {
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
private actor ProfileIntentServiceFixture: V2ProfileIntentManaging {
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

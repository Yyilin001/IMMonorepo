import Foundation
import Testing
import IMV2Core
@testable import IMV2ClientKit
@testable import IMApp

@MainActor
struct V2PreferenceActivityTests {
    @Test func sequentialChangesFromStaleListItemPreserveOtherSavedFields() async throws {
        let f = try Fixture()
        let dataSource = V2GRDBConversationDataSource(localStore: f.store, requestLatestVisible: { _ in })
        let list = V2ConversationListStore(environment: .init(userID: f.user.rawValue,
            projections: .init(dataSource: dataSource), messages: .init(stateChanger: f.adapter)))
        let oldItem = V2ConversationListItem(id: "room", title: "Room", preview: "", lastActivity: Date(),
            isOutgoing: false, kind: .direct(accountKind: .regular))
        await list.updateConversationState(oldItem, isPinned: true)
        await list.updateConversationState(oldItem, isArchived: true)
        let desired = try await f.service.desiredTarget(fallback: .conversation(roomID: .init("room"), isPinned: false, isArchived: false, muteUntil: nil))
        #expect(desired == .conversation(roomID: try .init("room"), isPinned: true, isArchived: true, muteUntil: nil))
        #expect(list.preferenceActivity != nil)
        #expect(try await f.store.preparePersonalPreferences(accountID: f.user) == 1)
        try await f.store.close()
    }
    @Test func savedDraftAppearsAndExplicitDiscardRemovesOnlyLocalDraft() async throws {
        let f = try Fixture()
        let activity = V2PreferenceActivityStore(manager: f.adapter)
        let observing = Task { await activity.observe() }
        defer { observing.cancel() }
        let id = try await f.service.enqueue(.favorite(roomID: .init("room"), messageID: .init("message"), isFavorited: true))
        for _ in 0..<100 where activity.entries.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let entry = try #require(activity.entries.first)
        #expect(entry.id == id && entry.canDiscard && !entry.canResume)
        #expect(V2PreferenceActivityStore.title(entry) == "收藏消息")
        await activity.discard(id)
        for _ in 0..<100 where !activity.entries.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(activity.entries.isEmpty)
        #expect(try await f.store.preparePersonalPreferences(accountID: f.user) == 0)
        observing.cancel()
        await observing.value
        try await f.store.close()
    }

    @Test func unknownCannotBeRemovedAndContinueKeepsOriginalIdentityAndCooldown() async throws {
        let f = try Fixture()
        let id = try await f.service.enqueue(.favorite(roomID: .init("room"), messageID: .init("message"), isFavorited: true))
        #expect(try await f.store.preparePersonalPreferences(accountID: f.user) == 1)
        let original = try #require(try await f.store.dueOperationWork(now: Date()).first)
        guard case .claimed(let claim) = try await f.store.claimOperationWork(id: original.id, ownerID: UUID(), action: .submit, now: Date()) else { Issue.record("missing claim"); return }
        let floor = Date().addingTimeInterval(7200)
        try await f.store.deferOperationWork(claim, until: floor, code: "LOST_REPLY", scheduling: .needsAttention)
        let activity = V2PreferenceActivityStore(manager: f.adapter)
        let observing = Task { await activity.observe() }
        defer { observing.cancel() }
        for _ in 0..<100 where activity.entries.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let entry = try #require(activity.entries.first)
        #expect(entry.canResume && !entry.canDiscard)
        await activity.discard(id)
        #expect(try await f.store.operationWork(id: original.id)?.scheduling == .needsAttention)
        await activity.resume(id)
        let resumed = try #require(try await f.store.operationWork(id: original.id))
        #expect(resumed.identity == original.identity && resumed.fingerprint == original.fingerprint)
        #expect(resumed.nextAction == .reconcile)
        #expect(resumed.nextActionAt.timeIntervalSince1970 == floor.timeIntervalSince1970)
        #expect(resumed.attemptCount == 1)
        observing.cancel()
        await observing.value
        try await f.store.close()
    }

    private struct Fixture {
        let user = UserID(uuid: UUID())
        let store: GRDBV2LocalSyncStore
        let service: V2PersonalPreferenceService
        let adapter: V2OutboxConversationStateChanger
        init() throws {
            store = try .init(databaseURL: FileManager.default.temporaryDirectory.appending(path: "preference-activity-\(UUID()).sqlite"), installationBinding: .init(value: UUID()), userID: user)
            service = .init(accountID: user, store: store, transport: NoNetwork(), recovery: NoNetwork())
            adapter = .init(service: service)
        }
    }
}

private struct NoNetwork: V2ClientConversationCapabilitiesTransport, V2PersonalPreferenceRecovering {
    func setConversationState(command: V2ConversationStateCommand) async throws -> V2PersonalPreferenceReceipt { throw URLError(.notConnectedToInternet) }
    func setMessageFavorite(command: V2MessageFavoriteCommand) async throws -> V2PersonalPreferenceReceipt { throw URLError(.notConnectedToInternet) }
    func recover(_ request: V2PersonalPreferenceRecoveryRequest) async throws -> V2PersonalPreferenceRecoveryResult { throw URLError(.notConnectedToInternet) }
}

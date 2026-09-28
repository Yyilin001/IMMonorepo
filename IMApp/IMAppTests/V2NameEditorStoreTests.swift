import Foundation
import IMV2Core
@testable import IMV2ClientKit
@testable import IMApp
import Testing

@MainActor @Suite("Durable name editor", .serialized)
struct V2NameEditorStoreTests {
    @Test("closing page observation does not cancel a persisted name operation", arguments: [false, true])
    func closingPagePreservesIntent(group: Bool) async throws {
        let f = try await NameEditorFixture.make(group: group)
        let editor = f.editor()
        let observer = Task { await editor.observe() }
        await editor.load(); editor.edit("Draft")
        await editor.save()
        try await waitUntil { editor.pending != nil }
        let id = try #require(editor.pending?.id)
        observer.cancel(); await observer.value
        #expect(try await f.store.operationWork(id: id)?.execution == .prepared)
        #expect(await f.remote.submissions == 0)
        try await f.execute(id)
        #expect(try await f.store.operationWork(id: id)?.execution == .committed)
        #expect(try await f.store.nameSnapshot(target: f.target)?.name == "Draft")
        try await f.close()
    }

    @Test("process recreation restores the original pending draft and identity")
    func coldStartupRestoresPending() async throws {
        let f = try await NameEditorFixture.make()
        let originalID = try await f.service.save(f.target, name: "Pending draft", expectedRevision: .init(rawValue: 1))
        try await f.store.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: f.url, installationBinding: f.binding, userID: f.owner)
        let service = V2NameOperationService(accountID: f.owner, store: reopened, client: f.remote)
        let editor = V2NameEditorStore(target: f.target, service: service)
        let observer = Task { await editor.observe() }
        await editor.load()
        try await waitUntil { editor.pending?.id == originalID }
        #expect(editor.text == "Pending draft" && !editor.canSave)
        #expect(try await reopened.nameCommand(workID: originalID).0.name == "Pending draft")
        observer.cancel(); await observer.value
        try await reopened.close(); f.removeFiles()
    }

    @Test("a late refresh updates baseline without replacing text edited while it was waiting")
    func refreshPreservesTyping() async throws {
        let f = try await NameEditorFixture.make()
        let editor = f.editor()
        await editor.load()
        await f.remote.blockNextRead()
        await f.remote.setSnapshot("New confirmed", revision: 2)
        let refresh = Task { await editor.refresh() }
        await f.remote.waitForBlockedRead()
        editor.edit("Typed during refresh")
        await f.remote.releaseRead()
        await refresh.value
        #expect(editor.text == "Typed during refresh")
        #expect(editor.baseline?.name == "New confirmed" && editor.baseline?.revision?.rawValue == 2)
        try await f.close()
    }

    @Test("unknown submission result forbids saving a second operation")
    func unknownForbidsAnotherSave() async throws {
        let f = try await NameEditorFixture.make()
        let editor = f.editor()
        let ownObservation = Task { await editor.observe() }
        await editor.load(); editor.edit("Original draft"); await editor.save()
        try await waitUntil { editor.pending != nil }
        let id = try #require(editor.pending?.id)
        await f.remote.setBehavior(.unknown)
        try await f.execute(id)
        try await waitUntil { editor.pending?.work.execution == .awaitingConfirmation }
        editor.edit("Different draft")
        #expect(!editor.canSave)
        await editor.save()
        #expect(editor.pending?.id == id)
        let due = try await f.store.dueOperationWork(now: Date().addingTimeInterval(3600), limit: 20, kinds: [.contactAlias])
        #expect(due.map(\.id) == [id])
        #expect(await f.remote.submissions == 1)
        ownObservation.cancel(); await ownObservation.value
        try await f.close()
    }

    @Test("conflict requires explicit rebase, keeps draft, and freezes a new identity against refreshed revision")
    func conflictRequiresExplicitRefresh() async throws {
        let f = try await NameEditorFixture.make()
        let editor = f.editor()
        let ownObservation = Task { await editor.observe() }
        await editor.load(); editor.edit("My preserved draft"); await editor.save()
        try await waitUntil { editor.pending != nil }
        let originalID = try #require(editor.pending?.id)
        await f.remote.setBehavior(.conflict)
        try await f.execute(originalID)
        try await waitUntil { editor.pending?.work.execution == .conflicted }
        #expect(!editor.canSave && editor.text == "My preserved draft")
        await f.remote.setSnapshot("Changed elsewhere", revision: 2)
        let reopenedEditor = f.editor()
        let reopenedObservation = Task { await reopenedEditor.observe() }
        try await waitUntil { reopenedEditor.pending?.work.execution == .conflicted }
        await reopenedEditor.load()
        #expect(!reopenedEditor.canSave)
        #expect(reopenedEditor.text == "My preserved draft")
        await editor.refresh()
        #expect(editor.canSave && editor.text == "My preserved draft")
        #expect(editor.baseline?.revision?.rawValue == 2)
        await editor.save()
        try await waitUntil { editor.pending?.id != originalID }
        let replacementID = try #require(editor.pending?.id)
        #expect(replacementID != originalID)
        #expect(try await f.store.nameCommand(workID: replacementID).0.revision?.rawValue == 2)
        #expect(try await f.store.nameCommand(workID: replacementID).0.name == "My preserved draft")
        ownObservation.cancel(); reopenedObservation.cancel()
        await ownObservation.value; await reopenedObservation.value
        try await f.close()
    }

    @Test("a cross-device alias invalidation withdraws the editing base and preserves the draft")
    func baselineInvalidationPreservesDraft() async throws {
        let f = try await NameEditorFixture.make()
        let editor = f.editor()
        await editor.load()
        let observation = Task { await editor.observeBaseline() }
        editor.edit("Keep this draft")
        guard case .contact(let user) = f.target else { Issue.record("expected contact target"); return }
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init(UUID().uuidString), projectionKind: "contact_alias",
            payload: JSONSerialization.data(withJSONObject: ["target_user_id": user.rawValue, "revision": 2]))
        _ = try await f.store.apply(.init(generation: 1, records: [record], nextSyncToken: .init("alias-floor"),
            receipt: .init("alias-floor-receipt"), hasMore: false, capabilityProfile: "base"))
        try await waitUntil { editor.baseline == nil }
        #expect(editor.text == "Keep this draft" && !editor.canSave)
        await f.remote.setSnapshot("Changed elsewhere", revision: 2)
        await editor.refresh()
        #expect(editor.baseline?.revision?.rawValue == 2 && editor.text == "Keep this draft" && editor.canSave)
        observation.cancel(); await observation.value
        try await f.close()
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() { try #require(ContinuousClock.now < deadline); await Task.yield() }
    }
}

@MainActor private struct NameEditorFixture {
    let url: URL
    let owner: UserID
    let target: V2NameTarget
    let binding: V2LocalInstallationBinding
    let store: GRDBV2LocalSyncStore
    let remote: NameEditorRemote
    let service: V2NameOperationService
    static func make(group: Bool = false) async throws -> Self {
        let url = FileManager.default.temporaryDirectory.appending(path: "name-editor-" + UUID().uuidString).appending(path: "V2.sqlite")
        let owner = try UserID(UUID().uuidString)
        let target: V2NameTarget = group ? .group(try .init(UUID().uuidString)) : .contact(try .init(UUID().uuidString))
        let binding = V2LocalInstallationBinding(value: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: owner)
        let remote = NameEditorRemote()
        try await store.saveNameSnapshot(.init(target: target, name: "Confirmed", revision: .init(rawValue: 1)), accountID: owner)
        return .init(url: url, owner: owner, target: target, binding: binding, store: store, remote: remote,
            service: .init(accountID: owner, store: store, client: remote))
    }
    func editor() -> V2NameEditorStore { .init(target: target, service: service) }
    func execute(_ id: UUID) async throws {
        let work = try #require(try await store.operationWork(id: id))
        guard case .claimed(let claim) = try await store.claimOperationWork(id: id, ownerID: UUID(), action: work.nextAction, now: work.nextActionAt) else {
            throw V2OperationWorkError.invalidTransition
        }
        try await service.execute(claim)
    }
    func close() async throws { try await store.close(); removeFiles() }
    func removeFiles() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}
private actor NameEditorRemote: V2NameOperationClient {
    enum Behavior { case commit, unknown, conflict }
    var submissions = 0
    private var behavior: Behavior = .commit
    private var name = "Confirmed"
    private var revision: UInt64 = 1
    private var shouldBlock = false
    private var blocked = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    func setBehavior(_ value: Behavior) { behavior = value }
    func setSnapshot(_ name: String, revision: UInt64) { self.name = name; self.revision = revision }
    func blockNextRead() { shouldBlock = true }
    func waitForBlockedRead() async { if !blocked { await withCheckedContinuation { startWaiter = $0 } } }
    func releaseRead() { shouldBlock = false; blocked = false; releaseWaiter?.resume(); releaseWaiter = nil }
    private func readGate() async {
        if shouldBlock {
            blocked = true; startWaiter?.resume(); startWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }
    }
    func contactSnapshot(owner: UserID, target: UserID) async throws -> V2ContactAliasSnapshot {
        await readGate()
        return try .init(ownerUserID: owner, targetUserID: target, value: .init(ownerUserID: owner, targetUserID: target, remarkName: name, revision: .init(rawValue: revision)!))
    }
    func groupSnapshot(actor: UserID, room: RoomID) async throws -> V2GroupNicknameSnapshot {
        await readGate()
        return try .init(actorUserID: actor, roomID: room, value: .init(roomID: room, userID: actor, groupNickname: name, revision: .init(rawValue: revision)!))
    }
    func submit(_ command: V2ContactAliasUpdateCommand) throws -> V2ContactAliasUpdateReceipt {
        submissions += 1
        if behavior == .unknown { throw URLError(.networkConnectionLost) }
        if behavior == .conflict {
            return try .init(identity: command.identity, fingerprint: command.fingerprint, outcome: .rejected(.revisionConflict(current: .init(rawValue: 2))), resolvedAtMilliseconds: 1)
        }
        return try .init(identity: command.identity, fingerprint: command.fingerprint,
            outcome: .committed(.init(ownerUserID: command.ownerUserID, targetUserID: command.targetUserID, remarkName: command.remarkName,
                revision: .init(rawValue: (command.expectedRevision?.rawValue ?? 0) + 1)!)), resolvedAtMilliseconds: 1)
    }
    func submit(_ command: V2GroupNicknameUpdateCommand) throws -> V2GroupNicknameUpdateReceipt {
        submissions += 1
        if behavior == .unknown { throw URLError(.networkConnectionLost) }
        if behavior == .conflict {
            return try .init(identity: command.identity, fingerprint: command.fingerprint, outcome: .rejected(.revisionConflict(current: .init(rawValue: 2))), resolvedAtMilliseconds: 1)
        }
        return try .init(identity: command.identity, fingerprint: command.fingerprint,
            outcome: .committed(.init(roomID: command.roomID, userID: command.actorUserID, groupNickname: command.nickname,
                revision: .init(rawValue: (command.expectedRevision?.rawValue ?? 0) + 1)!)), resolvedAtMilliseconds: 1)
    }
    func recover(_ request: V2ContactAliasRecoveryRequest) -> V2ContactAliasRecoveryResult { .unresolved }
    func recover(_ request: V2GroupNicknameRecoveryRequest) -> V2GroupNicknameRecoveryResult { .unresolved }
}

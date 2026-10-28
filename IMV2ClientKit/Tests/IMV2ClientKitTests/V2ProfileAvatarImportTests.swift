import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Personal avatar import belongs to its profile change")
struct V2ProfileAvatarImportTests {
    @Test(arguments: [false, true])
    func retryRecoversTheOriginalCopyAfterItsResponseWasLost(reopen: Bool) async throws {
        let f = try Fixture(), source = try f.source(), intent = try await f.enqueue(source)
        try await f.store.pauseResourceImport(id: source.id, needsAttention: true)
        let first = V2ProfileIntentService(store: f.store, accountID: f.user, manager: try f.manager())
        #expect(try await first.prepareNextIntent())
        #expect(try await f.store.firstUnfinishedProfileIntent(accountID: f.user) == nil)
        let store: GRDBV2LocalSyncStore
        if reopen { try await f.store.close(); store = try f.reopen() }
        else { store = f.store }
        let service = V2ProfileIntentService(store: store, accountID: f.user, manager: try f.manager())
        #expect(try await store.resourceImportLocator(id: source.id) == .init(home: .account(f.user), operationID: source.request.operationID))
        let resumed = try await service.resumeOrReapply(intentID: intent.id)
        #expect(resumed.id == intent.id && resumed.operationID == intent.operationID)
        #expect(resumed.avatarImport == source)
        #expect(try await store.resourceImport(id: source.id)?.attempts == 0)
        #expect(try await store.firstUnfinishedProfileIntent(accountID: f.user)?.id == intent.id)
        // The server already copied the image. Recovering its result must bind
        // that exact target, with no second copy or replacement profile command.
        try await ready(source, store: store, user: f.user, until: Date().addingTimeInterval(100))
        #expect(try await service.prepareNextIntent())
        let frozen = try #require(try await store.profileIntent(id: intent.id))
        #expect(frozen.avatarImport == source && frozen.workID != nil)
        #expect(frozen.patch.avatar == .set(.init(mediaID: source.request.targetMediaID)))
        try await store.close(); try f.remove()
    }

    @Test func rejectedCopyStillRequiresAFreshImport() async throws {
        let f = try Fixture(), source = try f.source(), intent = try await f.enqueue(source)
        let status = try V2ResourceImportStatus(locator: .init(home: .account(f.user), operationID: source.request.operationID),
            mediaID: source.request.targetMediaID, state: .failed, bindableUntil: nil)
        try await f.store.databasePool.write { try GRDBV2LocalSyncStore.saveResourceImport(status, id: source.id, db: $0) }
        let service = V2ProfileIntentService(store: f.store, accountID: f.user, manager: try f.manager())
        #expect(try await service.prepareNextIntent())
        let replacement = try await service.resumeOrReapply(intentID: intent.id)
        #expect(replacement.id != intent.id)
        #expect(replacement.avatarImport?.request.operationID != source.request.operationID)
        #expect(replacement.avatarImport?.request.source == source.request.source)
        try await f.close()
    }

    @Test func submittedImportProfileConfirmsOriginalOperationAfterResourceExpiry() async throws {
        let f = try Fixture(), source = try f.source(), intent = try await f.enqueue(source)
        let executor = ImportProfileExecutor()
        let service = V2ProfileIntentService(store: f.store, accountID: f.user, manager: executor)
        try await ready(source, store: f.store, user: f.user, until: Date().addingTimeInterval(100))
        #expect(try await service.prepareNextIntent())
        let frozen = try #require(try await f.store.profileIntent(id: intent.id)), work = try #require(frozen.workID), owner = UUID()
        guard case .claimed(let submit) = try await f.store.claimOperationWork(id: work, ownerID: owner, action: .submit, now: Date()) else { Issue.record("No submission claim"); return }
        try await service.execute(submit)
        let waiting = try #require(try await f.store.operationWork(id: work))
        #expect(waiting.nextAction == .reconcile)
        try await ready(source, store: f.store, user: f.user, until: Date().addingTimeInterval(-1))
        guard case .claimed(let query) = try await f.store.claimOperationWork(id: work, ownerID: owner, action: .reconcile, now: waiting.nextActionAt) else { Issue.record("No result confirmation"); return }
        try await service.execute(query)
        #expect(try await f.store.operationWork(id: work)?.execution == .committed)
        #expect(await executor.submissions.map(\.operationID) == [intent.operationID])
        #expect(await executor.confirmations.map(\.operationID) == [intent.operationID])
        #expect(try await f.store.profileIntent(id: intent.id)?.avatarImport == source)
        #expect(try await f.store.resourceBusinessOwners(.init(transfer: .serverImport(source.id))).entries.isEmpty)
        try await f.store.pruneResourceTransferHistory(now: Date().addingTimeInterval(40 * 24 * 60 * 60))
        #expect(try await f.store.resourceImport(id: source.id) != nil)
        try await f.close()
    }

    @Test func admissionIsAtomicAndImportCannotBypassProfileDisposition() async throws {
        let f = try Fixture(), source = try f.source()
        let intent = try await f.enqueue(source)
        #expect(intent.workID == nil && intent.avatarImport == source && intent.avatarUpload == nil)
        #expect(try await f.store.resourceImport(id: source.id)?.request == source.request)
        let center = try await f.center()
        let owners = try await f.store.resourceBusinessOwners(.init(transfer: .serverImport(source.id)))
        #expect(owners.entries.map(\.owner) == [.profileIntent(intent.id)])
        try await f.store.requestImportCancellation(id: source.id)
        #expect(try await f.store.resourceImport(id: source.id)?.cancellationRequested == false)
        let plan = try await center.planProfileDisposition(transfer: .serverImport(source.id), intentID: intent.id)
        #expect(plan.intent.patch.displayName == .set("新昵称") && plan.effect == .withdrawUnsubmittedChange)
        try await center.commitProfileDisposition(plan)
        #expect(try await f.store.firstUnfinishedProfileIntent(accountID: f.user) == nil)
        #expect(try await f.store.resourceImport(id: source.id)?.cancellationRequested == true)
        await center.close(); try await f.close()
    }

    @Test func wrongAccountAdmissionRollsBackTheImportAndWrongUsageIsRejected() async throws {
        let f = try Fixture(), source = try f.source()
        await #expect(throws: V2OperationWorkError.accountMismatch) {
            try await f.store.enqueueProfileImportIntent(accountID: .init(uuid: UUID()), expectedRevision: .init(rawValue: 1)!, patch: .init(displayName: .set("名字")), source: source)
        }
        #expect(try await f.store.resourceImport(id: source.id) == nil)
        #expect(throws: V2OperationWorkError.invalidRecord) {
            try V2ProfileAvatarImport(id: UUID(), request: .init(operationID: .init(uuid: UUID()), source: source.request.source,
                targetUsage: .groupAvatar(.init(uuid: UUID())), targetMediaID: .init(uuid: UUID())))
        }
        try await f.close()
    }

    @Test func coldPreparationUsesOriginalOperationAndReadyImportWakesTheProfileQueue() async throws {
        let f = try Fixture(), source = try f.source(), now = Date()
        let intent = try await f.enqueue(source)
        let first = V2ProfileIntentService(store: f.store, accountID: f.user, manager: try f.manager())
        #expect(try await !first.prepareNextIntent(now: now))
        try await f.store.close()
        let restored = try f.reopen()
        let service = V2ProfileIntentService(store: restored, accountID: f.user, manager: try f.manager())
        try await ready(source, store: restored, user: f.user, until: now.addingTimeInterval(100))
        #expect(try await service.schedule().nextAttemptAt() == Date(timeIntervalSince1970: 0))
        #expect(try await service.prepareNextIntent())
        let frozen = try #require(try await restored.profileIntent(id: intent.id))
        #expect(frozen.operationID == intent.operationID && frozen.avatarImport == source && frozen.workID != nil)
        #expect(frozen.patch.avatar == .set(.init(mediaID: source.request.targetMediaID)))
        #expect(frozen.patch.displayName == .set("新昵称"))
        let center = try await makeResourceTestCenter(store: restored, root: f.root)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) {
            try await center.planProfileDisposition(transfer: .serverImport(source.id), intentID: intent.id)
        }
        await center.close(); try await restored.close(); try f.remove()
    }

    @Test(arguments: [false, true]) func expiredUnsubmittedImportReappliesWithNewTargetAndPreservesNickname(expiresAtFreeze: Bool) async throws {
        let f = try Fixture(), source = try f.source(), intent = try await f.enqueue(source)
        let service = V2ProfileIntentService(store: f.store, accountID: f.user, manager: try f.manager())
        try await ready(source, store: f.store, user: f.user, until: Date().addingTimeInterval(-1))
        // An earlier observation clock passes the readiness check, while the
        // final writer sees expiry. Both boundaries preserve the draft.
        #expect(try await service.prepareNextIntent(now: Date().addingTimeInterval(expiresAtFreeze ? -100 : 0)))
        #expect(try await f.store.profileIntent(id: intent.id)?.workID == nil)
        let replacement = try await service.resumeOrReapply(intentID: intent.id)
        let next = try #require(replacement.avatarImport)
        #expect(replacement.id != intent.id && replacement.operationID != intent.operationID)
        #expect(next.id != source.id && next.request.operationID != source.request.operationID && next.request.targetMediaID != source.request.targetMediaID)
        #expect(next.request.source == source.request.source && replacement.patch.displayName == .set("新昵称"))
        let owners = try await f.store.resourceBusinessOwners(.init(transfer: .serverImport(source.id)))
        #expect(owners.entries.isEmpty)
        try await f.close()
    }

    @Test func sharedImportStaysOwnedUntilAllProfileChangesAreDiscarded() async throws {
        let f = try Fixture(), source = try f.source()
        let first = try await f.enqueue(source), second = try await f.enqueue(source)
        #expect(try await f.store.resourceBusinessOwners(.init(transfer: .serverImport(source.id))).entries.count == 2)
        try await f.store.discardProfileIntentSource(id: first.id)
        #expect(try await f.store.resourceImport(id: source.id)?.cancellationRequested == false)
        try await f.store.discardProfileIntentSource(id: second.id)
        #expect(try await f.store.resourceImport(id: source.id)?.cancellationRequested == true)
        try await f.close()
    }

    private func ready(_ source: V2ProfileAvatarImport, store: GRDBV2LocalSyncStore, user: UserID, until: Date) async throws {
        let status = try V2ResourceImportStatus(locator: .init(home: .account(user), operationID: source.request.operationID),
            mediaID: source.request.targetMediaID, state: .ready, bindableUntil: until)
        try await store.databasePool.write { try GRDBV2LocalSyncStore.saveResourceImport(status, id: source.id, db: $0) }
    }
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "profile-avatar-import-\(UUID())")
        let user = UserID(uuid: UUID()), binding = V2LocalInstallationBinding(value: UUID())
        let store: GRDBV2LocalSyncStore
        init() throws { store = try .init(databaseURL: root.appending(path: "db.sqlite"), installationBinding: binding, userID: user) }
        func reopen() throws -> GRDBV2LocalSyncStore { try .init(databaseURL: root.appending(path: "db.sqlite"), installationBinding: binding, userID: user) }
        func source() throws -> V2ProfileAvatarImport {
            try .init(id: UUID(), request: .init(operationID: .init(uuid: UUID()), source: .message(location: .init(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil), targetUsage: .userAvatar, targetMediaID: .init(uuid: UUID())))
        }
        func enqueue(_ source: V2ProfileAvatarImport) async throws -> V2ProfileIntent {
            try await store.enqueueProfileImportIntent(accountID: user, expectedRevision: .init(rawValue: 1)!, patch: .init(displayName: .set("新昵称")), source: source)
        }
        func center() async throws -> V2ResourceCenter { try await makeResourceTestCenter(store: store, root: root) }
        func manager() throws -> ImportProfileManager {
            .init(profile: try .init(userID: user, publicIdentity: .init(userID: user, handle: .init("profile_import"), displayName: "名字", accountKind: .regular), avatar: nil, state: .active, revision: .init(rawValue: 2)!, visibilityRevision: .init(rawValue: 2)!))
        }
        func close() async throws { try await store.close(); try remove() }
        func remove() throws { try FileManager.default.removeItem(at: root) }
    }
}
private struct ImportProfileManager: V2OwnProfileManaging {
    let profile: V2ProfileView
    func currentProfile() async throws -> V2ProfileView { profile }
    func patchProfile(_ command: V2ProfileUpdateCommand) async throws -> V2ProfileUpdateResult { throw V2OwnProfileClientError.invalidRequest }
    func recoverProfile(_ request: V2ProfileOperationRecoveryRequest) async throws -> V2ProfileOperationRecoveryResult { throw V2OwnProfileClientError.invalidRequest }
}
private actor ImportProfileExecutor: V2OwnProfileManaging {
    private(set) var submissions: [V2ProfileUpdateCommand] = []
    private(set) var confirmations: [V2ProfileOperationRecoveryRequest] = []
    func currentProfile() throws -> V2ProfileView { throw V2OwnProfileClientError.invalidRequest }
    func patchProfile(_ command: V2ProfileUpdateCommand) throws -> V2ProfileUpdateResult {
        submissions.append(command)
        throw V2OwnProfileClientError.authorizationUnavailable
    }
    func recoverProfile(_ request: V2ProfileOperationRecoveryRequest) throws -> V2ProfileOperationRecoveryResult {
        confirmations.append(request)
        return .receipt(try .init(actorUserID: request.actorUserID, operationID: request.operationID, fingerprint: request.fingerprint,
            outcome: .committed(revision: .init(rawValue: 2)!, visibilityRevision: .init(rawValue: 2)!), resolvedAtMilliseconds: 1), currentSnapshot: nil)
    }
}

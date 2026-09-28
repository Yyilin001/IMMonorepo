import Foundation
import Testing
import IMV2Core
@testable import IMV2ClientKit

struct V2NameOperationTests {
    @Test func exhaustedRoundRetainsServerCooldownAcrossReopenAndExplicitContinue() async throws {
        let (store, user, url, binding) = try fixture()
        let cooldown = Date().addingTimeInterval(10_000)
        let remote = NameTestServer(commitBeforeFailure: false,
            failure: .init(kind: .httpStatus, service: "accountAPI", statusCode: 429, retryAfter: cooldown))
        let service = V2NameOperationService(accountID: user, store: store, client: remote)
        let id = try await service.save(.contact(.init("friend")), name: "pending", expectedRevision: nil)
        let initial = try #require(try await store.operationWork(id: id))
        try await service.execute(claim(initial, store: store))
        let paused = try #require(try await store.operationWork(id: id))
        #expect(paused.scheduling == .needsAttention)
        #expect(paused.execution == .awaitingConfirmation)
        #expect(paused.nextActionAt >= cooldown.addingTimeInterval(-0.001))
        try await store.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: user)
        let restored = V2NameOperationService(accountID: user, store: reopened, client: remote)
        try await restored.continueConfirmation(id: id)
        #expect(try await reopened.dueOperationWork(now: cooldown.addingTimeInterval(-1)).isEmpty)
        let resumed = try #require(try await reopened.operationWork(id: id))
        #expect(resumed.identity == initial.identity)
        #expect(resumed.nextAction == .reconcile)
        #expect(resumed.nextActionAt >= cooldown.addingTimeInterval(-0.001))
        #expect(await remote.submissions == 1)
        try await reopened.close()
    }
    private func fixture() throws -> (GRDBV2LocalSyncStore, UserID, URL, V2LocalInstallationBinding) {
        let user = try UserID("name-owner"), url = FileManager.default.temporaryDirectory.appending(path: "names-\(UUID()).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        return (try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: user), user, url, binding)
    }
    private func claim(_ work: V2OperationWork, store: GRDBV2LocalSyncStore) async throws -> V2OperationWorkClaim {
        guard case .claimed(let claim) = try await store.claimOperationWork(id: work.id, ownerID: UUID(), action: work.nextAction, now: work.nextActionAt) else { throw V2OperationWorkError.invalidTransition }
        return claim
    }
    @Test func retentionKeepsLatestNameOutcomeSoOlderFailedInputCannotReappear() async throws {
        let (store, user, _, _) = try fixture()
        let now = Date(), target = V2NameTarget.contact(try .init("friend"))
        var ids: [UUID] = []
        for index in 0..<3 {
            let id = try await store.enqueueNameOperation(accountID: user, target: target,
                name: "name-\(index)", expectedRevision: nil, now: now)
            ids.append(id)
            let work = try #require(try await store.operationWork(id: id))
            _ = try await claim(work, store: store)
            try await store.completeOperationWork(.init(identity: work.identity, fingerprint: work.fingerprint,
                state: index == 0 ? .conflicted : .committed, receipt: "retention-result"), now: now)
        }
        #expect(try await store.pruneCompletedOperationHistory(now: now.addingTimeInterval(8 * 24 * 60 * 60)) == 1)
        #expect(try await store.operationWork(id: ids[1]) == nil)
        #expect(try await store.operationWork(id: ids[0])?.execution == .conflicted)
        var updates = store.nameIntentUpdates(target: target).makeAsyncIterator()
        let latest = try await updates.next()
        #expect(latest??.id == ids[2])
        try await store.close()
    }
    @Test func lostAcknowledgementAndProcessRestartUseOriginalCommand() async throws {
        let (store, user, url, binding) = try fixture()
        let remote = NameTestServer()
        let service = V2NameOperationService(accountID: user, store: store, client: remote)
        let id = try await service.save(.contact(.init("friend")), name: "备注", expectedRevision: nil)
        let first = try #require(try await store.operationWork(id: id))
        try await service.execute(claim(first, store: store))
        let unknown = try #require(try await store.operationWork(id: id))
        #expect(unknown.execution == .awaitingConfirmation)
        #expect(unknown.nextAction == .reconcile)
        try await store.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: user)
        let resumed = V2NameOperationService(accountID: user, store: reopened, client: remote)
        try await resumed.execute(claim(unknown, store: reopened))
        #expect(try await reopened.operationWork(id: id)?.execution == .committed)
        #expect(try await reopened.nameSnapshot(target: .contact(.init("friend")))?.name == "备注")
        #expect(await remote.submissions == 1)
        #expect(await remote.queries == 1)
        try await reopened.close()
    }
    @Test func bothDomainsFreezeAndSameKeyCannotPassBackoff() async throws {
        let (store, user, _, _) = try fixture(), now = Date()
        let first = try await store.enqueueNameOperation(accountID: user, target: .group(.init("room")), name: "A", expectedRevision: nil, now: now)
        let second = try await store.enqueueNameOperation(accountID: user, target: .group(.init("room")), name: "B", expectedRevision: nil, now: now)
        let other = try await store.enqueueNameOperation(accountID: user, target: .contact(.init("friend")), name: "C", expectedRevision: nil, now: now)
        let work = try #require(try await store.operationWork(id: first))
        try await store.deferOperationWork(claim(work, store: store), until: now.addingTimeInterval(30), code: "TIMEOUT")
        let due = try await store.dueOperationWork(now: now)
        #expect(due.map(\.id) == [other])
        #expect(try await store.nameCommand(workID: second).0.name == "B")
        #expect(try await store.nameCommand(workID: second).0.revision == nil)
        try await store.close()
    }
    @Test func mismatchedCommittedValueAndVersionCannotFinishWork() async throws {
        let (store, user, _, _) = try fixture()
        let id = try await store.enqueueNameOperation(accountID: user, target: .group(.init("room")), name: "Expected", expectedRevision: nil)
        let work = try #require(try await store.operationWork(id: id))
        _ = try await claim(work, store: store)
        let command = try await store.nameCommand(workID: id).0
        for (name, revision) in [("Wrong", UInt64(1)), ("Expected", UInt64(2))] {
            let receipt = try V2GroupNicknameUpdateReceipt(identity: work.identity, fingerprint: work.fingerprint,
                outcome: .committed(.init(roomID: .init("room"), userID: user, groupNickname: name, revision: .init(rawValue: revision)!)), resolvedAtMilliseconds: 1)
            await #expect(throws: V2OperationWorkError.identityConflict) { try await store.completeNameOperation(command, receipt: .group(receipt)) }
        }
        #expect(try await store.operationWork(id: id)?.execution == .submitting)
        try await store.close()
    }
    @Test func closeDecisionPersistsAndNeverResubmitsUnresolvedIdentity() async throws {
        let (store, user, _, _) = try fixture()
        let remote = NameTestServer(commitBeforeFailure: false)
        let service = V2NameOperationService(accountID: user, store: store, client: remote)
        let id = try await service.save(.contact(.init("friend")), name: nil, expectedRevision: nil)
        try await service.execute(claim(try #require(try await store.operationWork(id: id)), store: store))
        try await service.discard(id: id)
        #expect(try await store.nameCommand(workID: id).1)
        try await service.execute(claim(try #require(try await store.operationWork(id: id)), store: store))
        #expect(try await store.operationWork(id: id)?.execution == .closed)
        #expect(await remote.submissions == 1)
        #expect(await remote.closes == 1)
        try await store.close()
    }
    @Test func newSnapshotDoesNotRegressAndEqualVersionMustAgree() async throws {
        let (store, user, _, _) = try fixture()
        let target = V2NameTarget.contact(try .init("friend"))
        try await store.saveNameSnapshot(.init(target: target, name: "B", revision: .init(rawValue: 2)), accountID: user)
        try await store.saveNameSnapshot(.init(target: target, name: "A", revision: .init(rawValue: 1)), accountID: user)
        #expect(try await store.nameSnapshot(target: target)?.name == "B")
        await #expect(throws: V2OperationWorkError.identityConflict) {
            try await store.saveNameSnapshot(.init(target: target, name: "Wrong", revision: .init(rawValue: 2)), accountID: user)
        }
        try await store.close()
    }
    @Test func localCancelRequiresNoSubmissionAndAccountQuotaIncludesNames() async throws {
        let (store, user, _, _) = try fixture()
        let id = try await store.enqueueNameOperation(accountID: user, target: .contact(.init("friend")), name: "A", expectedRevision: nil)
        await #expect(throws: V2OperationWorkError.capacityExceeded) {
            try await store.databasePool.read { db in try GRDBV2LocalSyncStore.requireOperationCapacity(adding: 1, limits: .init(maximumActiveCount: 1), db: db) }
        }
        try await store.requestNameOperationClose(id: id)
        #expect(try await store.operationWork(id: id)?.execution == .cancelledLocally)
        await #expect(throws: V2OperationWorkError.accountMismatch) {
            try await store.enqueueNameOperation(accountID: .init("other"), target: .contact(.init("friend")), name: "A", expectedRevision: nil)
        }
        try await store.close()
    }
}

private actor NameTestServer: V2NameOperationClient {
    var submissions = 0, queries = 0, closes = 0
    var receipt: V2ContactAliasUpdateReceipt?
    let commitBeforeFailure: Bool
    let failure: V2HTTPFailure?
    init(commitBeforeFailure: Bool = true, failure: V2HTTPFailure? = nil) {
        self.commitBeforeFailure = commitBeforeFailure; self.failure = failure
    }
    func contactSnapshot(owner: UserID, target: UserID) throws -> V2ContactAliasSnapshot { try .init(ownerUserID: owner, targetUserID: target, value: nil) }
    func groupSnapshot(actor: UserID, room: RoomID) throws -> V2GroupNicknameSnapshot { try .init(actorUserID: actor, roomID: room, value: nil) }
    func submit(_ command: V2ContactAliasUpdateCommand) throws -> V2ContactAliasUpdateReceipt {
        submissions += 1
        if let failure { throw failure }
        if commitBeforeFailure {
            receipt = try .init(identity: command.identity, fingerprint: command.fingerprint,
                outcome: .committed(.init(ownerUserID: command.ownerUserID, targetUserID: command.targetUserID, remarkName: command.remarkName,
                    revision: .init(rawValue: (command.expectedRevision?.rawValue ?? 0) + 1)!)), resolvedAtMilliseconds: 1)
        }
        throw URLError(.networkConnectionLost)
    }
    func submit(_ command: V2GroupNicknameUpdateCommand) throws -> V2GroupNicknameUpdateReceipt { throw URLError(.networkConnectionLost) }
    func recover(_ request: V2ContactAliasRecoveryRequest) throws -> V2ContactAliasRecoveryResult {
        queries += 1
        if let receipt { return .receipt(receipt) }
        if request.action == .closeIfAbsent {
            closes += 1
            return .receipt(try .init(identity: request.identity, fingerprint: request.fingerprint, outcome: .closed, resolvedAtMilliseconds: 1))
        }
        return .unresolved
    }
    func recover(_ request: V2GroupNicknameRecoveryRequest) -> V2GroupNicknameRecoveryResult { .unresolved }
}

import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Group avatar imports retain their exact business owner")
struct V2GroupAvatarImportTests {
    @Test func wrongTargetCannotLeaveAnOrphanImport() async throws {
        let f = try IntentFixture(), source = try request(f)
        for usage in [V2ResourceUsage.userAvatar, .groupAvatar(.init(uuid: UUID()))] {
            let id = UUID(), wrong = try V2ResourceImportRequest(operationID: .init(uuid: UUID()), source: source.source,
                targetUsage: usage, targetMediaID: .init(uuid: UUID()))
            await #expect(throws: V2GroupAvatarIntentError.conflict) {
                try await f.store.freezeGroupAvatarImportIntent(actorUserID: f.actor, command: f.command(media: wrong.targetMediaID), importJobID: id, request: wrong)
            }
            #expect(try await f.store.resourceImport(id: id) == nil)
        }
        try await f.store.close(); try f.removeFiles()
    }

    @Test func closedDecisionProtectsSharedImportUntilEveryConsumerLetsGo() async throws {
        let f = try IntentFixture(), id = UUID(), request = try request(f)
        let command = try f.command(media: request.targetMediaID)
        _ = try await f.store.freezeGroupAvatarImportIntent(actorUserID: f.actor, command: command, importJobID: id, request: request)
        // Query/closure may establish that an unsubmitted command is absent;
        // its pending import still belongs to the explicit user decision.
        try await f.store.requestGroupAvatarRecovery(command.operationID, action: .closeIfAbsent)
        let claim = try await f.store.claimGroupAvatarSubmission(command.operationID, now: f.now)
        let proof = try V2GroupAvatarRecoveryResponse(actorUserID: f.actor, deviceID: f.device,
            request: .init(command: command, action: .closeIfAbsent), result: .closed)
        try await f.store.finishGroupAvatarRecovery(claim, response: proof, now: f.now)
        let second = try f.command(media: request.targetMediaID, revision: 1)
        _ = try await f.store.freezeGroupAvatarImportIntent(actorUserID: f.actor, command: second, importJobID: id, request: request)
        #expect(try await f.store.resourceBusinessOwners(.init(transfer: .serverImport(id))).entries.count == 2)
        try await f.store.cancelGroupAvatarIntent(second.operationID)
        #expect(try await f.store.resourceImport(id: id)?.cancellationRequested == false)
        try await f.store.abandonClosedGroupAvatarIntent(command.operationID)
        #expect(try await f.store.resourceImport(id: id)?.cancellationRequested == true)
        try await f.store.close(); try f.removeFiles()
    }

    @Test func atomicAdmissionOwnerAndCancellationBoundary() async throws {
        let f = try IntentFixture(), id = UUID(), request = try request(f)
        let command = try f.command(media: request.targetMediaID)
        let intent = try await f.store.freezeGroupAvatarImportIntent(actorUserID: f.actor, command: command, importJobID: id, request: request)
        #expect(intent.preparation == .serverImport(id) && intent.uploadJobID == nil)
        #expect(try await f.store.freezeGroupAvatarImportIntent(actorUserID: f.actor, command: command, importJobID: id, request: request) == intent)
        let owners = try await f.store.resourceBusinessOwners(.init(transfer: .serverImport(id)))
        #expect(owners.entries.map(\.owner) == [.groupAvatar(f.room, command.operationID)])
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.hasBusinessOwners == true)
        try await f.store.requestManagedImportPause(id)
        #expect(try await f.store.resourcePreparationSchedule().nextAttemptAt() == nil)
        try await f.store.resumeManagedResourceTransfer(.serverImport(id))
        try await f.store.requestImportCancellation(id: id)
        #expect(try await f.store.resourceImport(id: id)?.cancellationRequested == false)
        let other = UUID(), conflicting = try self.request(f)
        await #expect(throws: V2GroupAvatarIntentError.conflict) {
            try await f.store.freezeGroupAvatarImportIntent(actorUserID: f.actor, command: f.command(media: conflicting.targetMediaID), importJobID: other, request: conflicting)
        }
        #expect(try await f.store.resourceImport(id: other) == nil)
        try await f.store.cancelGroupAvatarIntent(command.operationID)
        #expect(try await f.store.resourceImport(id: id)?.cancellationRequested == true)
        #expect(try await f.store.resourceBusinessOwners(.init(transfer: .serverImport(id))).entries.isEmpty)
        try await f.store.close(); try f.removeFiles()
    }

    @Test func coldOwnerWaitsForReadyThenSubmitsOriginalAvatarCommand() async throws {
        let f = try IntentFixture(), id = UUID(), request = try request(f)
        let command = try f.command(media: request.targetMediaID)
        _ = try await f.store.freezeGroupAvatarImportIntent(actorUserID: f.actor, command: command, importJobID: id, request: request)
        await #expect(throws: V2ResourceJournalError.dependencyNotReady) { try await f.store.claimGroupAvatarSubmission(command.operationID, now: f.now) }
        try await f.store.close()
        let restored = try f.reopen(), transfers = try await f.transfers(store: restored)
        let client = ImportAvatarSubmitter(response: try f.response(command))
        let engine = V2GroupAvatarIntentEngine(actorUserID: f.actor, store: restored, transfers: transfers, submissions: client, now: { f.now })
        #expect(try await engine.resume(command.operationID).stage == .preparing)
        #expect(await client.commands.isEmpty)
        try await ready(request, id: id, store: restored, until: f.now.addingTimeInterval(100))
        #expect(try await restored.dueGroupAvatarIntents(now: f.now).contains(command.operationID))
        let completed = try await engine.resume(command.operationID)
        #expect(completed.stage == .committed && completed.importJobID == id && completed.command == command)
        #expect(await client.commands == [command])
        try await restored.pruneResourceTransferHistory(now: Date().addingTimeInterval(40 * 24 * 60 * 60))
        #expect(try await restored.resourceImport(id: id) != nil)
        #expect(try await restored.groupAvatarIntent(command.operationID)?.importJobID == id)
        await engine.close(); await transfers.close(); try await restored.close(); try f.removeFiles()
    }

    @Test func expiredImportCannotSubmitButSubmittedOutcomeStillRecovers() async throws {
        let f = try IntentFixture(), id = UUID(), request = try request(f)
        let command = try f.command(media: request.targetMediaID)
        _ = try await f.store.freezeGroupAvatarImportIntent(actorUserID: f.actor, command: command, importJobID: id, request: request)
        try await ready(request, id: id, store: f.store, until: f.now.addingTimeInterval(-1))
        await #expect(throws: V2ResourceJournalError.bindingExpired) { try await f.store.claimGroupAvatarSubmission(command.operationID, now: f.now) }
        try await ready(request, id: id, store: f.store, until: f.now.addingTimeInterval(100))
        _ = try await f.store.claimGroupAvatarSubmission(command.operationID, now: f.now)
        try await f.store.requestGroupAvatarRecovery(command.operationID, action: .closeIfAbsent)
        let future = f.now.addingTimeInterval(200)
        let claim = try await f.store.claimGroupAvatarSubmission(command.operationID, now: future)
        let proof = try V2GroupAvatarRecoveryResponse(actorUserID: f.actor, deviceID: f.device,
            request: .init(command: command, action: .closeIfAbsent), result: .closed)
        try await f.store.finishGroupAvatarRecovery(claim, response: proof, now: future)
        #expect(try await f.store.groupAvatarIntent(command.operationID)?.stage == .closed)
        let replacement = try await f.store.replaceClosedGroupAvatarIntent(command.operationID, expectedRevision: 3, now: future)
        #expect(try await f.store.replaceClosedGroupAvatarIntent(command.operationID, expectedRevision: 3, now: future) == replacement)
        let next = try #require(try await f.store.groupAvatarIntent(replacement)), imported = try #require(next.importJobID)
        #expect(imported != id && next.uploadJobID == nil && next.command.mutation.mediaID != request.targetMediaID)
        let job = try #require(try await f.store.resourceImport(id: imported))
        #expect(job.request.source == request.source && job.request.targetUsage == request.targetUsage && job.request.operationID != request.operationID)
        #expect(next.command.mutation.mediaID == job.request.targetMediaID)
        try await f.store.close(); try f.removeFiles()
    }

    private func request(_ f: IntentFixture) throws -> V2ResourceImportRequest {
        try .init(operationID: .init(uuid: UUID()), source: .message(location: .init(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil),
            targetUsage: .groupAvatar(f.room), targetMediaID: .init(uuid: UUID()))
    }
    private func ready(_ request: V2ResourceImportRequest, id: UUID, store: GRDBV2LocalSyncStore, until: Date) async throws {
        let status = try V2ResourceImportStatus(locator: .init(home: request.targetUsage.home(actorUserID: try #require(try await store.boundAccountID())), operationID: request.operationID),
            mediaID: request.targetMediaID, state: .ready, bindableUntil: until)
        try await store.databasePool.write { try GRDBV2LocalSyncStore.saveResourceImport(status, id: id, db: $0) }
    }
}

private actor ImportAvatarSubmitter: V2GroupAvatarCommandSubmitting {
    let response: V2GroupAvatarCommandResponse
    private(set) var commands: [V2GroupAvatarCommand] = []
    init(response: V2GroupAvatarCommandResponse) { self.response = response }
    func submitGroupAvatar(_ command: V2GroupAvatarCommand) -> V2GroupAvatarCommandResponse { commands.append(command); return response }
}

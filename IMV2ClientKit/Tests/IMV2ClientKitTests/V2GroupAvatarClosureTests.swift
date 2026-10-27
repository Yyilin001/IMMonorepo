import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Permanent group avatar closure recovery")
struct V2GroupAvatarClosureTests {
    @Test("completed history cannot hide an old closed decision or an active operation")
    func pendingBeforeLimit() async throws {
        let f = try IntentFixture(), old = try f.command(media: nil)
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: old, uploadJobID: nil, now: f.now)
        try await f.store.requestGroupAvatarRecovery(old.operationID, action: .closeIfAbsent)
        let claim = try await f.store.claimGroupAvatarSubmission(old.operationID, now: f.now)
        try await f.store.finishGroupAvatarRecovery(claim, response: reply(f, old, .closeIfAbsent, .closed), now: f.now)
        for index in 1...20 {
            let done = try f.command(media: nil)
            _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: done, uploadJobID: nil, now: f.now.addingTimeInterval(Double(index)))
            try await f.store.cancelGroupAvatarIntent(done.operationID)
        }
        let active = try f.command(media: nil)
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: active, uploadJobID: nil, now: f.now.addingTimeInterval(100))
        #expect(try await f.store.groupAvatarIntents(in: f.room).allSatisfy { $0.id != old.operationID })
        #expect(try await f.store.pendingGroupAvatarIntents(in: f.room, limit: 1).map(\.id) == [active.operationID])
        #expect(try await f.store.pendingGroupAvatarOperations(actorUserID: f.actor, limit: 1).entries.map(\.id) == [old.operationID])
        try await f.store.cancelGroupAvatarIntent(active.operationID)
        #expect(try await f.store.pendingGroupAvatarIntents(in: f.room, limit: 1).map(\.id) == [old.operationID])
        try await f.store.abandonClosedGroupAvatarIntent(old.operationID)
        #expect(try await f.store.pendingGroupAvatarIntents(in: f.room).isEmpty)
        try await f.store.close(); try f.removeFiles()
    }

    @Test("an unresolved query cannot clear a newer claim or downgrade a requested closure")
    func staleQueries() async throws {
        let f = try IntentFixture(), command = try f.command(media: nil), id = command.operationID
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: nil)
        try await f.store.requestGroupAvatarRecovery(id, action: .query)
        let old = try await f.store.claimGroupAvatarSubmission(id, now: f.now)
        let newer = try await f.store.claimGroupAvatarSubmission(id, now: f.now.addingTimeInterval(31))
        try await f.store.finishGroupAvatarRecovery(old, response: reply(f, command, .query, .unresolved), now: f.now)
        #expect(try await f.store.groupAvatarIntent(id)?.recoveryAction == .query)
        await #expect(throws: V2GroupAvatarIntentError.busy) { _ = try await f.store.claimGroupAvatarSubmission(id, now: f.now.addingTimeInterval(32)) }
        try await f.store.requestGroupAvatarRecovery(id, action: .closeIfAbsent)
        try await f.store.requestGroupAvatarRecovery(id, action: .query)
        try await f.store.finishGroupAvatarRecovery(newer, response: reply(f, command, .query, .unresolved), now: f.now)
        let closing = try await f.store.claimGroupAvatarSubmission(id, now: f.now.addingTimeInterval(32))
        #expect(closing.intent.recoveryAction == .closeIfAbsent && closing.intent.attempts == 1)
        try await f.store.finishGroupAvatarRecovery(old, response: reply(f, command, .query, .unresolved), now: f.now)
        #expect(try await f.store.groupAvatarIntent(id)?.recoveryAction == .closeIfAbsent)
        try await f.store.finishGroupAvatarRecovery(closing, response: reply(f, command, .closeIfAbsent, .closed), now: f.now)
        #expect(try await f.store.groupAvatarIntent(id)?.stage == .closed)
        try await f.store.close(); try f.removeFiles()
    }

    @Test("absence alone preserves the original operation and its staging file")
    func unresolvedRetainsSource() async throws {
        let f = try IntentFixture(), job = try await f.upload(), command = try f.command(media: job.request.mediaID)
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: job.id)
        try await f.store.requestGroupAvatarRecovery(command.operationID, action: .query)
        let claim = try await f.store.claimGroupAvatarSubmission(command.operationID, now: f.now)
        try await f.store.finishGroupAvatarRecovery(claim, response: reply(f, command, .query, .unresolved), now: f.now)
        let pending = try #require(try await f.store.groupAvatarIntent(command.operationID))
        #expect(pending.command == command && pending.recoveryAction == nil && pending.stage == .submitted)
        #expect(pending.closureProof == nil && pending.retryAt > f.now)
        #expect(try await f.store.releasableResourceAssetID(id: job.id) == nil)
        await #expect(throws: V2GroupAvatarIntentError.conflict) { try await f.store.abandonClosedGroupAvatarIntent(command.operationID) }
        await #expect(throws: V2GroupAvatarIntentError.conflict) { _ = try await f.store.replaceClosedGroupAvatarIntent(command.operationID, expectedRevision: 1) }
        try await f.store.close(); try f.removeFiles()
    }

    @Test("closure is durable before I/O and resumes after restart without resubmitting the command")
    func recoveryAfterRestart() async throws {
        let f = try IntentFixture(), command = try f.command(media: nil), id = command.operationID
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: nil)
        try await f.store.requestGroupAvatarRecovery(id, action: .closeIfAbsent)
        let client = ClosureClient(reply: try reply(f, command, .closeIfAbsent, .closed))
        let transfers = try await f.transfers(), engine = V2GroupAvatarIntentEngine(actorUserID: f.actor, store: f.store,
            transfers: transfers, submissions: client, recovery: client)
        await #expect(throws: V2GroupAvatarSubmissionError.outcomeUnknown) { _ = try await engine.resume(id) }
        await engine.close(); await transfers.close(); try await f.store.close()
        let reopened = try f.reopen(), nextTransfers = try await f.transfers(store: reopened)
        let nextEngine = V2GroupAvatarIntentEngine(actorUserID: f.actor, store: reopened, transfers: nextTransfers,
            submissions: client, recovery: client, now: { f.now.addingTimeInterval(61) })
        try await nextEngine.recoverOnce()
        #expect(try await reopened.groupAvatarIntent(id)?.stage == .closed)
        #expect(await client.submissions == 0)
        #expect(await client.requests == Array(repeating: .init(command: command, action: .closeIfAbsent), count: 2))
        await nextEngine.close(); await nextTransfers.close(); try await reopened.close(); try f.removeFiles()
    }

    @Test("an in-flight submission yields to a closure on failure, while a late positive receipt still wins", arguments: [false, true])
    func submissionRace(commits: Bool) async throws {
        let f = try IntentFixture(), command = try f.command(media: nil), id = command.operationID
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: nil)
        let client = ClosureGatedClient(submission: try f.response(command), closure: try reply(f, command, .closeIfAbsent, .closed), commits: commits)
        let transfers = try await f.transfers(), engine = V2GroupAvatarIntentEngine(actorUserID: f.actor, store: f.store,
            transfers: transfers, submissions: client, recovery: client)
        let submission = Task { try await engine.resume(id) }
        await client.waitForSubmission()
        let closure = Task { try await engine.resolve(id, action: .closeIfAbsent) }
        // Observe the durable write-ahead boundary before allowing the old reply.
        for _ in 0..<1_000 {
            if try await f.store.groupAvatarIntent(id)?.recoveryAction == .closeIfAbsent { break }
            await Task.yield()
        }
        #expect(try await f.store.groupAvatarIntent(id)?.recoveryAction == .closeIfAbsent)
        await client.release()
        _ = await submission.result
        #expect(try await closure.value.stage == (commits ? .committed : .closed))
        #expect(await client.recoveries == (commits ? 0 : 1))
        await engine.close(); await transfers.close(); try await f.store.close(); try f.removeFiles()
    }

    @Test("closed proofs retain expired source files across restart until an explicit abandon decision")
    func abandonAfterRestart() async throws {
        let f = try IntentFixture(), job = try await f.upload(), command = try f.command(media: job.request.mediaID)
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: job.id)
        let proof = try await close(f, command)
        try await f.store.saveResourceSession(.init(locator: #require(job.session).locator, mediaID: job.request.mediaID,
            generation: 1, state: .expired, resourceState: .deleted, expiresAt: f.now), for: job.id)
        #expect(try await f.store.releasableResourceAssetID(id: job.id) == nil)
        #expect(try await f.store.testHeldAssetIDs().contains(job.localAssetID))
        try await f.store.close()
        let reopened = try f.reopen(), transfers = try await f.transfers(store: reopened)
        #expect(try await reopened.groupAvatarIntent(command.operationID)?.closureProof == proof)
        try await reopened.abandonClosedGroupAvatarIntent(command.operationID)
        try await reopened.abandonClosedGroupAvatarIntent(command.operationID)
        try await transfers.releaseFinishedSources()
        #expect(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent(job.localAssetID.value.uuidString).path))
        #expect(try await reopened.testHeldAssetIDs().isEmpty)
        #expect(try await reopened.groupAvatarIntent(command.operationID)?.closedDisposition == .abandoned)
        #expect(try await reopened.groupAvatarIntent(command.operationID)?.closureProof == proof)
        await transfers.close(); try await reopened.close(); try f.removeFiles()
    }

    @Test("replacement atomically allocates fresh identities and protects the shared file from old-job cleanup")
    func replacement() async throws {
        let f = try IntentFixture(), job = try await f.upload(), command = try f.command(media: job.request.mediaID)
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: job.id)
        let proof = try await close(f, command)
        var fillers: [(UUID, V2ResourceImportRequest)] = []
        for _ in 0..<32 {
            let id = UUID(), request = try V2ResourceImportRequest(operationID: .init(uuid: UUID()),
                source: .message(location: .init(roomID: f.room, messageID: .init(uuid: UUID())),
                    mediaID: .init(uuid: UUID()), variantID: nil),
                targetUsage: .messageAttachment(f.room), targetMediaID: .init(uuid: UUID()))
            try await f.store.prepareResourceImport(id: id, request: request)
            fillers.append((id, request))
        }
        await #expect(throws: V2ResourceJournalError.capacityExceeded) {
            _ = try await f.store.replaceClosedGroupAvatarIntent(command.operationID, expectedRevision: 7)
        }
        #expect(try await f.store.groupAvatarIntent(command.operationID)?.closedDisposition == .awaitingDecision)
        #expect(try await f.store.pendingGroupAvatarIntents(in: f.room).count == 1)
        let freed = fillers[0]
        try await f.store.seedResourceImportStatus(.init(locator: .init(home: .room(f.room), operationID: freed.1.operationID),
            mediaID: freed.1.targetMediaID, state: .cancelled, bindableUntil: nil), id: freed.0)
        let id = try await f.store.replaceClosedGroupAvatarIntent(command.operationID, expectedRevision: 7)
        #expect(try await f.store.replaceClosedGroupAvatarIntent(command.operationID, expectedRevision: 99) == id)
        let next = try #require(try await f.store.groupAvatarIntent(id))
        let nextJobID = try #require(next.uploadJobID)
        let nextJob = try #require(try await f.store.resourceTransfer(id: nextJobID))
        #expect(id != command.operationID && next.command.expectedRevision == 7)
        #expect(nextJob.id != job.id && nextJob.request.operationID != job.request.operationID)
        #expect(nextJob.request.mediaID != job.request.mediaID && next.command.mutation.mediaID == nextJob.request.mediaID)
        #expect(nextJob.request.usage == .groupAvatar(f.room) && nextJob.request.checksum == job.request.checksum)
        #expect(nextJob.localAssetID == job.localAssetID && nextJob.stage == .prepared)
        #expect(try await f.store.resourceTransfer(id: job.id)?.cancellationRequested == true)
        #expect(try await f.store.groupAvatarIntent(command.operationID)?.closureProof == proof)
        #expect(try await f.store.groupAvatarIntent(command.operationID)?.closedDisposition == .replaced)
        #expect(try await f.store.releasableResourceAssetID(id: job.id) == job.localAssetID)
        try await f.store.releaseResourceSource(id: job.id)
        #expect(try await f.store.testHeldAssetIDs().contains(nextJob.localAssetID))
        await #expect(throws: V2GroupAvatarIntentError.conflict) { try await f.store.abandonClosedGroupAvatarIntent(command.operationID) }
        try await f.store.close()
        let reopened = try f.reopen()
        #expect(try await reopened.groupAvatarIntent(id)?.command == next.command)
        #expect(try await reopened.replaceClosedGroupAvatarIntent(command.operationID, expectedRevision: 88) == id)
        try await reopened.close(); try f.removeFiles()
    }

    @Test("contradictory permanent receipts are rejected in either arrival order", arguments: [false, true])
    func contradictoryProofs(closesFirst: Bool) async throws {
        let f = try IntentFixture(), command = try f.command(media: nil), id = command.operationID
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: nil)
        let submission = try await f.store.claimGroupAvatarSubmission(id, now: f.now)
        try await f.store.requestGroupAvatarRecovery(id, action: .closeIfAbsent)
        try await f.store.failGroupAvatarSubmission(submission, issue: .outcomeUnknown, retryAt: f.now, attention: true)
        let recovery = try await f.store.claimGroupAvatarSubmission(id, now: f.now)
        let proof = try reply(f, command, .closeIfAbsent, .closed)
        if closesFirst {
            try await f.store.finishGroupAvatarRecovery(recovery, response: proof, now: f.now)
            await #expect(throws: V2GroupAvatarIntentError.conflict) { try await f.store.finishGroupAvatarSubmission(submission, response: f.response(command), now: f.now) }
        } else {
            try await f.store.finishGroupAvatarSubmission(submission, response: f.response(command), now: f.now)
            await #expect(throws: V2GroupAvatarIntentError.conflict) { try await f.store.finishGroupAvatarRecovery(recovery, response: proof, now: f.now) }
        }
        #expect(try await f.store.groupAvatarIntent(id)?.stage == (closesFirst ? .closed : .committed))
        try await f.store.close(); try f.removeFiles()
    }

    @Test("reopening the current journal preserves a frozen command and its active lease")
    func restartRetainsActiveClaim() async throws {
        let f = try IntentFixture(), command = try f.command(media: nil), id = command.operationID
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: nil)
        let claim = try await f.store.claimGroupAvatarSubmission(id, now: f.now)
        try await f.store.close()
        let reopened = try f.reopen()
        #expect(try await reopened.groupAvatarIntent(id)?.command == command)
        #expect(try await reopened.databasePool.read { try String.fetchOne($0, sql: "SELECT claim_id FROM v2_group_avatar_intents WHERE operation_id=?", arguments: [id.rawValue]) } == claim.id.uuidString)
        await #expect(throws: V2GroupAvatarIntentError.busy) { _ = try await reopened.claimGroupAvatarSubmission(id, now: f.now.addingTimeInterval(1)) }
        try await reopened.requestGroupAvatarRecovery(id, action: .closeIfAbsent)
        let next = try await reopened.claimGroupAvatarSubmission(id, now: f.now.addingTimeInterval(31))
        try await reopened.finishGroupAvatarRecovery(next, response: reply(f, command, .closeIfAbsent, .closed), now: f.now)
        #expect(try await reopened.groupAvatarIntent(id)?.stage == .closed)
        try await reopened.close(); try f.removeFiles()
    }

    private func reply(_ f: IntentFixture, _ command: V2GroupAvatarCommand, _ action: V2GroupAvatarRecoveryRequest.Action,
                       _ result: V2GroupAvatarRecoveryResult) throws -> V2GroupAvatarRecoveryResponse {
        try .init(actorUserID: f.actor, deviceID: f.device, request: .init(command: command, action: action), result: result)
    }
    private func close(_ f: IntentFixture, _ command: V2GroupAvatarCommand) async throws -> V2GroupAvatarRecoveryResponse {
        try await f.store.requestGroupAvatarRecovery(command.operationID, action: .closeIfAbsent)
        let claim = try await f.store.claimGroupAvatarSubmission(command.operationID, now: f.now)
        let proof = try reply(f, command, .closeIfAbsent, .closed)
        try await f.store.finishGroupAvatarRecovery(claim, response: proof, now: f.now)
        return proof
    }
}

private actor ClosureClient: V2GroupAvatarCommandSubmitting, V2GroupAvatarOperationRecovering {
    let reply: V2GroupAvatarRecoveryResponse
    var requests: [V2GroupAvatarRecoveryRequest] = [], submissions = 0
    init(reply: V2GroupAvatarRecoveryResponse) { self.reply = reply }
    func submitGroupAvatar(_ command: V2GroupAvatarCommand) throws -> V2GroupAvatarCommandResponse {
        submissions += 1; throw V2GroupAvatarSubmissionError.invalidResponse
    }
    func recoverGroupAvatar(_ request: V2GroupAvatarRecoveryRequest) throws -> V2GroupAvatarRecoveryResponse {
        requests.append(request)
        if requests.count == 1 { throw V2GroupAvatarSubmissionError.outcomeUnknown }
        return reply
    }
}

private actor ClosureGatedClient: V2GroupAvatarCommandSubmitting, V2GroupAvatarOperationRecovering {
    let submission: V2GroupAvatarCommandResponse, closure: V2GroupAvatarRecoveryResponse, commits: Bool
    var recoveries = 0
    private var arrived = false, released = false
    private var arrival: CheckedContinuation<Void, Never>?, waiter: CheckedContinuation<Void, Never>?
    init(submission: V2GroupAvatarCommandResponse, closure: V2GroupAvatarRecoveryResponse, commits: Bool) {
        self.submission = submission; self.closure = closure; self.commits = commits
    }
    func submitGroupAvatar(_ command: V2GroupAvatarCommand) async throws -> V2GroupAvatarCommandResponse {
        arrived = true; arrival?.resume(); arrival = nil
        if !released { await withCheckedContinuation { waiter = $0 } }
        if commits { return submission }; throw V2GroupAvatarSubmissionError.outcomeUnknown
    }
    func recoverGroupAvatar(_ request: V2GroupAvatarRecoveryRequest) -> V2GroupAvatarRecoveryResponse {
        recoveries += 1; return closure
    }
    func waitForSubmission() async { if !arrived { await withCheckedContinuation { arrival = $0 } } }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Group avatar recovery without user confirmation")
struct V2GroupAvatarAutomaticRecoveryTests {
    @Test(arguments: [false, true])
    func exhaustedSubmissionsAutomaticallyResolveTheOriginalCommand(committed: Bool) async throws {
        let f = try IntentFixture(), command = try f.command(media: nil)
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: nil)
        // Simulate a crash on the final allowed submission, then restart after
        // its lease. Recovery must not charge another business submission.
        for offset in 0..<5 {
            _ = try await f.store.claimGroupAvatarSubmission(command.operationID, now: f.now.addingTimeInterval(Double(offset * 31)))
        }
        try await f.store.close()
        let reopened = try f.reopen(), transfers = try await f.transfers(store: reopened)
        let result: V2GroupAvatarRecoveryResult
        if committed, case .committed(let receipt) = try f.response(command).outcome { result = .committed(receipt) }
        else { result = .closed }
        let client = AutomaticAvatarClient(actor: f.actor, device: f.device, result: result)
        // Foundation stores Date relative to 2001; the journal stores Unix
        // seconds. Exercise a value whose Unix round trip rounds upward so a
        // due database row is not rejected by a second Date-domain comparison.
        let instant = Date(timeIntervalSinceReferenceDate:
            floor(f.now.timeIntervalSinceReferenceDate + 156).nextUp.nextUp.nextUp)
        #expect(Date(timeIntervalSince1970: instant.timeIntervalSince1970) > instant)
        let engine = V2GroupAvatarIntentEngine(actorUserID: f.actor, store: reopened, transfers: transfers,
            submissions: client, recovery: client, now: { instant })
        try await engine.recoverOnce()
        let intent = try #require(try await reopened.groupAvatarIntent(command.operationID))
        #expect(intent.stage == (committed ? .committed : .closed))
        #expect(intent.command == command)
        #expect(await client.submissions == 0)
        #expect(await client.requests == [V2GroupAvatarRecoveryRequest(command: command, action: .closeIfAbsent)])
        await engine.close(); await transfers.close(); try await reopened.close(); try f.removeFiles()
    }

    @Test func recoveryBackoffSurvivesRestartAndRespectsServerCooldown() async throws {
        let f = try IntentFixture(), command = try f.command(media: nil)
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: nil)
        let claim = try await f.store.claimGroupAvatarSubmission(command.operationID, now: f.now)
        let cooldown = Date(timeIntervalSince1970: floor(f.now.timeIntervalSince1970) + 600)
        try await f.store.failGroupAvatarSubmission(claim, issue: .throttled, retryAt: cooldown, attention: true)
        #expect(try await f.store.resourcePreparationSchedule().nextAttemptAt() == cooldown)
        try await f.store.reconcileGroupAvatarRecovery(now: f.now)
        #expect(try await f.store.groupAvatarIntent(command.operationID)?.stage == .needsAttention)
        try await f.store.reconcileGroupAvatarRecovery(now: cooldown)
        let recovery = try await f.store.claimGroupAvatarSubmission(command.operationID, now: cooldown)
        #expect(recovery.intent.recoveryAction == .closeIfAbsent)
        try await f.store.failGroupAvatarSubmission(recovery, issue: .invalidResponse, retryAt: cooldown, attention: true)
        try await f.store.close()
        let reopened = try f.reopen()
        try await reopened.reconcileGroupAvatarRecovery(now: cooldown)
        let next = try #require(try await reopened.resourcePreparationSchedule().nextAttemptAt())
        #expect(next == cooldown.addingTimeInterval(60))
        #expect(try await reopened.dueGroupAvatarIntents(now: cooldown).isEmpty)
        #expect(try await reopened.dueGroupAvatarIntents(now: next) == [command.operationID])
        try await reopened.close(); try f.removeFiles()
    }

    @Test(arguments: [false, true])
    func departedGroupsFinishWithoutManualAbandonment(alreadyCommitted: Bool) async throws {
        let f = try IntentFixture(), job = try await f.upload(), command = try f.command(media: job.request.mediaID)
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: job.id)
        let claim = try await f.store.claimGroupAvatarSubmission(command.operationID, now: f.now)
        try await f.store.failGroupAvatarSubmission(claim, issue: .outcomeUnknown, retryAt: f.now, attention: true)
        try await revokeMembership(f)
        let result: V2GroupAvatarRecoveryResult
        if alreadyCommitted, case .committed(let receipt) = try f.response(command).outcome { result = .committed(receipt) }
        else { result = .closed }
        let client = AutomaticAvatarClient(actor: f.actor, device: f.device, result: result), transfers = try await f.transfers()
        let engine = V2GroupAvatarIntentEngine(actorUserID: f.actor, store: f.store, transfers: transfers,
            submissions: client, recovery: client)
        try await engine.recoverOnce()
        let intent = try #require(try await f.store.groupAvatarIntent(command.operationID))
        #expect(intent.stage == (alreadyCommitted ? .committed : .closed))
        if !alreadyCommitted { #expect(intent.closedDisposition == .abandoned && intent.closureProof != nil) }
        #expect(try await f.store.pendingGroupAvatarIntents(in: f.room).isEmpty)
        #expect(await client.submissions == 0)
        #expect(try await f.store.testHeldAssetIDs().isEmpty)
        await engine.close(); await transfers.close(); try await f.store.close(); try f.removeFiles()
    }

    @Test func departureCancelsUnsubmittedUploadsButMissingProjectionDoesNot() async throws {
        let f = try IntentFixture(), job = try await f.upload(ready: false), command = try f.command(media: job.request.mediaID)
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: job.id)
        try await f.store.reconcileGroupAvatarRecovery(now: f.now)
        #expect(try await f.store.groupAvatarIntent(command.operationID)?.stage == .preparing)
        try await revokeMembership(f)
        #expect(try await f.store.resourcePreparationSchedule().nextAttemptAt() != nil)
        try await f.store.reconcileGroupAvatarRecovery(now: f.now)
        #expect(try await f.store.groupAvatarIntent(command.operationID)?.stage == .cancelled)
        #expect(try await f.store.resourceTransfer(id: job.id)?.cancellationRequested == true)
        try await f.store.close(); try f.removeFiles()
    }

    private func revokeMembership(_ f: IntentFixture) async throws {
        try await f.store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_room_membership_states(room_id,membership_revision,source_event_id,is_member) VALUES(?,1,?,0)",
                arguments: [f.room.rawValue, UUID().uuidString])
        }
    }
}

private actor AutomaticAvatarClient: V2GroupAvatarCommandSubmitting, V2GroupAvatarOperationRecovering {
    let actor: UserID
    let device: DeviceID
    let result: V2GroupAvatarRecoveryResult
    private(set) var submissions = 0
    private(set) var requests: [V2GroupAvatarRecoveryRequest] = []
    init(actor: UserID, device: DeviceID, result: V2GroupAvatarRecoveryResult) {
        self.actor = actor; self.device = device; self.result = result
    }
    func submitGroupAvatar(_ command: V2GroupAvatarCommand) throws -> V2GroupAvatarCommandResponse {
        submissions += 1
        throw V2GroupAvatarSubmissionError.outcomeUnknown
    }
    func recoverGroupAvatar(_ request: V2GroupAvatarRecoveryRequest) throws -> V2GroupAvatarRecoveryResponse {
        requests.append(request)
        return try .init(actorUserID: actor, deviceID: device, request: request, result: result)
    }
}

import Foundation
import GRDB
import IMV2Core
import Synchronization
import Testing
@testable import IMV2ClientKit

@Suite("Durable group avatar management intents")
struct V2GroupAvatarIntentTests {
    @Test("initial upload and group intent commit together, including conflict rollback")
    func atomicPreparation() async throws {
        let f = try IntentFixture(), jobID = UUID()
        let upload = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()),
            usage: .groupAvatar(f.room), contentType: "image/png", byteCount: 3, checksum: .init(value: String(repeating: "a", count: 64)))
        let command = try f.command(media: upload.mediaID)
        let value = try await f.store.freezeMetadataGroupAvatarUploadIntent(actorUserID: f.actor, command: command,
            uploadJobID: jobID, request: upload, localAssetID: .init(jobID))
        #expect(value.uploadJobID == jobID)
        #expect(try await f.store.freezeMetadataGroupAvatarUploadIntent(actorUserID: f.actor, command: command,
            uploadJobID: jobID, request: upload, localAssetID: .init(jobID)) == value)
        let other = UUID(), conflicting = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()),
            usage: .groupAvatar(f.room), contentType: "image/png", byteCount: 3, checksum: upload.checksum)
        await #expect(throws: V2GroupAvatarIntentError.conflict) {
            _ = try await f.store.freezeMetadataGroupAvatarUploadIntent(actorUserID: f.actor, command: f.command(media: conflicting.mediaID),
                uploadJobID: other, request: conflicting, localAssetID: .init(other))
        }
        #expect(try await f.store.resourceTransfer(id: other) == nil)
        #expect(try await f.store.pendingGroupAvatarIntents(in: f.room) == [value])
        try await f.store.close(); try f.removeFiles()
    }

    @Test("local management retries do not invalidate display leases; committed room events do")
    func projectionScope() async throws {
        let f = try IntentFixture(), command = try f.command(media: nil)
        let changes = await f.store.projectionChanges()
        _ = changes.hub.take(changes.identifier)
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: nil)
        let preparation = try #require(changes.hub.take(changes.identifier))
        #expect(preparation.scopes.contains(.conversationDetails) && !preparation.scopes.contains(.presentations))
        _ = try await f.store.claimGroupAvatarSubmission(command.operationID, now: f.now)
        let submission = try #require(changes.hub.take(changes.identifier))
        #expect(!submission.scopes.contains(.presentations))
        let event = try V2LocalGroupAvatarEffect(sourceEventID: .init(uuid: UUID()), roomID: f.room,
            revision: 1, roomSequence: 1, updatedAtMilliseconds: Int64(f.now.timeIntervalSince1970 * 1_000))
        try await f.store.databasePool.write { try GRDBV2LocalSyncStore.applyGroupAvatarInvalidation(event, db: $0) }
        #expect(changes.hub.take(changes.identifier)?.scopes.contains(.presentations) == true)
        try await f.store.close(); try f.removeFiles()
    }

    @Test("frozen commands survive restart, reject substitution and keep an unknown result after resource expiry")
    func restartAndExpiry() async throws {
        let f = try IntentFixture(), job = try await f.upload()
        let command = try f.command(media: job.request.mediaID)
        let saved = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: job.id)
        #expect(try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: job.id) == saved)
        await #expect(throws: V2GroupAvatarIntentError.conflict) {
            _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: f.command(media: job.request.mediaID), uploadJobID: job.id)
        }
        await #expect(throws: V2GroupAvatarIntentError.accountMismatch) {
            _ = try await f.store.freezeGroupAvatarIntent(actorUserID: .init(uuid: UUID()), command: command, uploadJobID: job.id)
        }
        let claim = try await f.store.claimGroupAvatarSubmission(command.operationID, now: f.now)
        await #expect(throws: V2GroupAvatarIntentError.alreadySubmitted) { try await f.store.cancelGroupAvatarIntent(command.operationID) }
        #expect(try await f.store.requestResourceCancellation(id: job.id) == nil)
        try await f.store.close()
        let reopened = try f.reopen()
        let expired = try V2ResourceUploadSession(locator: #require(job.session).locator, mediaID: job.request.mediaID,
            generation: 1, state: .expired, resourceState: .deleted, expiresAt: f.now)
        try await reopened.saveResourceSession(expired, for: job.id)
        #expect(try await reopened.testHeldAssetIDs().contains(job.localAssetID))
        await #expect(throws: V2GroupAvatarIntentError.busy) {
            _ = try await reopened.claimGroupAvatarSubmission(command.operationID, now: f.now.addingTimeInterval(10))
        }
        let retry = try await reopened.claimGroupAvatarSubmission(command.operationID, now: f.now.addingTimeInterval(31))
        #expect(retry.intent.command == command && retry.id != claim.id)
        try await reopened.finishGroupAvatarSubmission(retry, response: f.response(command), now: f.now)
        #expect(try await reopened.groupAvatarIntent(command.operationID)?.stage == .committed)
        #expect(try await reopened.releasableResourceAssetID(id: job.id) == job.localAssetID)
        #expect(try await reopened.resourceSendPayloads().isEmpty)
        try await reopened.close(); try f.removeFiles()
    }

    @Test("stale claims cannot replace a receipt or a newer attempt with a failure")
    func claimFencing() async throws {
        let f = try IntentFixture(), command = try f.command(media: nil)
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: nil)
        let first = try await f.store.claimGroupAvatarSubmission(command.operationID, now: f.now)
        let newer = try await f.store.claimGroupAvatarSubmission(command.operationID, now: f.now.addingTimeInterval(31))
        try await f.store.failGroupAvatarSubmission(first, issue: .forbidden, retryAt: f.now, attention: true)
        #expect(try await f.store.groupAvatarIntent(command.operationID)?.stage == .submitted)
        try await f.store.finishGroupAvatarSubmission(first, response: f.response(command), now: f.now)
        try await f.store.failGroupAvatarSubmission(newer, issue: .outcomeUnknown, retryAt: f.now, attention: false)
        #expect(try await f.store.groupAvatarIntent(command.operationID)?.stage == .committed)
        let differentReceipt = try V2GroupAvatarCommandResponse(actorUserID: f.actor, deviceID: f.device, command: command,
            outcome: .committed(.init(state: .init(roomID: f.room, mediaID: nil, revision: 1), roomSequence: 2, updatedAt: f.now)))
        await #expect(throws: V2GroupAvatarIntentError.conflict) {
            try await f.store.finishGroupAvatarSubmission(first, response: differentReceipt, now: f.now)
        }
        try await f.store.close(); try f.removeFiles()
    }

    @Test("a crash at the retry limit cannot reset the automatic attempt budget")
    func exhaustedClaim() async throws {
        let f = try IntentFixture(), command = try f.command(media: nil)
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: nil)
        for offset in 0..<5 {
            _ = try await f.store.claimGroupAvatarSubmission(command.operationID, now: f.now.addingTimeInterval(Double(offset * 31)))
        }
        try await f.store.close()
        let reopened = try f.reopen()
        #expect(try await reopened.dueGroupAvatarIntents(now: f.now.addingTimeInterval(156)).isEmpty)
        #expect(try await reopened.groupAvatarIntent(command.operationID)?.stage == .needsAttention)
        #expect(try await reopened.groupAvatarIntent(command.operationID)?.attempts == 5)
        try await reopened.close(); try f.removeFiles()
    }

    @Test("upload dependencies must match the room, purpose and media of the frozen command",
          arguments: ["room", "purpose", "media"])
    func dependencyIdentity(field: String) async throws {
        let f = try IntentFixture()
        let usage: V2ResourceUsage = field == "room" ? .groupAvatar(.init(uuid: UUID()))
            : field == "purpose" ? .messageAttachment(f.room) : .groupAvatar(f.room)
        let job = try await f.upload(usage: usage)
        let command = try f.command(media: field == "media" ? .init(uuid: UUID()) : job.request.mediaID)
        await #expect(throws: V2GroupAvatarIntentError.conflict) {
            _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: job.id)
        }
        #expect(try await f.store.groupAvatarIntents(in: f.room).isEmpty)
        try await f.store.close(); try f.removeFiles()
    }

    @Test("cancelling preparation persists upload cleanup and prevents a late handoff")
    func cancelPreparation() async throws {
        let f = try IntentFixture(), job = try await f.upload(ready: false)
        let command = try f.command(media: job.request.mediaID)
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: job.id)
        await #expect(throws: V2ResourceJournalError.dependencyNotReady) {
            _ = try await f.store.claimGroupAvatarSubmission(command.operationID, now: f.now)
        }
        try await f.store.cancelGroupAvatarIntent(command.operationID)
        #expect(try await f.store.pendingResourceCancellations() == [job.id])
        #expect(try await f.store.groupAvatarIntent(command.operationID)?.stage == .cancelled)
        await #expect(throws: V2GroupAvatarIntentError.conflict) {
            _ = try await f.store.claimGroupAvatarSubmission(command.operationID, now: f.now)
        }
        try await f.store.close(); try f.removeFiles()
    }

    @Test("releasing one upload claim cannot release another consumer of the same physical bytes")
    func sharedStaging() async throws {
        let f = try IntentFixture()
        let resources = try await makeResourceTestCenter(store: f.store, root: f.directory)
        let source = f.directory.appending(path: "shared.png"); try Data([1,2,3]).write(to: source)
        func upload(_ usage: V2ResourceUsage, purpose: V2LocalResourceAssetPurpose) async throws -> V2ResourceTransferJob {
            let asset = try await resources.importLocal(at: source, displayName: .init("shared.png"), contentType: .init("image/png"), purpose: purpose)
            let id = UUID()
            let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()), usage: usage,
                contentType: asset.contentType.value, byteCount: asset.byteCount, checksum: asset.checksum, displayName: asset.displayName)
            _ = try await f.store.prepareResourceTransfer(id: id, request: request, localAssetID: asset.id, now: f.now)
            try await f.store.saveResourceSession(.init(locator: .init(home: .room(f.room), sessionID: .init(uuid: UUID())),
                mediaID: request.mediaID, generation: 1, state: .completed, resourceState: .ready,
                expiresAt: f.now.addingTimeInterval(100), bindableUntil: f.now.addingTimeInterval(100)), for: id)
            return try #require(try await f.store.resourceTransfer(id: id))
        }
        let groupJob = try await upload(.groupAvatar(f.room), purpose: .groupAvatar(f.room))
        let messageJob = try await upload(.messageAttachment(f.room), purpose: .messageDraft(f.room))
        let command = try f.command(media: groupJob.request.mediaID)
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: groupJob.id)
        let message = try V2SendIntent(id: UUID(), roomID: f.room, clientMessageID: .init(uuid: UUID()), text: "shared source", attachmentJobIDs: [messageJob.id])
        try await f.store.freezeMetadataSendIntent(message)
        _ = try await f.store.handOffSendIntent(message.id, now: f.now)
        let claim = try await f.store.claimGroupAvatarSubmission(command.operationID, now: f.now)
        try await f.store.finishGroupAvatarSubmission(claim, response: f.response(command), now: f.now)
        #expect(try await f.store.releasableResourceAssetID(id: groupJob.id) == groupJob.localAssetID)
        try await f.store.releaseResourceSource(id: groupJob.id)
        let file = try #require(try await f.store.resourceFileJournal().localAsset(groupJob.localAssetID)?.fileID)
        #expect(try await f.store.resourceFileJournal().record(file)?.retention == .original)
        #expect(try await f.store.releasableResourceAssetID(id: messageJob.id) == nil)
        try await f.store.completeResourceSendFixture(message.clientMessageID, result: .accepted(.init(messageID: .init(uuid: UUID()), roomSequence: 1)))
        try await f.store.releaseResourceSource(id: messageJob.id)
        await #expect(throws: V2GroupAvatarIntentError.conflict) {
            _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: f.command(media: groupJob.request.mediaID, revision: 1), uploadJobID: groupJob.id)
        }
        let lateMessage = try V2SendIntent(id: UUID(), roomID: f.room, clientMessageID: .init(uuid: UUID()), text: "late", attachmentJobIDs: [messageJob.id])
        await #expect(throws: V2ResourceJournalError.conflict) { try await f.store.freezeMetadataSendIntent(lateMessage) }
        await #expect(throws: V2ResourceStorageError.unavailable) {
            let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()), usage: groupJob.request.usage,
                contentType: groupJob.request.contentType, byteCount: groupJob.request.byteCount, checksum: groupJob.request.checksum, displayName: groupJob.request.displayName)
            _ = try await f.store.prepareResourceTransfer(id: UUID(), request: request, localAssetID: groupJob.localAssetID)
        }
        await resources.close(); try await f.store.close()
        let reopened = try f.reopen(), restoredResources = try await makeResourceTestCenter(store: reopened, root: f.directory)
        let transfers = V2ResourceTransferEngine(store: reopened, control: IntentForbiddenTransfer(), executor: IntentForbiddenTransfer(), resources: restoredResources)
        try await transfers.releaseFinishedSources()
        #expect(try await reopened.releasableResourceJobs().isEmpty)
        #expect(try await reopened.testHeldAssetIDs().isEmpty)
        #expect(try await reopened.resourceFileJournal().record(file)?.retention == .cache)
        #expect(try await reopened.resourceFileJournal().record(file)?.storage == .cache)
        await transfers.close(); await restoredResources.close(); try await reopened.close(); try f.removeFiles()
    }

    @Test("unknown sends back off, stop automatic retries, and preserve the same command on explicit retry")
    func boundedRecovery() async throws {
        let f = try IntentFixture(), command = try f.command(media: nil), clock = IntentClock(fixed: Date())
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: nil)
        let client = IntentSubmitter(reply: try f.response(command), failure: .outcomeUnknown)
        let transfers = try await f.transfers()
        let engine = V2GroupAvatarIntentEngine(actorUserID: f.actor, store: f.store, transfers: transfers, submissions: client, now: { clock.now })
        for _ in 0..<5 { try await engine.recoverOnce(); clock.advance(61) }
        #expect(await client.commands.count == 5)
        let pending = try #require(try await f.store.groupAvatarIntent(command.operationID))
        #expect(pending.stage == .needsAttention && pending.submissionStarted && !pending.canCancel)
        try await engine.recoverOnce()
        #expect(await client.commands.count == 5)
        await client.succeed()
        #expect(try await engine.retry(command.operationID).stage == .committed)
        #expect(await client.commands == Array(repeating: command, count: 6))
        await engine.close(); await transfers.close(); try await f.store.close(); try f.removeFiles()
    }

    @Test("page cancellation only removes that waiter while the shared operation commits")
    func independentWaiters() async throws {
        let f = try IntentFixture(), command = try f.command(media: nil)
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: nil)
        let client = IntentGatedSubmitter(reply: try f.response(command)), transfers = try await f.transfers()
        let engine = V2GroupAvatarIntentEngine(actorUserID: f.actor, store: f.store, transfers: transfers, submissions: client)
        let first = Task { try await engine.resume(command.operationID) }
        await client.waitUntilArrived()
        first.cancel()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        let second = Task { try await engine.resume(command.operationID) }
        await client.release()
        #expect(try await second.value.stage == .committed)
        #expect(await client.count == 1)
        await engine.close(); await transfers.close(); try await f.store.close(); try f.removeFiles()
    }

    @Test func coldStartUserRetryAndClosureDoNotEraseServerCooldown() async throws {
        let f = try IntentFixture(), command = try f.command(media: nil)
        let cooldown = Date(timeIntervalSince1970: floor(f.now.timeIntervalSince1970)+10000)
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: nil)
        let claim = try await f.store.claimGroupAvatarSubmission(command.operationID, now: f.now)
        try await f.store.failGroupAvatarSubmission(claim, issue: .throttled, retryAt: cooldown, attention: true)
        let reopened = try f.reopen()
        try await reopened.retryGroupAvatarIntent(command.operationID)
        #expect(try await reopened.groupAvatarIntent(command.operationID)?.retryAt == cooldown)
        try await reopened.requestGroupAvatarRecovery(command.operationID, action: .closeIfAbsent)
        #expect(try await reopened.groupAvatarIntent(command.operationID)?.retryAt == cooldown)
        #expect(try await reopened.dueGroupAvatarIntents(now: f.now.addingTimeInterval(100)).isEmpty)
        try await reopened.close(); try await f.store.close(); try f.removeFiles()
    }

    @Test("snapshot replacement preserves unresolved management commands even when the room disappears")
    func snapshotKeepsIntent() async throws {
        let f = try IntentFixture(), command = try f.command(media: nil)
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: nil)
        _ = try await f.store.claimGroupAvatarSubmission(command.operationID, now: f.now)
        let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        let snapshot = try makeSnapshotFixture(reset: reset, pages: [])
        try await f.store.beginReset(reset)
        try await f.store.beginSnapshotImport(snapshot.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
        try await f.store.prepareSnapshotActivation(snapshot.manifest)
        try await f.store.activateAcknowledgedSnapshot(snapshot.manifest)
        #expect(try await f.store.groupAvatarIntent(command.operationID)?.command == command)
        #expect(try await f.store.groupAvatarIntent(command.operationID)?.submissionStarted == true)
        #expect(try await f.store.pendingGroupAvatarOperations(actorUserID: f.actor).entries.map(\.id) == [command.operationID])
        try await f.store.close()
        let reopened = try f.reopen()
        #expect(try await reopened.pendingGroupAvatarOperations(actorUserID: f.actor).entries.map(\.id) == [command.operationID])
        try await reopened.close(); try f.removeFiles()
    }
}

struct IntentFixture {
    let directory: URL, store: GRDBV2LocalSyncStore
    let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID())
    let binding = V2LocalInstallationBinding(value: UUID()), now = Date()
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("group-avatar-intent-\(UUID())")
        store = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("db.sqlite"), installationBinding: binding, userID: actor)
    }
    func reopen() throws -> GRDBV2LocalSyncStore {
        try .init(databaseURL: directory.appendingPathComponent("db.sqlite"), installationBinding: binding, userID: actor)
    }
    func removeFiles() throws { try FileManager.default.removeItem(at: directory) }
    func command(media: MediaID?, revision: UInt64 = 0) throws -> V2GroupAvatarCommand {
        try .init(operationID: .init(uuid: UUID()), roomID: room, expectedRevision: revision, mutation: media.map { .set($0) } ?? .remove)
    }
    func request(usage: V2ResourceUsage) throws -> V2ResourceUploadRequest {
        try .init(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()), usage: usage,
            contentType: "image/png", byteCount: 3, checksum: .init(value: String(repeating: "a", count: 64)))
    }
    func upload(ready: Bool = true, usage: V2ResourceUsage? = nil, token: V2LocalResourceAssetID? = nil) async throws -> V2ResourceTransferJob {
        let id = UUID(), request = try request(usage: usage ?? .groupAvatar(room)), token = token ?? V2LocalResourceAssetID()
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent(token.value.uuidString))
        _ = try await store.prepareMetadataResourceTransfer(id: id, request: request, localAssetID: token, now: now)
        if ready {
            try await store.saveResourceSession(.init(locator: .init(home: request.usage.home(actorUserID: actor), sessionID: .init(uuid: UUID())),
                mediaID: request.mediaID, generation: 1, state: .completed, resourceState: .ready,
                expiresAt: now.addingTimeInterval(100), bindableUntil: now.addingTimeInterval(100)), for: id)
        }
        return try #require(try await store.resourceTransfer(id: id))
    }
    func response(_ command: V2GroupAvatarCommand) throws -> V2GroupAvatarCommandResponse {
        try .init(actorUserID: actor, deviceID: device, command: command,
            outcome: .committed(.init(state: .init(roomID: room, mediaID: command.mutation.mediaID,
                revision: command.expectedRevision + 1), roomSequence: 1, updatedAt: now)))
    }
    func transfers(store: GRDBV2LocalSyncStore? = nil) async throws -> V2ResourceTransferEngine {
        let selectedStore = store ?? self.store
        return .init(store: selectedStore, control: IntentForbiddenTransfer(), executor: IntentForbiddenTransfer(), resources: try await makeResourceTestCenter(store: selectedStore, root: directory))
    }
}
private struct IntentForbiddenTransfer: V2ResourceUploadControlling, V2ResourcePlanExecuting {
    func create(_ request: V2ResourceUploadRequest) async throws -> V2ResourceUploadSession { throw V2ResourceJournalError.invalidRecord }
    func status(_ locator: V2ResourceUploadLocator) async throws -> V2ResourceUploadSession { throw V2ResourceJournalError.invalidRecord }
    func target(_ session: V2ResourceUploadSession) async throws -> V2ResourceTransferPlan? { throw V2ResourceJournalError.invalidRecord }
    func finalize(_ session: V2ResourceUploadSession) async throws -> V2ResourceUploadSession { throw V2ResourceJournalError.invalidRecord }
    func cancel(_ session: V2ResourceUploadSession) async throws -> V2ResourceUploadSession { throw V2ResourceJournalError.invalidRecord }
    func upload(fileURL: URL, plan: V2ResourceTransferPlan) async throws { throw V2ResourceJournalError.invalidRecord }
}
private final class IntentClock: Sendable {
    let value: Mutex<Date>
    init(fixed: Date) { value = Mutex(fixed) }
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}
private actor IntentSubmitter: V2GroupAvatarCommandSubmitting {
    let reply: V2GroupAvatarCommandResponse
    var failure: V2GroupAvatarSubmissionError?
    var commands: [V2GroupAvatarCommand] = []
    init(reply: V2GroupAvatarCommandResponse, failure: V2GroupAvatarSubmissionError? = nil) { self.reply = reply; self.failure = failure }
    func succeed() { failure = nil }
    func submitGroupAvatar(_ command: V2GroupAvatarCommand) throws -> V2GroupAvatarCommandResponse {
        commands.append(command)
        if let failure { throw failure }; return reply
    }
}
private actor IntentGatedSubmitter: V2GroupAvatarCommandSubmitting {
    let reply: V2GroupAvatarCommandResponse
    var count = 0
    private var arrived = false, released = false
    private var arrival: CheckedContinuation<Void, Never>?, waiter: CheckedContinuation<Void, Never>?
    init(reply: V2GroupAvatarCommandResponse) { self.reply = reply }
    func submitGroupAvatar(_ command: V2GroupAvatarCommand) async -> V2GroupAvatarCommandResponse {
        count += 1; arrived = true; arrival?.resume(); arrival = nil
        if !released { await withCheckedContinuation { waiter = $0 } }
        return reply
    }
    func waitUntilArrived() async { if !arrived { await withCheckedContinuation { arrival = $0 } } }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

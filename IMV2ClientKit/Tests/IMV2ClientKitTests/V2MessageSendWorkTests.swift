import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Message send public work", .serialized)
struct V2MessageSendWorkTests {
    @Test(arguments: ["negative", "expired", "unknown"])
    func provenUnsentDispositionPreservesUnknownIdentity(_ scenario: String) async throws {
        let f = try SendWorkFixture(); defer { f.remove() }
        let intent = try f.intent("retained proposal")
        try await f.store.freezeSendIntent(intent, now: scenario == "expired" ? Date().addingTimeInterval(-90_000) : Date())
        try await f.store.handOffSendIntent(intent.id)
        let work = try await f.head(), original = try await f.store.messageSendCommand(workID: work.id)
        if scenario == "expired" {
            guard case .expiredUnsubmitted = try await f.store.claimOperationWork(id: work.id, ownerID: UUID(), action: .submit, now: Date()) else {
                throw V2OperationWorkError.invalidTransition
            }
        } else {
            let claim = try await f.claim(work)
            if scenario == "negative" {
                let receipt = try V2MessageSendOperationReceipt(identity: original.identity, fingerprint: original.fingerprint,
                    outcome: .closed, resolvedAtMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000))
                try await f.store.completeOperationWork(.init(identity: receipt.identity, fingerprint: receipt.fingerprint, state: .closed, receipt: receipt), now: Date())
            } else {
                try await f.store.deferOperationWork(claim, until: Date(), code: "OUTCOME_UNKNOWN", scheduling: .needsAttention)
            }
        }
        if scenario == "unknown" {
            await #expect(throws: V2ResourceJournalError.conflict) { try await f.store.replaceProvenUnsentSendIntent(intent.id) }
            await #expect(throws: V2ResourceJournalError.conflict) { try await f.store.abandonProvenUnsentSendIntent(intent.id) }
            #expect(try await f.store.operationWork(id: work.id)?.submissionStarted == true)
        } else {
            let replacement = try await f.store.replaceProvenUnsentSendIntent(intent.id)
            #expect(replacement != intent.id)
            #expect(try await f.store.replaceProvenUnsentSendIntent(intent.id) == replacement)
            let replacementIntent = try await f.store.databasePool.read { try GRDBV2LocalSyncStore.readSendIntent(replacement, db: $0) }
            #expect(replacementIntent?.clientMessageID != intent.clientMessageID)
            // Independently exercise discard using another proven-unsent intent.
            let discarded = try f.intent("discard proposal")
            try await f.store.freezeSendIntent(discarded, now: Date().addingTimeInterval(-90_000))
            try await f.store.handOffSendIntent(discarded.id)
            let discardWork = try await f.store.databasePool.read { db in
                try #require(String.fetchOne(db, sql: "SELECT work_id FROM v2_send_intents WHERE intent_id=?", arguments: [discarded.id.uuidString]).flatMap(UUID.init(uuidString:)))
            }
            _ = try await f.store.claimOperationWork(id: discardWork, ownerID: UUID(), action: .submit, now: Date())
            try await f.store.abandonProvenUnsentSendIntent(discarded.id)
            #expect(try await f.store.databasePool.read { try GRDBV2LocalSyncStore.readSendIntent(discarded.id, db: $0)?.stage } == .cancelled)
        }
        #expect(try await f.store.messageSendCommand(workID: work.id) == original)
        try await f.store.close()
    }

    @Test(arguments: ["receiptFirst", "projectionFirst", "preparedSnapshot"])
    func acceptedPresentationConvergesWithoutResurrection(_ order: String) async throws {
        let f = try SendWorkFixture(); defer { f.remove() }
        let intent = try f.intent("awaiting actual projection")
        try await f.store.freezeSendIntent(intent)
        try await f.store.handOffSendIntent(intent.id)
        let work = try await f.head(), command = try await f.store.messageSendCommand(workID: work.id)
        _ = try await f.claim(work)
        let message = MessageID(uuid: UUID())
        let receipt = try V2MessageSendOperationReceipt(identity: command.identity, fingerprint: command.fingerprint,
            outcome: .accepted(.init(messageID: message, roomSequence: 2)), resolvedAtMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000))
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init(uuid: UUID()), projectionKind: "message",
            payload: JSONSerialization.data(withJSONObject: ["event_type": "message.accepted", "message_id": message.rawValue,
                "room_id": f.room.rawValue, "room_sequence": 2, "message_revision": 1, "sender_user_id": f.account.rawValue,
                "text": intent.text, "server_created_at_ms": 1750000000000]))
        func applyLive() async throws {
            _ = try await f.store.apply(.init(generation: 1, records: [record], nextSyncToken: .init("accepted"),
                receipt: .init("accepted"), hasMore: false, capabilityProfile: "base"))
        }
        if order == "projectionFirst" { try await applyLive() }
        var snapshot: SnapshotFixture?
        if order == "preparedSnapshot" {
            let reset = try V2ClientResetRequired(snapshotID: .init("accepted-snapshot"), generation: 2, baseSequence: 1, expiresAt: .distantFuture)
            let page = try V2SnapshotProjectionV3Page(items: [.init(key: .init(projectionKind: "message", entityKey: message.rawValue),
                sourceEventID: record.sourceEventID, sequence: 1, payload: record.payload)])
            let value = try makeSnapshotFixture(reset: reset, pages: [page])
            try await f.store.beginReset(reset)
            try await f.store.beginSnapshotImport(value.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 1, capabilityProfile: "base"))
            for page in value.pages { try await f.store.applySnapshotPage(page, for: value.manifest) }
            try await f.store.prepareSnapshotActivation(value.manifest)
            snapshot = value
        }
        try await f.store.completeMessageSend(command, receipt: receipt)
        if order != "projectionFirst" {
            let pending = try await f.store.submittedSendIntents(in: f.room)
            #expect(pending.count == 1 && pending.first?.status == .acceptedAwaitingProjection)
            await #expect(throws: V2ResourceJournalError.conflict) { try await f.store.replaceProvenUnsentSendIntent(intent.id) }
            await #expect(throws: V2ResourceJournalError.conflict) { try await f.store.abandonProvenUnsentSendIntent(intent.id) }
            await #expect(throws: V2OperationWorkError.capacityExceeded) {
                try await f.store.databasePool.write { try GRDBV2LocalSyncStore.requireOperationCapacity(adding: 1, limits: .init(maximumActiveCount: 1), db: $0) }
            }
            #expect(try await f.store.pruneCompletedOperationHistory(now: Date().addingTimeInterval(8 * 86400)) == 0)
            if let snapshot { try await f.store.activateAcknowledgedSnapshot(snapshot.manifest) }
            else { try await applyLive() }
        }
        // No page read was required to record the authoritative materialization.
        let observed = try await f.store.databasePool.read { try Int.fetchOne($0, sql: "SELECT accepted_projection_observed FROM v2_message_send_operations WHERE work_id=?", arguments: [work.id.uuidString]) }
        #expect(observed == 1)
        try await f.store.databasePool.write { db in
            try db.execute(sql: "DELETE FROM v2_message_projections WHERE message_id=?", arguments: [message.rawValue])
            try GRDBV2LocalSyncStore.requireOperationCapacity(adding: 1, limits: .init(maximumActiveCount: 1), db: db)
        }
        #expect(try await f.store.submittedSendIntents(in: f.room).isEmpty)
        #expect(try await f.store.pruneCompletedOperationHistory(now: Date().addingTimeInterval(8 * 86400)) == 1)
        try await f.store.close()
    }

    @Test("200 terminal sends remain pageable without hiding a later active send")
    func terminalHistoryPagesLeaveActiveSendVisible() async throws {
        let f = try SendWorkFixture(); defer { f.remove() }
        var terminalIDs = Set<UUID>()
        for _ in 0..<201 {
            let intent = try f.intent("closed history")
            try await f.store.freezeSendIntent(intent)
            try await f.store.handOffSendIntent(intent.id)
            let work = try await f.head()
            _ = try await f.claim(work)
            try await f.store.completeOperationWork(.init(identity: work.identity, fingerprint: work.fingerprint,
                state: .closed, receipt: "original closed proof"), now: Date())
            terminalIDs.insert(intent.id)
        }
        let active = try f.intent("new active send")
        try await f.store.freezeSendIntent(active)
        try await f.store.handOffSendIntent(active.id)
        let first = try await f.store.submittedSendIntents(in: f.room, limit: 201)
        #expect(first.count == 201 && first.first?.id == active.id && first.first?.status == .pending)
        let second = try await f.store.submittedSendIntents(in: f.room, limit: 201, offset: 200)
        #expect(second.count == 2)
        #expect(Set(first.map(\.id)).union(second.map(\.id)) == terminalIDs.union([active.id]))
        try await f.store.close()
    }

    @Test("a lost acceptance survives restart and resolves the original client message ID")
    func lostAcceptance() async throws {
        let f=try SendWorkFixture();defer { f.remove() }
        let intent=try f.intent("immutable body")
        try await f.store.freezeSendIntent(intent)
        try await f.store.handOffSendIntent(intent.id)
        let work=try await f.head(),command=try await f.store.messageSendCommand(workID:work.id)
        let service=V2MessageSendOperationService(accountID:f.account,store:f.store,client:f.remote)
        try await service.execute(f.claim(work))
        #expect(try await f.store.operationWork(id:work.id)?.execution == .awaitingConfirmation)
        await #expect(throws:V2ResourceJournalError.conflict) { try await f.store.replaceProvenUnsentSendIntent(intent.id) }
        try await f.store.close()
        let restored=try GRDBV2LocalSyncStore(databaseURL:f.url,installationBinding:f.binding,userID:f.account)
        let pending=try #require(try await restored.operationWork(id:work.id))
        guard case .claimed(let claim)=try await restored.claimOperationWork(id:pending.id,ownerID:UUID(),action:pending.nextAction,now:pending.nextActionAt) else { throw V2OperationWorkError.invalidTransition }
        try await V2MessageSendOperationService(accountID:f.account,store:restored,client:f.remote).execute(claim)
        #expect(try await restored.operationWork(id:work.id)?.execution == .committed)
        #expect(try await restored.messageSendCommand(workID:work.id) == command)
        let submissions=await f.remote.submissions,recoveries=await f.remote.recoveries
        #expect(submissions == 1 && recoveries == 1)
        #expect(try await restored.messages(in:f.room).isEmpty)
        try await restored.close()
    }
    @Test("a full shared reservation transfers to executable work without double admission")
    func fullQuotaHandoff() async throws {
        let f=try SendWorkFixture();defer { f.remove() }
        let intent=try f.intent("body")
        try await f.store.freezeSendIntent(intent)
        let bytes=try await f.store.databasePool.read { try Int64.fetchOne($0,sql:"SELECT payload_bytes FROM v2_send_intents WHERE intent_id=?",arguments:[intent.id.uuidString])! }
        let count=try await f.store.databasePool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM v2_operation_work")! }
        #expect(count == 0 && bytes>0)
        await #expect(throws:V2OperationWorkError.capacityExceeded) {
            try await f.store.databasePool.write { try GRDBV2LocalSyncStore.requireOperationCapacity(adding:1,limits:.init(maximumActiveCount:1),db:$0) }
        }
        try await f.store.handOffSendIntent(intent.id,limits:.init(maximumActiveCount:1,maximumPayloadBytes:bytes))
        let work=try await f.head()
        let frozenBytes=try await f.store.databasePool.read { try Int64.fetchOne($0,sql:"SELECT payload_bytes FROM v2_operation_work WHERE work_id=?",arguments:[work.id.uuidString])! }
        #expect(frozenBytes==bytes)
        #expect(try await f.store.preparingSendIntents().isEmpty)
        try await f.store.close()
    }
    @Test("preparation does not renew the original 24 hour first submission deadline")
    func delayedPreparation() async throws {
        let f=try SendWorkFixture();defer { f.remove() }
        let created=Date().addingTimeInterval(-90_000),intent=try f.intent("stale draft")
        try await f.store.freezeSendIntent(intent,now:created)
        try await f.store.handOffSendIntent(intent.id)
        let work=try await f.head(),command=try await f.store.messageSendCommand(workID:work.id)
        #expect(command.firstSubmissionDeadlineMilliseconds == UInt64(created.timeIntervalSince1970*1_000)+86_400_000)
        let result=try await f.store.claimOperationWork(id:work.id,ownerID:UUID(),action:.submit,now:Date())
        guard case .expiredUnsubmitted=result else { Issue.record("stale draft received a submit claim"); return }
        #expect(await f.remote.submissions == 0)
        #expect(try await f.store.operationWork(id:work.id)?.execution == .expiredUnsubmitted)
        try await f.store.close()
    }
    @Test("200 pending messages per room are bounded independently of other rooms")
    func roomCapacity() async throws {
        let f=try SendWorkFixture();defer { f.remove() }
        for _ in 0..<200 { try await f.store.freezeSendIntent(f.intent("queued")) }
        await #expect(throws:V2OperationWorkError.capacityExceeded) { try await f.store.freezeSendIntent(f.intent("overflow")) }
        try await f.store.freezeSendIntent(.init(id:UUID(),roomID:.init(uuid:UUID()),clientMessageID:.init(uuid:UUID()),text:"independent",attachmentJobIDs:[]))
        #expect(try await f.store.preparingSendIntents(limit:256).count == 201)
        try await f.store.close()
    }
}
struct SendWorkFixture {
    let url:URL,binding=V2LocalInstallationBinding(value:UUID()),account=UserID(uuid:UUID()),room=RoomID(uuid:UUID())
    let store:GRDBV2LocalSyncStore,remote=SendWorkRemote()
    init() throws {
        url=FileManager.default.temporaryDirectory.appending(path:"send-work-"+UUID().uuidString).appending(path:"state.sqlite")
        store=try .init(databaseURL:url,installationBinding:binding,userID:account)
    }
    func intent(_ text:String) throws -> V2SendIntent { try .init(id:UUID(),roomID:room,clientMessageID:.init(uuid:UUID()),text:text,attachmentJobIDs:[]) }
    func head() async throws -> V2OperationWork { try #require(try await store.dueOperationWork(now:.distantFuture,kinds:[.sendMessage]).first) }
    func claim(_ work:V2OperationWork) async throws -> V2OperationWorkClaim {
        guard case .claimed(let claim)=try await store.claimOperationWork(id:work.id,ownerID:UUID(),action:work.nextAction,now:work.nextActionAt) else { throw V2OperationWorkError.invalidTransition }
        return claim
    }
    func remove() { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
}
actor SendWorkRemote:V2MessageSendOperationClient {
    var submissions=0,recoveries=0
    var receipt:V2MessageSendOperationReceipt?
    func submit(_ command:V2MessageSendOperationCommand) async throws -> V2MessageSendOperationRecoveryResult {
        submissions += 1
        receipt=try .init(identity:command.identity,fingerprint:command.fingerprint,
            outcome:.accepted(.init(messageID:.init(uuid:UUID()),roomSequence:2)),resolvedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1_000))
        throw URLError(.networkConnectionLost)
    }
    func recover(_ request:V2MessageSendOperationRecoveryRequest) async throws -> V2MessageSendOperationRecoveryResult {
        recoveries += 1
        guard let receipt else { return .unresolved }
        return .receipt(receipt)
    }
}

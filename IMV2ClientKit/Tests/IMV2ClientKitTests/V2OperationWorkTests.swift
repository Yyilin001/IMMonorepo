import Foundation
import GRDB
import Testing
@testable import IMV2ClientKit
import IMV2Core

struct V2OperationWorkTests {
    @Test func diagnosticReservationsMatchCrossDomainAdmission() async throws {
        let (store, _, _, user) = try fixture()
        let work = try input(user)
        try await enqueue(work, in: store)
        try await store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_profile_intents(intent_id,account_id,payload,payload_bytes) VALUES(?,?,?,17)",
                arguments: [UUID().uuidString, user.rawValue, Data("draft".utf8)])
        }
        let snapshot = try await store.accountWorkSnapshot(now: now)
        #expect(snapshot.ordinaryCount == 2 && snapshot.ordinaryReservedBytes == 33)
        #expect(snapshot.controlCount == 0 && snapshot.controlReservedBytes == 0)
        #expect(snapshot.oldestUnresolvedOriginalAge == nil)
        let extra = try input(user, key: "extra")
        await #expect(throws: V2OperationWorkError.capacityExceeded) {
            try await enqueue(extra, in: store, limits: .init(maximumActiveCount: 2, maximumPayloadBytes: 33))
        }
        let unchanged = try await store.accountWorkSnapshot(now: now)
        #expect(unchanged.ordinaryCount == 2 && unchanged.ordinaryReservedBytes == 33)
    }

    @Test(arguments: [V2OperationExecutionState.committed, .closed])
    func fullAdmissionQuotaNeverBlocksOriginalOutcomeRecovery(terminal: V2OperationExecutionState) async throws {
        let (store, url, binding, user) = try fixture()
        let original = try input(user), extra = try input(user, key: "extra")
        let limits = V2OperationWorkLimits(maximumActiveCount: 1, maximumPayloadBytes: 16)
        try await enqueue(original, in: store, limits: limits)
        let first = try await claim(original, in: store)
        let cooldown = now.addingTimeInterval(120)
        try await store.deferOperationWork(first, until: cooldown, code: "RESPONSE_LOST", scheduling: .needsAttention)
        try await store.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: user)
        await #expect(throws: V2OperationWorkError.capacityExceeded) {
            try await enqueue(extra, in: reopened, limits: limits)
        }
        // Recovery and user-authorized continuation update the existing row;
        // neither can require spare ordinary count/payload capacity.
        try await reopened.retryOperationWorkByUser(id: original.id, now: now)
        #expect(try await reopened.operationWork(id: original.id)?.nextActionAt == cooldown)
        let recovery = try await claim(original, in: reopened, action: .reconcile, at: cooldown)
        #expect(recovery.work.identity == original.identity)
        #expect(recovery.work.attemptCount == 2)
        try await reopened.completeOperationWork(.init(identity: original.identity, fingerprint: original.fingerprint,
            state: terminal, receipt: "verified original result"), now: cooldown)
        #expect(try await reopened.operationWork(id: original.id)?.execution == terminal)
        // Only the proven terminal outcome releases the ordinary reservation.
        try await enqueue(extra, in: reopened, limits: limits)
        let rows = try await reopened.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_operation_work") }
        #expect(rows == 2)
        try await reopened.close()
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func fixture() throws -> (GRDBV2LocalSyncStore, URL, V2LocalInstallationBinding, UserID) {
        let url = FileManager.default.temporaryDirectory.appending(path: "work-\(UUID()).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let user = try UserID("work-user")
        return (try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: user), url, binding, user)
    }
    private func input(_ user: UserID, key: String = "profile", dependencies: [UUID] = [], deadline: Date? = nil) throws -> V2NewOperationWork {
        try .init(intentID: UUID(), identity: .init(accountID: user, scope: .account(user),
            operation: .profileUpdate(.init(UUID().uuidString))),
            fingerprint: .init(kind: .profileUpdate, fields: [.init("name", .text("name"))]),
            orderingKey: key, payloadBytes: 16, admissionDeadline: deadline, dependencyIDs: dependencies)
    }
    private func enqueue(_ input: V2NewOperationWork, in store: GRDBV2LocalSyncStore, limits: V2OperationWorkLimits = .init()) async throws {
        try await store.databasePool.write { db in
            _ = try GRDBV2LocalSyncStore.insertOperationWork(input, now: now, limits: limits, db: db)
        }
    }
    private func claim(_ input: V2NewOperationWork, in store: GRDBV2LocalSyncStore, owner: UUID = UUID(), action: V2OperationWorkAction = .submit, at: Date? = nil, budget: Int = 5) async throws -> V2OperationWorkClaim {
        let result = try await store.claimOperationWork(id: input.id, ownerID: owner, action: action, now: at ?? now, maximumAutomaticAttempts: budget)
        guard case .claimed(let claim) = result else { throw V2OperationWorkError.invalidTransition }
        return claim
    }
    private func commit(_ input: V2NewOperationWork, in store: GRDBV2LocalSyncStore) async throws {
        try await store.completeOperationWork(.init(identity: input.identity, fingerprint: input.fingerprint,
            state: .committed, receipt: "immutable-receipt"), now: now)
    }

    private func retainedProfile(_ input: V2NewOperationWork, in store: GRDBV2LocalSyncStore, released: Bool) async throws {
        try await enqueue(input, in: store)
        try await store.databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO v2_profile_intents(intent_id,account_id,payload,work_id,source_released,payload_bytes)
                VALUES(?,?,?,?,?,17)
                """, arguments: [input.intentID.uuidString, input.identity.accountID.rawValue,
                    Data("retention-fixture".utf8), input.id.uuidString, released])
        }
    }

    @Test func historyPruningPreservesUnknownDraftsSourcesAndRecentResults() async throws {
        let (store, _, _, user) = try fixture()
        let complete = try input(user, key: "done"), protected = try input(user, key: "protected")
        let unknown = try input(user, key: "unknown"), rejected = try input(user, key: "rejected")
        let recent = try input(user, key: "recent")
        for work in [complete, protected, unknown, rejected, recent] {
            try await retainedProfile(work, in: store, released: work.id != protected.id)
            _ = try await claim(work, in: store)
        }
        for work in [complete, protected] { try await commit(work, in: store) }
        try await store.completeOperationWork(.init(identity: rejected.identity, fingerprint: rejected.fingerprint,
            state: .rejected, receipt: "rejection"), now: now)
        let later = now.addingTimeInterval(8 * 24 * 60 * 60)
        try await store.completeOperationWork(.init(identity: recent.identity, fingerprint: recent.fingerprint,
            state: .committed, receipt: "recent"), now: later)
        #expect(try await store.pruneCompletedOperationHistory(now: later) == 1)
        #expect(try await store.operationWork(id: complete.id) == nil)
        for work in [protected, unknown, rejected, recent] {
            #expect(try await store.operationWork(id: work.id) != nil)
        }
        let count = try await store.databasePool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_profile_intents") }
        #expect(count == 4)
    }

    @Test func historyPruningIsBoundedAndKeepsReferencedParentUntilChildRemoval() async throws {
        let (store, _, _, user) = try fixture()
        let parent = try input(user, key: "parent")
        let child = try input(user, key: "child", dependencies: [parent.id])
        for work in [parent, child] { try await retainedProfile(work, in: store, released: true) }
        // The latest committed profile is retained as the recovery supersession
        // boundary, so older failed drafts cannot reappear after cleanup.
        let newest = try input(user, key: "newest")
        try await retainedProfile(newest, in: store, released: true)
        _ = try await claim(newest, in: store)
        try await commit(newest, in: store)
        _ = try await claim(parent, in: store)
        try await commit(parent, in: store)
        let later = now.addingTimeInterval(8 * 24 * 60 * 60)
        #expect(try await store.pruneCompletedOperationHistory(now: later, limit: 1) == 0)
        _ = try await claim(child, in: store)
        try await commit(child, in: store)
        #expect(try await store.pruneCompletedOperationHistory(now: later, limit: 1) == 1)
        #expect(try await store.operationWork(id: child.id) == nil)
        #expect(try await store.operationWork(id: parent.id) != nil)
        #expect(try await store.pruneCompletedOperationHistory(now: later, limit: 1) == 1)
        #expect(try await store.operationWork(id: parent.id) == nil)
        await #expect(throws: V2OperationWorkError.invalidRecord) {
            try await store.pruneCompletedOperationHistory(now: later, limit: 129)
        }
    }

    @Test func messageHistoryCleanupKeepsUnknownAndReplacementDependencies() async throws {
        let (store, _, _, user) = try fixture()
        let room = RoomID(uuid: UUID())
        let deadline = UInt64(now.addingTimeInterval(3_600).timeIntervalSince1970 * 1_000)
        var completedMutationIDs: [UUID] = []
        for withdraw in [false, true] {
            let message = MessageID(uuid: UUID())
            let payload: V2MessageMutationPayload
            if withdraw {
                payload = .withdraw(try .init(command: .init(roomID: room, actorUserID: user,
                    operationID: .init(UUID().uuidString), messageID: message, expectedMessageRevision: 1),
                    firstSubmissionDeadlineMilliseconds: deadline))
            } else {
                payload = .edit(try .init(command: .init(roomID: room, actorUserID: user,
                    operationID: .init(UUID().uuidString), messageID: message, expectedMessageRevision: 1,
                    text: "completed edit", maximumUTF8Bytes: 65_536), firstSubmissionDeadlineMilliseconds: deadline))
            }
            let id = try await store.enqueueMessageMutation(payload, now: now)
            guard case .claimed = try await store.claimOperationWork(id: id, ownerID: UUID(), action: .submit, now: now) else {
                throw V2OperationWorkError.invalidTransition
            }
            try await store.completeOperationWork(.init(identity: payload.identity, fingerprint: payload.fingerprint,
                state: .committed, receipt: "mutation-receipt"), now: now)
            completedMutationIDs.append(id)
        }
        let plain = try await persistDurableMessage(in: store, roomID: room,
            clientMessageID: .init(uuid: UUID()), text: "completed send")
        let pinned = try await persistDurableMessage(in: store, roomID: room,
            clientMessageID: .init(uuid: UUID()), text: "referenced send")
        let unknown = try await persistDurableMessage(in: store, roomID: room,
            clientMessageID: .init(uuid: UUID()), text: "outcome unknown")
        var sendIDs: [UUID: UUID] = [:]
        var acceptedSends: [(ClientMessageID, V2MessageOperationAcceptance)] = []
        for intent in [plain, pinned, unknown] {
            let id = try #require(try await store.databasePool.read { db in
                try String.fetchOne(db, sql: "SELECT work_id FROM v2_send_intents WHERE intent_id=?",
                    arguments: [intent.id.uuidString]).flatMap(UUID.init(uuidString:))
            })
            sendIDs[intent.id] = id
            let work = try #require(try await store.operationWork(id: id))
            guard case .claimed(let currentClaim) = try await store.claimOperationWork(id: id, ownerID: UUID(), action: .submit, now: work.nextActionAt) else {
                throw V2OperationWorkError.invalidTransition
            }
            if intent.id == unknown.id {
                try await store.deferOperationWork(currentClaim, until: now, code: "TEST_UNKNOWN")
            } else {
                let accepted = try V2MessageOperationAcceptance(messageID: .init(uuid: UUID()), roomSequence: UInt64(acceptedSends.count + 1))
                try await store.completeResourceSendFixture(intent.clientMessageID, result: .accepted(accepted), now: now)
                acceptedSends.append((intent.clientMessageID, accepted))
            }
        }
        // A replacement reference must keep its parent even when all network work completed.
        try await store.databasePool.write { db in
            try db.execute(sql: "UPDATE v2_send_intents SET replacement_of=? WHERE intent_id=?",
                arguments: [pinned.id.uuidString, unknown.id.uuidString])
        }
        let later = now.addingTimeInterval(8 * 24 * 60 * 60)
        #expect(try await store.pruneCompletedOperationHistory(now: now) == 0)
        // Accepted but unmaterialized sends remain protected beyond retention.
        #expect(try await store.pruneCompletedOperationHistory(now: later) == 2)
        #expect(try await store.operationWork(id: #require(sendIDs[plain.id])) != nil)
        for (id, accepted) in acceptedSends {
            try await store.observeResourceSendFixtureProjection(id, accepted: accepted)
        }
        #expect(try await store.pruneCompletedOperationHistory(now: later) == 1)
        for id in completedMutationIDs { #expect(try await store.operationWork(id: id) == nil) }
        #expect(try await store.operationWork(id: #require(sendIDs[plain.id])) == nil)
        #expect(try await store.operationWork(id: #require(sendIDs[pinned.id])) != nil)
        #expect(try await store.operationWork(id: #require(sendIDs[unknown.id])) != nil)
        #expect(Set(try await savedDurableMessages(in: store).map(\.id)) == [pinned.id, unknown.id])
        try await store.close()
    }

    @Test func messageHistoryCleanupDetachesReadyImportsWithoutDeletingTheirJobs() async throws {
        let (store, _, _, _) = try fixture()
        let room = RoomID(uuid: UUID()), job = UUID()
        let source = V2ResourceImportSource.message(location: .init(roomID: .init(uuid: UUID()),
            messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil)
        let request = try V2ResourceImportRequest(operationID: .init(uuid: UUID()), source: source,
            targetUsage: .messageAttachment(room), targetMediaID: .init(uuid: UUID()))
        try await store.prepareResourceImport(id: job, request: request)
        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()),
            text: "completed attachment", attachmentJobIDs: [job])
        try await store.freezeMetadataSendIntent(intent)
        let status = try V2ResourceImportStatus(locator: .init(home: .room(room), operationID: request.operationID),
            mediaID: request.targetMediaID, state: .ready, bindableUntil: Date().addingTimeInterval(60))
        try await store.seedResourceImportStatus(status, id: job)
        try await store.handOffSendIntent(intent.id)
        let work = try #require(try await store.dueOperationWork(now: Date(), kinds: [.sendMessage]).first)
        guard case .claimed = try await store.claimOperationWork(id: work.id, ownerID: UUID(), action: .submit, now: Date()) else {
            throw V2OperationWorkError.invalidTransition
        }
        let accepted = try V2MessageOperationAcceptance(messageID: .init(uuid: UUID()), roomSequence: 1)
        try await store.completeResourceSendFixture(intent.clientMessageID, result: .accepted(accepted), now: now)
        #expect(try await store.pruneCompletedOperationHistory(now: now.addingTimeInterval(8 * 24 * 60 * 60)) == 0)
        try await store.observeResourceSendFixtureProjection(intent.clientMessageID, accepted: accepted,
            mediaPresentations: [try .init(mediaID: request.targetMediaID, kind: .file, contentType: "text/plain", byteCount: 3)])
        #expect(try await store.pruneCompletedOperationHistory(now: now.addingTimeInterval(8 * 24 * 60 * 60)) == 1)
        #expect(try await store.operationWork(id: work.id) == nil)
        #expect(try await savedDurableMessages(in: store).isEmpty)
        let remaining = try await store.databasePool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_resource_import_jobs WHERE job_id=?", arguments: [job.uuidString])
        }
        #expect(remaining == 1)
        try await store.close()
    }

    @Test func uploadHistoryWaitsForPhysicalSourceReleaseAndKeepsIndependentJob() async throws {
        let (store, _, _, _) = try fixture()
        let room = RoomID(uuid: UUID()), job = UUID()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: job.uuidString)
        try Data([1, 2, 3]).write(to: file)
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()),
            usage: .messageAttachment(room), contentType: "text/plain", byteCount: 3,
            checksum: .init(value: String(repeating: "b", count: 64)))
        _ = try await store.prepareMetadataResourceTransfer(id: job, request: request, localAssetID: .init(job))
        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()),
            text: "protected attachment", attachmentJobIDs: [job])
        try await store.freezeMetadataSendIntent(intent)
        let ready = try V2ResourceUploadSession(locator: .init(home: .room(room), sessionID: .init(uuid: UUID())),
            mediaID: request.mediaID, generation: 1, state: .completed, resourceState: .ready,
            expiresAt: Date().addingTimeInterval(60), bindableUntil: Date().addingTimeInterval(60))
        try await store.saveResourceSession(ready, for: job)
        try await store.handOffSendIntent(intent.id)
        let work = try #require(try await store.dueOperationWork(now: Date(), kinds: [.sendMessage]).first)
        guard case .claimed = try await store.claimOperationWork(id: work.id, ownerID: UUID(), action: .submit, now: Date()) else {
            throw V2OperationWorkError.invalidTransition
        }
        let accepted = try V2MessageOperationAcceptance(messageID: .init(uuid: UUID()), roomSequence: 1)
        try await store.completeResourceSendFixture(intent.clientMessageID, result: .accepted(accepted), now: now)
        let later = now.addingTimeInterval(8 * 24 * 60 * 60)
        #expect(try await store.pruneCompletedOperationHistory(now: later) == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try await store.releasableResourceAssetID(id: job) == .init(job))
        // Claiming deletion alone cannot release the history ownership boundary.
        #expect(try await store.pruneCompletedOperationHistory(now: later) == 0)
        try await store.releaseResourceSource(id: job)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try await store.pruneCompletedOperationHistory(now: later) == 0)
        try await store.observeResourceSendFixtureProjection(intent.clientMessageID, accepted: accepted,
            mediaPresentations: [try .init(mediaID: request.mediaID, kind: .file, contentType: request.contentType, byteCount: request.byteCount)])
        #expect(try await store.pruneCompletedOperationHistory(now: later) == 1)
        #expect(try await store.operationWork(id: work.id) == nil)
        #expect(try await savedDurableMessages(in: store).isEmpty)
        let remaining = try await store.databasePool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_resource_transfer_jobs WHERE job_id=?", arguments: [job.uuidString])
        }
        #expect(remaining == 1)
        try await store.close()
    }

    @Test func dispatcherDrainsHistoryInBatchesWithoutNewNetworkWork() async throws {
        let (store, _, _, user) = try fixture()
        for index in 0..<34 {
            let work = try input(user, key: "history-\(index)")
            try await retainedProfile(work, in: store, released: true)
            _ = try await claim(work, in: store)
            try await commit(work, in: store)
        }
        let later = now.addingTimeInterval(8 * 24 * 60 * 60)
        let dispatcher = V2OperationWorkDispatcher(store: store, handlers: [], now: { later })
        let task = Task { try await dispatcher.run() }
        var count = 34
        for _ in 0..<200 {
            count = try await store.databasePool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_operation_work") ?? 0 }
            if count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await dispatcher.stopAndDrain()
        try await task.value
        #expect(count == 1)
    }

    @Test func backingOffHeadBlocksOnlyItsKeyAndWakeIgnoresYoungerRows() async throws {
        let (store, _, _, user) = try fixture()
        let a = try input(user), b = try input(user), c = try input(user, key: "other")
        for work in [a,b,c] { try await enqueue(work, in: store) }
        let first = try await claim(a, in: store)
        try await store.deferOperationWork(first, until: now.addingTimeInterval(30), code: "TIMEOUT")
        #expect(try await store.dueOperationWork(now: now).map(\.id) == [c.id])
        try await store.cancelUnsubmittedOperation(id: c.id, now: now)
        #expect(try await store.operationWorkRetrySchedule(kinds: [.profileUpdate]).nextAttemptAt() == now.addingTimeInterval(30))
        #expect(try await store.operationWorkRetrySchedule(kinds: [.sendMessage]).nextAttemptAt() == nil)
        try await commit(a, in: store)
        #expect(try await store.dueOperationWork(now: now).map(\.id) == [b.id])
    }

    @Test func crashRecoveryPreservesAttemptsAndLateSuccessDefeatsStaleFailure() async throws {
        let (store, url, binding, user) = try fixture()
        let work = try input(user), oldOwner = UUID()
        try await enqueue(work, in: store)
        let old = try await claim(work, in: store, owner: oldOwner)
        // A same-owner timeout cannot prove the physical transport stopped.
        try await store.recoverOperationClaims(forNewOwner: oldOwner, now: now.addingTimeInterval(31))
        #expect(try await store.operationWork(id: work.id)?.scheduling == .claimed)
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: user)
        try await reopened.recoverOperationClaims(forNewOwner: UUID(), now: now)
        #expect(try await reopened.operationWork(id: work.id)?.attemptCount == 1)
        let newer = try await claim(work, in: reopened, action: .reconcile)
        await #expect(throws: V2OperationWorkError.staleClaim) {
            try await reopened.deferOperationWork(old, until: now, code: "OLD_FAILURE")
        }
        try await commit(work, in: reopened)
        try await reopened.deferOperationWork(newer, until: now, code: "LATE_FAILURE")
        #expect(try await reopened.operationWork(id: work.id)?.execution == .committed)
    }

    @Test func durableBudgetsNeedExplicitUserRoundAndKeepLifetimeCount() async throws {
        let (store, _, _, user) = try fixture()
        let work = try input(user)
        try await enqueue(work, in: store)
        let first = try await claim(work, in: store, budget: 1)
        try await store.deferOperationWork(first, until: now, code: "TIMEOUT")
        let exhausted = try await store.claimOperationWork(id: work.id, ownerID: UUID(), action: .submit, now: now, maximumAutomaticAttempts: 1)
        guard case .needsAttention = exhausted else { Issue.record("budget must exhaust"); return }
        try await store.resumeOperationWork(id: work.id, now: now)
        // Original result can still be queried with its separate budget.
        let query = try await claim(work, in: store, action: .reconcile, budget: 1)
        try await store.deferOperationWork(query, until: now, code: "UNRESOLVED")
        try await store.retryOperationWorkByUser(id: work.id, now: now)
        let retry = try await claim(work, in: store, action: .reconcile, budget: 1)
        #expect(retry.work.attemptCount == 3)
        #expect(retry.work.reconciliationRoundAttempts == 1)
        #expect(retry.work.identity == work.identity)
    }

    @Test func expiryAndCancellationCannotEraseUnknownSubmission() async throws {
        let (store, _, _, user) = try fixture()
        let expired = try input(user, key: "expired", deadline: now)
        try await enqueue(expired, in: store)
        guard case .expiredUnsubmitted = try await store.claimOperationWork(id: expired.id, ownerID: UUID(), action: .submit, now: now) else {
            Issue.record("expiry must commit"); return
        }
        #expect(try await store.operationWork(id: expired.id)?.execution == .expiredUnsubmitted)
        let unknown = try input(user, deadline: now.addingTimeInterval(1))
        try await enqueue(unknown, in: store)
        let sent = try await claim(unknown, in: store)
        try await store.deferOperationWork(sent, until: now, code: "TIMEOUT")
        await #expect(throws: V2OperationWorkError.invalidTransition) { try await store.cancelUnsubmittedOperation(id: unknown.id, now: now) }
        let recovered = try await claim(unknown, in: store, action: .reconcile, at: now.addingTimeInterval(2))
        #expect(recovered.work.submissionStarted)
        #expect(!recovered.work.execution.isTerminal)
    }

    @Test func dependencyNeedsCommittedReceiptAndCapacityRollsBackPayload() async throws {
        let (store, _, _, user) = try fixture()
        let parent = try input(user, key: "parent")
        try await enqueue(parent, in: store)
        let child = try input(user, key: "child", dependencies: [parent.id])
        try await enqueue(child, in: store)
        #expect(try await store.dueOperationWork(now: now).map(\.id) == [parent.id])
        _ = try await claim(parent, in: store)
        try await commit(parent, in: store)
        #expect(try await store.dueOperationWork(now: now).map(\.id) == [child.id])
        try await store.databasePool.write { db in try db.execute(sql: "CREATE TABLE test_domain_payload(id TEXT PRIMARY KEY)") }
        let excess = try input(user, key: "excess")
        await #expect(throws: V2OperationWorkError.capacityExceeded) {
            try await store.databasePool.write { db in
                try db.execute(sql: "INSERT INTO test_domain_payload VALUES (?)", arguments: [excess.id.uuidString])
                _ = try GRDBV2LocalSyncStore.insertOperationWork(excess, now: now, limits: .init(maximumActiveCount: 1), db: db)
            }
        }
        let count = try await store.databasePool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM test_domain_payload") }
        #expect(count == 0)
        #expect(try await store.operationWork(id: excess.id) == nil)
    }

    @Test func identityReplayIsExactAndAccountCannotChange() async throws {
        let (store, _, _, user) = try fixture()
        let work = try input(user)
        try await enqueue(work, in: store)
        try await enqueue(work, in: store)
        let changed = try V2NewOperationWork(id: work.id, intentID: work.intentID, identity: work.identity,
            fingerprint: .init(kind: .profileUpdate, fields: [.init("name", .text("other"))]),
            orderingKey: work.orderingKey, payloadBytes: work.payloadBytes, admissionDeadline: nil)
        await #expect(throws: V2OperationWorkError.identityConflict) { try await enqueue(changed, in: store) }
        let other = try input(UserID("other-account"))
        await #expect(throws: V2OperationWorkError.accountMismatch) { try await enqueue(other, in: store) }
    }
    @Test func dispatcherProgressesOtherKeysWhileOneStepIsBlocked() async throws {
        let (store, _, _, user) = try fixture()
        let slow = try input(user, key: "slow"), fast = try input(user, key: "fast")
        let gate = OperationWorkTestGate()
        let diagnostics = V2NetworkDiagnostics()
        try await enqueue(slow, in: store)
        let dispatcher = V2OperationWorkDispatcher(store: store, handlers: [.init(kind: .profileUpdate) { claim in
            if claim.work.id == slow.id { await gate.wait() }
            try await store.completeOperationWork(.init(identity: claim.work.identity, fingerprint: claim.work.fingerprint,
                state: .committed, receipt: "receipt"), now: now)
        }], maximumInFlight: 2, now: { now }, diagnostics: diagnostics)
        let task = Task { try await dispatcher.run() }
        // A newly inserted independent key must progress while slow is running,
        // not only after a whole initial task-group batch finishes.
        try await enqueue(fast, in: store)
        var fastCommitted = false
        for _ in 0..<200 {
            if try await store.operationWork(id: fast.id)?.execution == .committed { fastCommitted = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fastCommitted)
        #expect(try await store.operationWork(id: slow.id)?.execution != .committed)
        await gate.release()
        await dispatcher.stopAndDrain()
        try await task.value
        #expect(try await store.operationWork(id: slow.id)?.execution == .committed)
        let metrics = diagnostics.snapshot().operationSteps
        #expect(metrics.count == 2)
        #expect(metrics.allSatisfy { $0.kind == .profileUpdate && $0.action == .submit && $0.attempt == 1 })
        #expect(metrics.allSatisfy { $0.execution == .committed && $0.certainty == .responseReceived && $0.completion == .returned })
        #expect(metrics.allSatisfy { $0.candidateWait >= 0 && $0.handlerElapsed >= 0 })
    }

    @Test func dispatcherReconcileMetricUsesOriginalAttemptAndVerifiedJournal() async throws {
        let (store, _, _, user) = try fixture()
        let work = try input(user)
        try await enqueue(work, in: store)
        let original = try await claim(work, in: store)
        try await store.deferOperationWork(original, until: now, code: "RESPONSE_LOST", nextAction: .reconcile)
        let diagnostics = V2NetworkDiagnostics()
        let dispatcher = V2OperationWorkDispatcher(store: store, handlers: [.init(kind: .profileUpdate) { claim in
            try await store.completeOperationWork(.init(identity: claim.work.identity, fingerprint: claim.work.fingerprint,
                state: .closed, receipt: "verified closure"), now: now)
        }], now: { now }, diagnostics: diagnostics)
        let task = Task { try await dispatcher.run() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while diagnostics.snapshot().operationSteps.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        await dispatcher.stopAndDrain(); try await task.value
        let metric = try #require(diagnostics.snapshot().operationSteps.last)
        #expect(metric.action == .reconcile && metric.attempt == 2 && metric.priority == .recovery)
        #expect(metric.execution == .closed && metric.certainty == .responseReceived)
    }

    @Test func unfrozenProfileIntentReservesSharedCapacity() async throws {
        let (store, _, _, user) = try fixture()
        let stagedID = UUID()
        let source = try V2ProfileAvatarUpload(id: stagedID,
            localAssetID: .init(stagedID),
            displayName: "avatar.png", contentType: "image/png", byteCount: 32)
        try await store.seedMetadataProfileSource(source)
        let intent = try await store.enqueueProfileIntent(accountID: user, expectedRevision: .init(rawValue: 1)!,
            patch: .init(displayName: .set("name")), avatarUpload: source, now: now)
        #expect(intent.workID == nil)
        let other = try input(user, key: "other")
        await #expect(throws: V2OperationWorkError.capacityExceeded) {
            try await enqueue(other, in: store, limits: .init(maximumActiveCount: 1))
        }
        #expect(try await store.operationWork(id: other.id) == nil)
    }

    @Test func elapsedRoundBudgetSurvivesWakeAndStopsAutomaticReplay() async throws {
        let (store, _, _, user) = try fixture()
        let work = try input(user)
        try await enqueue(work, in: store)
        let first = try await claim(work, in: store)
        try await store.deferOperationWork(first, until: now, code: "TIMEOUT")
        try await store.resumeOperationWork(id: work.id, now: now.addingTimeInterval(61))
        guard case .needsAttention = try await store.claimOperationWork(id: work.id, ownerID: UUID(), action: .submit,
            now: now.addingTimeInterval(61)) else { Issue.record("elapsed round budget was reset"); return }
        #expect(try await store.operationWork(id: work.id)?.attemptCount == 1)
    }

    @Test func explicitRetryPreservesExistingCooldown() async throws {
        let (store, _, _, user) = try fixture()
        let work = try input(user)
        try await enqueue(work, in: store)
        let first = try await claim(work, in: store)
        let cooldown = now.addingTimeInterval(120)
        try await store.deferOperationWork(first, until: cooldown, code: "RETRY_AFTER", scheduling: .needsAttention)
        try await store.retryOperationWorkByUser(id: work.id, now: now)
        let resumed = try #require(try await store.operationWork(id: work.id))
        #expect(resumed.nextActionAt == cooldown)
        #expect(resumed.nextAction == .reconcile)
        #expect(resumed.attemptCount == 1)
        #expect(try await store.dueOperationWork(now: now).isEmpty)
    }

}


private actor OperationWorkTestGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let current = waiters; waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

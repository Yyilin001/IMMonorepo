import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Message send public work", .serialized)
struct V2MessageSendWorkTests {
    @Test("sending restores an archived conversation and preserves pin and mute settings")
    func sendingRestoresArchivedConversation() async throws {
        let f = try SendWorkFixture(); defer { f.remove() }
        let mute = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 3600)
        try await f.store.enqueuePersonalPreference(accountID: f.account,
            target: .conversation(roomID: f.room, isPinned: true, isArchived: true, muteUntil: mute))
        try await confirmPreference(f, pinned: true, archived: true, mute: mute)
        #expect(try await f.store.conversationState(roomID: f.room)?.isArchived == true)
        let intent = try f.intent("resume chat")
        try await f.store.freezeSendIntent(intent)
        let desired = try await f.store.personalPreferenceTarget(accountID: f.account,
            fallback: .conversation(roomID: f.room, isPinned: false, isArchived: true, muteUntil: nil))
        #expect(desired == .conversation(roomID: f.room, isPinned: true, isArchived: false, muteUntil: mute))
        // Replaying the same send must not create another preference operation.
        try await f.store.freezeSendIntent(intent)
        try await confirmPreference(f, pinned: true, archived: false, mute: mute)
        let state = try #require(try await f.store.conversationState(roomID: f.room))
        #expect(!state.isArchived && state.isPinned && state.muteUntil == mute)
        #expect(try await f.store.preparePersonalPreferences(accountID: f.account) == 0)
        try await f.store.close()
    }

    @Test("a send supersedes an unfrozen archive without resetting other pending settings")
    func sendingCoalescesPendingArchive() async throws {
        let f = try SendWorkFixture(); defer { f.remove() }
        let archive = try await f.store.enqueuePersonalPreference(accountID: f.account,
            target: .conversation(roomID: f.room, isPinned: true, isArchived: true, muteUntil: nil))
        try await f.store.freezeSendIntent(f.intent("resume pending archive"))
        let desired = try await f.store.personalPreferenceTarget(accountID: f.account,
            fallback: .conversation(roomID: f.room, isPinned: false, isArchived: true, muteUntil: nil))
        #expect(desired == .conversation(roomID: f.room, isPinned: true, isArchived: false, muteUntil: nil))
        let ids = try await f.store.databasePool.read { try String.fetchAll($0, sql: "SELECT intent_id FROM v2_personal_preference_intents") }
        #expect(ids == [archive.uuidString])
        try await f.store.close()
    }

    @Test("failure to save a send rolls back its automatic unarchive")
    func failedSendDoesNotUnarchive() async throws {
        let f = try SendWorkFixture(); defer { f.remove() }
        try await f.store.enqueuePersonalPreference(accountID: f.account,
            target: .conversation(roomID: f.room, isPinned: false, isArchived: true, muteUntil: nil))
        try await confirmPreference(f, pinned: false, archived: true, mute: nil)
        try await f.store.databasePool.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_send BEFORE INSERT ON v2_send_intents BEGIN SELECT RAISE(ABORT,'send storage failure'); END")
        }
        await #expect(throws: DatabaseError.self) { try await f.store.freezeSendIntent(f.intent("not saved")) }
        let desired = try await f.store.personalPreferenceTarget(accountID: f.account,
            fallback: .conversation(roomID: f.room, isPinned: false, isArchived: false, muteUntil: nil))
        #expect(desired == .conversation(roomID: f.room, isPinned: false, isArchived: true, muteUntil: nil))
        #expect(try await f.store.preparingSendIntents().isEmpty)
        #expect(try await f.store.preparePersonalPreferences(accountID: f.account) == 0)
        try await f.store.close()
    }

    @Test("explicit resend of a proven-unsent message also restores its archived conversation")
    func resendingRestoresArchivedConversation() async throws {
        let f = try SendWorkFixture(); defer { f.remove() }
        let original = try f.intent("retry archived chat")
        try await f.store.freezeSendIntent(original)
        try await f.store.handOffSendIntent(original.id)
        let work = try await f.head()
        guard case .expiredUnsubmitted = try await f.store.claimOperationWork(id: work.id, ownerID: UUID(), action: .submit,
            now: Date().addingTimeInterval(2 * 86400)) else { Issue.record("Expected proven local expiry"); return }
        try await f.store.enqueuePersonalPreference(accountID: f.account,
            target: .conversation(roomID: f.room, isPinned: false, isArchived: true, muteUntil: nil))
        try await confirmPreference(f, pinned: false, archived: true, mute: nil)
        let replacement = try await f.store.replaceProvenUnsentSendIntent(original.id)
        #expect(replacement != original.id)
        let desired = try await f.store.personalPreferenceTarget(accountID: f.account,
            fallback: .conversation(roomID: f.room, isPinned: false, isArchived: true, muteUntil: nil))
        #expect(desired == .conversation(roomID: f.room, isPinned: false, isArchived: false, muteUntil: nil))
        #expect(try await f.store.replaceProvenUnsentSendIntent(original.id) == replacement)
        try await f.store.close()
    }

    private func confirmPreference(_ f: SendWorkFixture, pinned: Bool, archived: Bool, mute: Date?) async throws {
        #expect(try await f.store.preparePersonalPreferences(accountID: f.account) == 1)
        let work = try #require(try await f.store.dueOperationWork(now: .now, kinds: [.conversationPreference]).first)
        _ = try await f.claim(work)
        let command = try await f.store.personalPreferenceCommand(workID: work.id)
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let revision = command.expectedRevision.rawValue + 1
        let receipt = try V2PersonalPreferenceReceipt(identity: work.identity, fingerprint: work.fingerprint,
            outcome: .committed(.conversationState(.init(roomID: f.room, isPinned: pinned, isArchived: archived,
                muteUntil: mute, updatedAt: now, revision: .init(rawValue: revision)!))),
            resolvedAtMilliseconds: UInt64(now.timeIntervalSince1970 * 1000))
        try await f.store.completePersonalPreference(command: command, receipt: receipt, accountID: f.account)
        let payload = try JSONSerialization.data(withJSONObject: [
            "room_id": f.room.rawValue, "is_pinned": pinned, "is_archived": archived,
            "mute_until_ms": Int64((mute?.timeIntervalSince1970 ?? 0) * 1000),
            "updated_at_ms": Int64(now.timeIntervalSince1970 * 1000), "revision": revision
        ])
        _ = try await f.store.apply(.init(generation: 1,
            records: [.init(sequence: revision, sourceEventID: .init(uuid: UUID()), projectionKind: "conversation_state", payload: payload)],
            nextSyncToken: .init("archive-\(revision)"), receipt: .init("archive-\(revision)"), hasMore: false, capabilityProfile: "base"))
    }

    @Test("pending rows keep the original creation time through handoff and retries")
    func pendingCreationTimeSurvivesStatusChanges() async throws {
        let f = try SendWorkFixture(); defer { f.remove() }
        let created = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 5)
        let intent = try f.intent("ordered message")
        try await f.store.freezeSendIntent(intent, now: created)
        let preparing = try await f.store.pendingResourceSendSnapshot(in: f.room, page: 0)
        #expect(preparing.preparing.first?.createdAt == created)
        try await f.store.handOffSendIntent(intent.id)
        let work = try await f.head(), claim = try await f.claim(work)
        try await f.store.deferOperationWork(claim, until: .now, code: "UNKNOWN", scheduling: .needsAttention, nextAction: .reconcile)
        let failed = try await f.store.pendingResourceSendSnapshot(in: f.room, page: 0)
        #expect(failed.submitted.first?.createdAt == created)
        try await V2MessageSendOperationService(accountID: f.account, store: f.store, client: f.remote).resumeConfirmation(intentID: intent.id)
        #expect(try await f.store.submittedSendIntents(in: f.room).first?.createdAt == created)
        try await f.store.close()
    }

    @Test("a send paused for manual confirmation does not block later messages", arguments: [true, false])
    func pausedSendDoesNotFreezeConversation(paused: Bool) async throws {
        let f = try SendWorkFixture(); defer { f.remove() }
        let first = try f.intent("unknown original")
        try await f.store.freezeSendIntent(first)
        try await f.store.handOffSendIntent(first.id)
        let original = try await f.head(), claim = try await f.claim(original)
        try await f.store.deferOperationWork(claim, until: Date().addingTimeInterval(600), code: "MESSAGE_SEND_UNRESOLVED",
            scheduling: paused ? .needsAttention : .backingOff, nextAction: .reconcile)
        let retained = try #require(try await f.store.operationWork(id: original.id))
        let next = try f.intent("new message")
        try await f.store.freezeSendIntent(next)
        try await f.store.handOffSendIntent(next.id)
        let due = try await f.store.dueOperationWork(now: .now, kinds: [.sendMessage])
        if paused {
            let work = try #require(due.first)
            #expect(work.intentID == next.id)
            let sending = try await f.claim(work)
            let command = try await f.store.messageSendCommand(workID: work.id)
            let receipt = try V2MessageSendOperationReceipt(identity: command.identity, fingerprint: command.fingerprint,
                outcome: .accepted(.init(messageID: .init(uuid: UUID()), roomSequence: 3)),
                resolvedAtMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000))
            try await f.store.completeMessageSend(command, receipt: receipt)
            #expect(sending.work.intentID == next.id)
            #expect(try await f.store.operationWork(id: work.id)?.execution == .committed)
        } else {
            // An actively recovering earlier send still preserves normal ordering.
            #expect(due.isEmpty)
        }
        #expect(try await f.store.operationWork(id: original.id) == retained)
        try await f.store.close()
    }

    @Test("pending presentation distinguishes network and authentication waits", arguments: [true, false])
    func pendingPresentationReflectsTransport(network: Bool) async throws {
        let f = try SendWorkFixture(); defer { f.remove() }
        let intent = try f.intent("parked message")
        try await f.store.freezeSendIntent(intent)
        try await f.store.handOffSendIntent(intent.id)
        let work = try await f.head(), claim = try await f.claim(work)
        try await f.store.deferOperationWork(claim, until: .now, code: "WAITING",
            scheduling: network ? .waitingForNetwork : .waitingForAuthentication, nextAction: .submit)
        let presentation = try await f.store.submittedSendIntents(in: f.room)
        #expect(presentation.first?.status == (network ? .waitingForNetwork : .waitingForAuthentication))
        try await f.store.close()
    }

    @Test("offline work survives reopening and resumes the frozen command without a manual retry")
    func offlineWorkResumesAfterColdConnection() async throws {
        let f = try SendWorkFixture(); defer { f.remove() }
        let intent = try f.intent("offline original body")
        try await f.store.freezeSendIntent(intent)
        try await f.store.handOffSendIntent(intent.id)
        let original = try await f.head()
        let command = try await f.store.messageSendCommand(workID: original.id)
        try await V2MessageSendOperationService(accountID: f.account, store: f.store,
            client: FailingSendWorkRemote(failure: .unavailableBeforeSubmission)).execute(f.claim(original))
        #expect(try await f.store.operationWork(id: original.id)?.scheduling == .waitingForNetwork)
        #expect(try await f.store.dueOperationWork(now: .distantFuture, kinds: [.sendMessage]).isEmpty)
        try await f.store.close()
        let restored = try GRDBV2LocalSyncStore(databaseURL: f.url, installationBinding: f.binding, userID: f.account)
        try await restored.resumeNetworkWaitingMessageSends(accountID: f.account)
        let ready = try #require(try await restored.operationWork(id: original.id))
        #expect(ready.scheduling == .ready && ready.nextAction == .submit)
        #expect(ready.submissionRoundAttempts == 0)
        #expect(try await restored.messageSendCommand(workID: original.id) == command)
        guard case .claimed(let claim) = try await restored.claimOperationWork(id: ready.id, ownerID: UUID(), action: ready.nextAction, now: ready.nextActionAt)
        else { throw V2OperationWorkError.invalidTransition }
        try await restored.resumeNetworkWaitingMessageSends(accountID: f.account)
        #expect(try await restored.operationWork(id: original.id)?.submissionRoundAttempts == 1)
        let service = V2MessageSendOperationService(accountID: f.account, store: restored, client: f.remote)
        try await service.execute(claim)
        let unknown = try #require(try await restored.operationWork(id: original.id))
        guard case .claimed(let query) = try await restored.claimOperationWork(id: unknown.id, ownerID: UUID(), action: unknown.nextAction, now: unknown.nextActionAt)
        else { throw V2OperationWorkError.invalidTransition }
        try await service.execute(query)
        #expect(try await restored.operationWork(id: original.id)?.execution == .committed)
        #expect(try await restored.messageSendCommand(workID: original.id) == command)
        let submissions = await f.remote.submissions, recoveries = await f.remote.recoveries
        #expect(submissions == 1 && recoveries == 1)
        try await restored.close()
    }

    @Test("connection recovery observes both preexisting and late parked commands", arguments: [false, true])
    func networkWakeupDoesNotLoseLateParking(parkFirst: Bool) async throws {
        let f = try SendWorkFixture(); defer { f.remove() }
        let intent = try f.intent("connection race")
        try await f.store.freezeSendIntent(intent)
        try await f.store.handOffSendIntent(intent.id)
        let work = try await f.head(), claim = try await f.claim(work)
        let park = {
            try await f.store.deferOperationWork(claim, until: Date(), code: "MESSAGE_SEND_TRANSPORT_UNAVAILABLE",
                                               scheduling: .waitingForNetwork, nextAction: .reconcile)
        }
        if parkFirst { try await park() }
        let runner = Task {
            try await V2MessageSendNetworkRecoveryRunner(store: f.store, accountID: f.account, isAuthenticated: { true }).run()
        }
        defer { runner.cancel() }
        if !parkFirst { try await park() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await f.store.operationWork(id: work.id)?.scheduling != .ready {
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }
        let ready = try #require(try await f.store.operationWork(id: work.id))
        #expect(ready.identity == work.identity && ready.fingerprint == work.fingerprint)
        #expect(ready.nextAction == .reconcile)
        for _ in 0..<3 {
            let next = try await f.claim(try #require(try await f.store.operationWork(id: work.id)))
            try await f.store.deferOperationWork(next, until: Date(), code: "MESSAGE_SEND_TRANSPORT_UNAVAILABLE",
                                               scheduling: .waitingForNetwork, nextAction: .reconcile)
            let wakeDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while try await f.store.operationWork(id: work.id)?.scheduling != .ready {
                try #require(ContinuousClock.now < wakeDeadline)
                await Task.yield()
            }
        }
        runner.cancel()
        _ = await runner.result
        try await f.store.close()
    }

    @Test("fresh authentication wakes legacy transport-paused work but keeps its recovery action")
    func legacyTransportPauseCanResume() async throws {
        let f = try SendWorkFixture(); defer { f.remove() }
        let intent = try f.intent("legacy parked identity")
        try await f.store.freezeSendIntent(intent)
        try await f.store.handOffSendIntent(intent.id)
        let work = try await f.head(), claim = try await f.claim(work)
        try await f.store.deferOperationWork(claim, until: Date(), code: "MESSAGE_SEND_TRANSPORT_UNAVAILABLE",
                                           scheduling: .needsAttention, nextAction: .reconcile)
        try await f.store.resumeNetworkWaitingMessageSends(accountID: f.account)
        let resumed = try #require(try await f.store.operationWork(id: work.id))
        #expect(resumed.scheduling == .ready && resumed.nextAction == .reconcile)
        #expect(resumed.identity == work.identity && resumed.fingerprint == work.fingerprint)
        #expect(resumed.admissionDeadline == work.admissionDeadline)
        try await f.store.close()
    }

    @Test("connection wakeup excludes unknown outcomes and capacity failures", arguments: [false, true])
    func networkWakeupPreservesOtherFailureBoundaries(capacity: Bool) async throws {
        let f = try SendWorkFixture(); defer { f.remove() }
        let intent = try f.intent("other failure")
        try await f.store.freezeSendIntent(intent)
        try await f.store.handOffSendIntent(intent.id)
        let work = try await f.head()
        let failure: V2MessageSendTransportError = capacity ? .busyBeforeSubmission(Date().addingTimeInterval(3)) : .outcomeUnknown
        try await V2MessageSendOperationService(accountID: f.account, store: f.store,
            client: FailingSendWorkRemote(failure: failure)).execute(f.claim(work))
        let before = try #require(try await f.store.operationWork(id: work.id))
        try await f.store.resumeNetworkWaitingMessageSends(accountID: f.account)
        let after = try #require(try await f.store.operationWork(id: work.id))
        #expect(after.revision == before.revision && after.nextActionAt == before.nextActionAt)
        #expect(after.nextAction == (capacity ? .submit : .reconcile))
        #expect(after.scheduling == .backingOff)
        await #expect(throws: V2OperationWorkError.accountMismatch) {
            try await f.store.resumeNetworkWaitingMessageSends(accountID: .init(uuid: UUID()))
        }
        try await f.store.close()
    }

    @Test("an unknown last submission starts the independent reconciliation round", arguments: [false, true])
    func exhaustedSubmissionStillReconcilesOriginalIdentity(typedTransportFailure: Bool) async throws {
        let fixture = try SendWorkFixture(); defer { fixture.remove() }
        let intent = try fixture.intent("retained unknown result")
        try await fixture.store.freezeSendIntent(intent)
        try await fixture.store.handOffSendIntent(intent.id)
        let original = try await fixture.head()
        let command = try await fixture.store.messageSendCommand(workID: original.id)
        for _ in 0..<4 {
            let work = try #require(try await fixture.store.operationWork(id: original.id))
            let claim = try await fixture.claim(work)
            try await V2MessageSendOperationService(accountID: fixture.account, store: fixture.store,
                client: CorrelatedRejectedSendWorkRemote(code: "SERVER_BUSY")).execute(claim)
        }
        let last = try await fixture.claim(try #require(try await fixture.store.operationWork(id: original.id)))
        let remote = SendWorkRemote(failure: typedTransportFailure ? V2MessageSendTransportError.outcomeUnknown : URLError(.networkConnectionLost))
        try await V2MessageSendOperationService(accountID: fixture.account, store: fixture.store, client: remote).execute(last)
        let unknown = try #require(try await fixture.store.operationWork(id: original.id))
        #expect(unknown.submissionRoundAttempts == 5)
        #expect(unknown.nextAction == .reconcile)
        #expect(unknown.scheduling == .backingOff)
        #expect(unknown.reconciliationRoundAttempts == 0)
        #expect(try await fixture.store.messageSendCommand(workID: original.id) == command)
        let recovery = try await fixture.claim(unknown)
        try await V2MessageSendOperationService(accountID: fixture.account, store: fixture.store, client: remote).execute(recovery)
        #expect(try await fixture.store.operationWork(id: original.id)?.execution == .committed)
        #expect(await remote.submissions == 1)
        #expect(await remote.recoveries == 1)
        try await fixture.store.close()
    }

    @Test(arguments: [V2MessageSendTransportError.unavailableBeforeSubmission, .outcomeUnknown])
    func transportCertaintyPersistsNextAction(_ failure: V2MessageSendTransportError) async throws {
        let fixture = try SendWorkFixture(); defer { fixture.remove() }
        let intent = try fixture.intent("same frozen payload")
        try await fixture.store.freezeSendIntent(intent)
        try await fixture.store.handOffSendIntent(intent.id)
        let work = try await fixture.head()
        let claim = try await fixture.claim(work)
        let remote = FailingSendWorkRemote(failure: failure)
        try await V2MessageSendOperationService(accountID: fixture.account, store: fixture.store, client: remote).execute(claim)
        let current = try #require(try await fixture.store.operationWork(id: work.id))
        #expect(current.nextAction == (failure == .unavailableBeforeSubmission ? .submit : .reconcile))
        #expect(current.identity == work.identity)
        #expect(current.fingerprint == work.fingerprint)
        #expect(await remote.submissions == 1)
        try await fixture.store.close()
    }
    @Test("correlated TCP busy preserves the claim action; ambiguous unavailable reconciles",
          arguments: ["SERVER_BUSY", "UNAVAILABLE"], [V2OperationWorkAction.submit, .reconcile])
    func correlatedTCPRejectionPreservesIdentityAndRetryFloor(code: String, action: V2OperationWorkAction) async throws {
        let fixture = try SendWorkFixture(); defer { fixture.remove() }
        let intent = try fixture.intent("same frozen TCP operation")
        try await fixture.store.freezeSendIntent(intent)
        try await fixture.store.handOffSendIntent(intent.id)
        let work = try await fixture.head()
        var claim = try await fixture.claim(work)
        if action == .reconcile {
            try await fixture.store.deferOperationWork(claim, until: Date(), code: "prior unknown", nextAction: .reconcile)
            let current = try #require(try await fixture.store.operationWork(id: work.id))
            claim = try await fixture.claim(current)
        }
        let before = Date()
        let remote = CorrelatedRejectedSendWorkRemote(code: code)
        try await V2MessageSendOperationService(accountID: fixture.account, store: fixture.store, client: remote).execute(claim)
        let current = try #require(try await fixture.store.operationWork(id: work.id))
        #expect(current.nextAction == (code == "SERVER_BUSY" ? action : .reconcile))
        #expect(current.nextActionAt >= before.addingTimeInterval(3))
        #expect(current.identity == work.identity)
        #expect(current.fingerprint == work.fingerprint)
        #expect(try await fixture.store.messageSendCommand(workID: work.id).identity == work.identity)
        #expect(current.scheduling == .backingOff)
        try await fixture.store.close()
    }

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
                    outcome: .rejected(.permissionDenied), resolvedAtMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000))
                try await f.store.completeOperationWork(.init(identity: receipt.identity, fingerprint: receipt.fingerprint, state: .rejected, receipt: receipt), now: Date())
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
    @Test("preparation does not renew the original bounded first submission deadline")
    func delayedPreparation() async throws {
        let f=try SendWorkFixture();defer { f.remove() }
        let created=Date().addingTimeInterval(-90_000),intent=try f.intent("stale draft")
        try await f.store.freezeSendIntent(intent,now:created)
        try await f.store.handOffSendIntent(intent.id)
        let work=try await f.head(),command=try await f.store.messageSendCommand(workID:work.id)
        #expect(command.firstSubmissionDeadlineMilliseconds == UInt64(created.timeIntervalSince1970*1_000)+86_395_000)
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

private actor FailingSendWorkRemote: V2MessageSendOperationClient {
    let failure: V2MessageSendTransportError
    var submissions = 0
    init(failure: V2MessageSendTransportError) { self.failure = failure }
    func submit(_: V2MessageSendOperationCommand) throws -> V2MessageSendOperationRecoveryResult {
        submissions += 1
        throw failure
    }
    func recover(_: V2MessageSendOperationRecoveryRequest) throws -> V2MessageSendOperationRecoveryResult { throw failure }
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
    private let failure: any Error
    init(failure: any Error = URLError(.networkConnectionLost)) { self.failure = failure }
    var submissions=0,recoveries=0
    var receipt:V2MessageSendOperationReceipt?
    func submit(_ command:V2MessageSendOperationCommand) async throws -> V2MessageSendOperationRecoveryResult {
        submissions += 1
        receipt=try .init(identity:command.identity,fingerprint:command.fingerprint,
            outcome:.accepted(.init(messageID:.init(uuid:UUID()),roomSequence:2)),resolvedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1_000))
        throw failure
    }
    func recover(_ request:V2MessageSendOperationRecoveryRequest) async throws -> V2MessageSendOperationRecoveryResult {
        recoveries += 1
        guard let receipt else { return .unresolved }
        return .receipt(receipt)
    }
}

private struct CorrelatedRejectedSendWorkRemote: V2MessageSendOperationClient {
    let code: String
    func submit(_ command: V2MessageSendOperationCommand) throws -> V2MessageSendOperationRecoveryResult {
        try rejected(identity: command.identity, fingerprint: command.fingerprint)
    }
    func recover(_ request: V2MessageSendOperationRecoveryRequest) throws -> V2MessageSendOperationRecoveryResult {
        try rejected(identity: request.identity, fingerprint: request.fingerprint)
    }
    private func rejected(identity: V2OperationIdentity, fingerprint: V2OperationFingerprint) throws -> V2MessageSendOperationRecoveryResult {
        var response = IMV2Envelope()
        response.error.code = code
        response.error.retryable = true
        response.error.retryAfterSeconds = 3
        return try V2ProtobufMessageSendOperationClient.decodeCorrelatedResponse(response,
            identity: identity, fingerprint: fingerprint)
    }
}

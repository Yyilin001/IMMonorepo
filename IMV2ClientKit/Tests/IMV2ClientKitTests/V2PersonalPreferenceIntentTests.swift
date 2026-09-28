import Foundation
import GRDB
import Testing
import IMV2Core
@testable import IMV2ClientKit

struct V2PersonalPreferenceIntentTests {
    private func fixture() throws -> (GRDBV2LocalSyncStore, UserID) {
        let user = try UserID("preferences-user")
        return (try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "preferences-\(UUID()).sqlite"),
            installationBinding: .init(value: UUID()), userID: user), user)
    }
    private func claim(_ work: V2OperationWork, store: GRDBV2LocalSyncStore, now: Date) async throws -> V2OperationWorkClaim {
        guard case .claimed(let result) = try await store.claimOperationWork(id: work.id, ownerID: UUID(), action: work.nextAction, now: now) else { throw V2OperationWorkError.invalidTransition }
        return result
    }
    @Test func queuedIntentFreezesAfterPredecessorReceiptAndOtherKeysProceed() async throws {
        let (store, user) = try fixture(), now = Date()
        let room = try RoomID("room-a")
        _ = try await store.enqueuePersonalPreference(accountID: user, target: .conversation(roomID: room, isPinned: true, isArchived: false, muteUntil: nil), now: now)
        #expect(try await store.preparePersonalPreferences(accountID: user, now: now) == 1)
        let second = try await store.enqueuePersonalPreference(accountID: user, target: .conversation(roomID: room, isPinned: false, isArchived: true, muteUntil: nil), now: now)
        _ = try await store.enqueuePersonalPreference(accountID: user, target: .favorite(roomID: room, messageID: .init("message-a"), isFavorited: true), now: now)
        #expect(try await store.preparePersonalPreferences(accountID: user, now: now) == 1)
        let due = try await store.dueOperationWork(now: now)
        #expect(due.count == 2)
        let first = try #require(due.first { $0.identity.kind == .conversationPreference })
        let command = try await store.personalPreferenceCommand(workID: first.id)
        #expect(command.expectedRevision == .initial)
        let flight = try await claim(first, store: store, now: now)
        try await store.deferOperationWork(flight, until: now.addingTimeInterval(30), code: "LOST_ACK")
        #expect(try await store.preparePersonalPreferences(accountID: user, now: now) == 0)
        let receipt = try V2PersonalPreferenceReceipt(identity: first.identity, fingerprint: first.fingerprint,
            outcome: .committed(.conversationState(.init(roomID: room, isPinned: true, isArchived: false, muteUntil: nil, updatedAt: now, revision: .init(rawValue: 1)!))),
            resolvedAtMilliseconds: UInt64(now.timeIntervalSince1970 * 1000))
        try await store.completePersonalPreference(command: command, receipt: receipt, accountID: user, now: now)
        #expect(try await store.preparePersonalPreferences(accountID: user, now: now) == 1)
        let next = try #require(try await store.dueOperationWork(now: now).first { $0.intentID == second })
        #expect(try await store.personalPreferenceCommand(workID: next.id).expectedRevision.rawValue == 1)
        #expect(try await store.operationWork(id: first.id)?.execution == .committed)
        try await store.close()
    }
    @Test func unfrozenTargetCoalescesWithoutRenewingOriginalDeadline() async throws {
        let (store, user) = try fixture(), now = Date(), room = try RoomID("coalesced-room")
        let first = try await store.enqueuePersonalPreference(accountID: user,
            target: .favorite(roomID: room, messageID: .init("message"), isFavorited: true), now: now)
        let second = try await store.enqueuePersonalPreference(accountID: user,
            target: .favorite(roomID: room, messageID: .init("message"), isFavorited: false), now: now.addingTimeInterval(60))
        #expect(second == first)
        let deadline = try await store.databasePool.read { db in
            try Double.fetchOne(db, sql: "SELECT deadline FROM v2_personal_preference_intents WHERE intent_id=?", arguments: [first.uuidString])
        }
        #expect(deadline == now.addingTimeInterval(7 * 86400).timeIntervalSince1970)
        #expect(try await store.preparePersonalPreferences(accountID: user, now: now.addingTimeInterval(61)) == 1)
        let work = try #require(try await store.dueOperationWork(now: now.addingTimeInterval(61)).first)
        guard case .favorite(let command) = try await store.personalPreferenceCommand(workID: work.id) else { Issue.record("wrong command"); return }
        #expect(!command.isFavorited)
        #expect(command.operationID.rawValue == first.uuidString)
        try await store.close()
    }
    @Test func desiredStateUsesLiveIntentAndDoesNotResurrectDiscardedTarget() async throws {
        let (store, user) = try fixture(), now = Date(), room = try RoomID("desired-room")
        let original: V2PersonalPreferenceTarget = .conversation(roomID: room, isPinned: false, isArchived: false, muteUntil: nil)
        let changed: V2PersonalPreferenceTarget = .conversation(roomID: room, isPinned: true, isArchived: false, muteUntil: nil)
        let id = try await store.enqueuePersonalPreference(accountID: user, target: changed, now: now)
        #expect(try await store.personalPreferenceTarget(accountID: user, fallback: original, now: now) == changed)
        try await store.discardPersonalPreference(id: id, accountID: user)
        #expect(try await store.personalPreferenceTarget(accountID: user, fallback: original, now: now) == original)
        try await store.close()
    }
    @Test func unknownCannotBeDiscardedAndExplicitContinuationPreservesCooldown() async throws {
        let (store, user) = try fixture(), now = Date()
        let id = try await store.enqueuePersonalPreference(accountID: user,
            target: .favorite(roomID: .init("room"), messageID: .init("message"), isFavorited: true), now: now)
        #expect(try await store.preparePersonalPreferences(accountID: user, now: now) == 1)
        let work = try #require(try await store.dueOperationWork(now: now).first)
        let flight = try await claim(work, store: store, now: now)
        let floor = now.addingTimeInterval(7200)
        try await store.deferOperationWork(flight, until: floor, code: "RETRY_AFTER", scheduling: .needsAttention)
        await #expect(throws: V2OperationWorkError.invalidTransition) { try await store.discardPersonalPreference(id: id, accountID: user) }
        await #expect(throws: V2OperationWorkError.accountMismatch) { try await store.resumePersonalPreference(id: id, accountID: .init("other"), now: now) }
        var iterator = store.personalPreferencePendingUpdates(accountID: user).makeAsyncIterator()
        let pending = try #require(try await iterator.next()?.first)
        #expect(pending.id == id && pending.canResume && !pending.canDiscard)
        try await store.resumePersonalPreference(id: id, accountID: user, now: now)
        let resumed = try #require(try await store.operationWork(id: work.id))
        #expect(resumed.identity == work.identity && resumed.fingerprint == work.fingerprint)
        #expect(resumed.nextAction == .reconcile)
        #expect(resumed.nextActionAt.timeIntervalSince1970 == floor.timeIntervalSince1970)
        #expect(resumed.attemptCount == 1)
        try await store.close()
    }
    @Test func unsubmittedDiscardDoesNotDeleteOtherIntent() async throws {
        let (store, user) = try fixture(), now = Date()
        let first = try await store.enqueuePersonalPreference(accountID: user,
            target: .favorite(roomID: .init("room"), messageID: .init("first"), isFavorited: true), now: now)
        let other = try await store.enqueuePersonalPreference(accountID: user,
            target: .favorite(roomID: .init("room"), messageID: .init("other"), isFavorited: true), now: now)
        try await store.discardPersonalPreference(id: first, accountID: user)
        #expect(try await store.preparePersonalPreferences(accountID: user, now: now) == 1)
        #expect(try await store.dueOperationWork(now: now).map(\.intentID) == [other])
        try await store.close()
    }
    @Test func removingCommittedHistoryPreservesConfirmedValueAheadOfProjection() async throws {
        let (store, user) = try fixture(), now = Date(), room = try RoomID("room"), message = try MessageID("message")
        let target: V2PersonalPreferenceTarget = .favorite(roomID: room, messageID: message, isFavorited: true)
        let fallback: V2PersonalPreferenceTarget = .favorite(roomID: room, messageID: message, isFavorited: false)
        let id = try await store.enqueuePersonalPreference(accountID: user, target: target, now: now)
        _ = try await store.preparePersonalPreferences(accountID: user, now: now)
        let work = try #require(try await store.dueOperationWork(now: now).first)
        _ = try await claim(work, store: store, now: now)
        let command = try await store.personalPreferenceCommand(workID: work.id)
        let receipt = try V2PersonalPreferenceReceipt(identity: work.identity, fingerprint: work.fingerprint,
            outcome: .committed(.messageFavorite(.init(roomID: room, messageID: message, isFavorited: true, updatedAt: now, revision: .init(rawValue: 1)!))), resolvedAtMilliseconds: 1)
        try await store.completePersonalPreference(command: command, receipt: receipt, accountID: user, now: now)
        try await store.discardPersonalPreference(id: id, accountID: user)
        #expect(try await store.operationWork(id: work.id) == nil)
        #expect(try await store.personalPreferenceTarget(accountID: user, fallback: fallback) == target)
        try await store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_message_favorites(message_id,room_id,is_favorited,updated_at,revision) VALUES(?,?,0,?,2)", arguments: [message.rawValue, room.rawValue, now.timeIntervalSince1970])
        }
        // A newer device's confirmed projection also wins over a stale page.
        #expect(try await store.personalPreferenceTarget(accountID: user, fallback: target) == fallback)
        try await store.close()
    }
    @Test func sharedCapacityIncludesUnfrozenIntentsAndExpiryIsLocalOnly() async throws {
        let (store, user) = try fixture(), now = Date()
        _ = try await store.enqueuePersonalPreference(accountID: user, target: .favorite(roomID: .init("room"), messageID: .init("message"), isFavorited: true), now: now)
        await #expect(throws: V2OperationWorkError.capacityExceeded) {
            try await store.databasePool.read { db in
                try GRDBV2LocalSyncStore.requireOperationCapacity(adding: 1, limits: .init(maximumActiveCount: 1), db: db)
            }
        }
        #expect(try await store.preparePersonalPreferences(accountID: user, now: now.addingTimeInterval(7 * 86400 + 1)) == 1)
        #expect(try await store.dueOperationWork(now: now.addingTimeInterval(7 * 86400 + 1)).isEmpty)
        #expect(try await store.personalPreferencePreparationSchedule().nextAttemptAt() == nil)
        try await store.close()
    }
    @Test func admittedDraftCanFreezeAtFullAccountByteQuota() async throws {
        let (store, user) = try fixture(), now = Date()
        let id = try await store.enqueuePersonalPreference(accountID: user,
            target: .favorite(roomID: .init("quota-room"), messageID: .init("quota-message"), isFavorited: true), now: now)
        let reservation = try await store.databasePool.read { db in
            try Int64.fetchOne(db, sql: "SELECT payload_bytes FROM v2_personal_preference_intents WHERE intent_id=?", arguments: [id.uuidString])!
        }
        // Model unrelated admitted work filling every remaining byte. No payload
        // allocation or network call is needed to exercise the admission boundary.
        let blocker = UUID()
        let identity = try V2OperationIdentity(accountID: user, scope: .account(user), operation: .profileUpdate(.init(uuid: blocker)))
        let fingerprint = try V2OperationFingerprint(kind: .profileUpdate, fields: [.init("fixture", .text("quota"))])
        try await store.databasePool.write { db in
            _ = try GRDBV2LocalSyncStore.insertOperationWork(.init(id: blocker, intentID: blocker,
                identity: identity, fingerprint: fingerprint, orderingKey: "quota-blocker",
                payloadBytes: V2OperationWorkLimits().maximumPayloadBytes - reservation,
                admissionDeadline: nil), now: now, db: db)
            try GRDBV2LocalSyncStore.requireOperationCapacity(adding: 0, db: db)
        }
        await #expect(throws: V2OperationWorkError.capacityExceeded) {
            try await store.databasePool.read { db in
                try GRDBV2LocalSyncStore.requireOperationCapacity(adding: 1, db: db)
            }
        }
        #expect(try await store.preparePersonalPreferences(accountID: user, now: now) == 1)
        let frozen = try #require(try await store.dueOperationWork(now: now).first { $0.intentID == id })
        #expect(try await store.personalPreferenceCommand(workID: frozen.id).expectedRevision == .initial)
        try await store.close()
    }
    @Test func unknownSubmissionRecoversOriginalReceiptWithoutSendingNewIdentity() async throws {
        let (store, user) = try fixture(), now = Date()
        let remote = LostAcknowledgementPreferenceServer(accountID: user)
        let service = V2PersonalPreferenceService(accountID: user, store: store, transport: remote, recovery: remote)
        _ = try await service.enqueue(.favorite(roomID: .init("room"), messageID: .init("message"), isFavorited: true))
        _ = try await store.preparePersonalPreferences(accountID: user, now: now)
        let work = try #require(try await store.dueOperationWork(now: now).first)
        try await service.execute(claim(work, store: store, now: now))
        let unknown = try #require(try await store.operationWork(id: work.id))
        #expect(unknown.execution == .awaitingConfirmation)
        #expect(unknown.nextAction == .reconcile)
        try await service.execute(claim(unknown, store: store, now: unknown.nextActionAt))
        #expect(try await store.operationWork(id: work.id)?.execution == .committed)
        #expect(await remote.submissions == 1)
        #expect(await remote.queries == 1)
        try await store.close()
    }
    @Test func invalidReceiptNeverSettlesUnknownCommand() async throws {
        let (store, user) = try fixture(), now = Date()
        _ = try await store.enqueuePersonalPreference(accountID: user, target: .favorite(roomID: .init("room"), messageID: .init("message"), isFavorited: true), now: now)
        _ = try await store.preparePersonalPreferences(accountID: user, now: now)
        let work = try #require(try await store.dueOperationWork(now: now).first)
        _ = try await claim(work, store: store, now: now)
        let command = try await store.personalPreferenceCommand(workID: work.id)
        let receipt = try V2PersonalPreferenceReceipt(identity: work.identity, fingerprint: work.fingerprint,
            outcome: .committed(.messageFavorite(.init(roomID: .init("room"), messageID: .init("message"), isFavorited: false,
                updatedAt: now, revision: .init(rawValue: 1)!))), resolvedAtMilliseconds: 1)
        await #expect(throws: V2OperationWorkError.identityConflict) { try await store.completePersonalPreference(command: command, receipt: receipt, accountID: user) }
        #expect(try await store.operationWork(id: work.id)?.scheduling == .claimed)
        try await store.close()
    }

    @Test func staleProjectionCannotRegressRevisionAndEqualRevisionMustAgree() async throws {
        let (store, _) = try fixture()
        func apply(sequence: UInt64, revision: Int, pinned: Bool) async throws {
            let payload = try JSONSerialization.data(withJSONObject: ["room_id": "room", "is_pinned": pinned,
                "is_archived": false, "mute_until_ms": 0, "updated_at_ms": revision * 1000, "revision": revision])
            _ = try await store.apply(.init(generation: 1,
                records: [.init(sequence: sequence, sourceEventID: .init(UUID().uuidString), projectionKind: "conversation_state", payload: payload)],
                nextSyncToken: .init("token-\(sequence)"), receipt: .init("receipt-\(sequence)"), hasMore: false, capabilityProfile: "base"))
        }
        try await apply(sequence: 1, revision: 2, pinned: true)
        try await apply(sequence: 2, revision: 1, pinned: false)
        #expect(try await store.conversationState(roomID: .init("room"))?.revision.rawValue == 2)
        #expect(try await store.conversationState(roomID: .init("room"))?.isPinned == true)
        await #expect(throws: (any Error).self) { try await apply(sequence: 3, revision: 2, pinned: false) }
        #expect(try await store.conversationState(roomID: .init("room"))?.isPinned == true)
        try await store.close()
    }
}

private actor LostAcknowledgementPreferenceServer: V2ClientConversationCapabilitiesTransport, V2PersonalPreferenceRecovering {
    let accountID: UserID
    var receipt: V2PersonalPreferenceReceipt?
    var submissions = 0, queries = 0
    init(accountID: UserID) { self.accountID = accountID }
    func setConversationState(command: V2ConversationStateCommand) async throws -> V2PersonalPreferenceReceipt { throw V2OperationWorkError.invalidTransition }
    func setMessageFavorite(command: V2MessageFavoriteCommand) async throws -> V2PersonalPreferenceReceipt {
        submissions += 1
        receipt = try .init(identity: command.identity(actorUserID: accountID), fingerprint: command.fingerprint(actorUserID: accountID),
            outcome: .committed(.messageFavorite(.init(roomID: command.roomID, messageID: command.messageID, isFavorited: command.isFavorited,
                updatedAt: Date(), revision: .init(rawValue: command.expectedRevision.rawValue + 1)!))), resolvedAtMilliseconds: 1)
        throw URLError(.networkConnectionLost)
    }
    func recover(_ request: V2PersonalPreferenceRecoveryRequest) async throws -> V2PersonalPreferenceRecoveryResult {
        queries += 1
        let receipt = try #require(receipt)
        #expect(request.identity == receipt.identity && request.fingerprint == receipt.fingerprint)
        return .receipt(receipt)
    }
}

import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Local-first direct conversation journal", .serialized)
struct V2LocalDirectMessageTests {
    @Test func offlineMessagesSurviveReopeningAndHandoffOnlyAfterRoomReceipt() async throws {
        let f = try SendWorkFixture(); defer { f.remove() }
        let service = V2DirectRoomOperationService(accountID: f.account, store: f.store, client: LocalDirectUnusedRemote())
        let identity = try peer()
        let workID = try await service.enqueue(publicIdentity: identity)
        #expect(try await service.enqueue(publicIdentity: identity) == workID)
        try await service.enqueueLocalMessage(text: "offline first", workID: workID)
        try await service.enqueueLocalMessage(text: "offline second", workID: workID)
        let messages = try await service.localMessages(workID: workID)
        #expect(messages.map(\.text) == ["offline first", "offline second"])
        try await service.prepareLocalMessages()
        #expect(try await f.store.preparingSendIntents().isEmpty)
        try await f.store.close()
        let restored = try GRDBV2LocalSyncStore(databaseURL: f.url, installationBinding: f.binding, userID: f.account)
        let resumed = V2DirectRoomOperationService(accountID: f.account, store: restored, client: LocalDirectUnusedRemote())
        #expect(try await resumed.localMessages(workID: workID) == messages)
        try await complete(workID, room: f.room, store: restored)
        try await resumed.prepareLocalMessages()
        #expect(try await resumed.localMessages(workID: workID).isEmpty)
        let sends = try await restored.preparingSendIntents()
        #expect(Set(sends.map(\.id)) == Set(messages.map(\.id)))
        #expect(sends.allSatisfy { $0.roomID == f.room && $0.clientMessageID.rawValue == $0.id.uuidString })
        try await resumed.prepareLocalMessages()
        #expect(try await restored.preparingSendIntents().count == 2)
        try await restored.close()
    }

    @Test func crashBetweenFreezeAndDeletionReusesTheOriginalSendIntent() async throws {
        let f = try SendWorkFixture(); defer { f.remove() }
        let service = V2DirectRoomOperationService(accountID: f.account, store: f.store, client: LocalDirectUnusedRemote())
        let workID = try await service.enqueue(publicIdentity: peer())
        try await service.enqueueLocalMessage(text: "only once", workID: workID)
        let message = try #require(try await service.localMessages(workID: workID).first)
        try await complete(workID, room: f.room, store: f.store)
        let intent = try V2SendIntent(id: message.id, roomID: f.room, clientMessageID: .init(message.id.uuidString), text: message.text, attachmentJobIDs: [])
        try await f.store.freezeMetadataSendIntent(intent, now: message.createdAt)
        try await service.prepareLocalMessages()
        #expect(try await f.store.preparingSendIntents().map(\.id) == [message.id])
        #expect(try await service.localMessages(workID: workID).isEmpty)
        try await f.store.close()
    }

    @Test func failedStorageKeepsMessagesAndCrossAccountWritesAreRejected() async throws {
        let f = try SendWorkFixture(); defer { f.remove() }
        let service = V2DirectRoomOperationService(accountID: f.account, store: f.store, client: LocalDirectUnusedRemote())
        let workID = try await service.enqueue(publicIdentity: peer())
        let other = V2DirectRoomOperationService(accountID: .init(uuid: UUID()), store: f.store, client: LocalDirectUnusedRemote())
        await #expect(throws: V2OperationWorkError.accountMismatch) { try await other.enqueueLocalMessage(text: "wrong account", workID: workID) }
        try await service.enqueueLocalMessage(text: "retained", workID: workID)
        try await complete(workID, room: f.room, store: f.store)
        #expect(try await f.store.pruneCompletedOperationHistory(now: Date().addingTimeInterval(8 * 86400)) == 0)
        try await f.store.databasePool.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_local_handoff BEFORE INSERT ON v2_send_intents BEGIN SELECT RAISE(ABORT,'simulated disk failure'); END")
        }
        await #expect(throws: DatabaseError.self) { try await service.prepareLocalMessages() }
        #expect(try await service.localMessages(workID: workID).map(\.text) == ["retained"])
        try await f.store.databasePool.write { try $0.execute(sql: "DROP TRIGGER fail_local_handoff") }
        try await service.prepareLocalMessages()
        #expect(try await service.localMessages(workID: workID).isEmpty)
        try await f.store.close()
    }

    @Test func explicitRetryKeepsUnsubmittedMessagesUnderTheNewOpening() async throws {
        let f = try SendWorkFixture(); defer { f.remove() }
        let service = V2DirectRoomOperationService(accountID: f.account, store: f.store, client: LocalDirectUnusedRemote())
        let identity = try peer()
        let old = try await service.enqueue(publicIdentity: identity)
        try await service.enqueueLocalMessage(text: "keep through retry", workID: old)
        let original = try await service.localMessages(workID: old)
        guard case .expiredUnsubmitted = try await f.store.claimOperationWork(id: old, ownerID: UUID(), action: .submit, now: Date().addingTimeInterval(86400)) else {
            Issue.record("Expected local expiry"); return
        }
        let replacement = try await service.enqueue(publicIdentity: identity)
        #expect(replacement != old)
        #expect(try await service.localMessages(workID: old).isEmpty)
        let retained = try await service.localMessages(workID: replacement)
        #expect(retained.map(\.id) == original.map(\.id))
        #expect(retained.map(\.text) == ["keep through retry"])
        try await f.store.close()
    }

    @Test func existingRoomLookupIsLocalAndRespectsRetainedDenial() async throws {
        let f = try SendWorkFixture(); defer { f.remove() }
        let service = V2DirectRoomOperationService(accountID: f.account, store: f.store, client: LocalDirectUnusedRemote())
        let identity = try peer()
        try await f.store.cacheDirectRoomIdentity(roomID: f.room, publicIdentity: identity, roomCreatedAt: Date())
        #expect(try await service.existingLocalRoom(with: identity.userID) == f.room)
        try await f.store.markRoomEventUnauthorized(roomID: f.room)
        #expect(try await service.existingLocalRoom(with: identity.userID) == nil)
        try await f.store.close()
    }

    @Test func waitingForRoomDoesNotConsumeTheMessageSubmissionWindow() async throws {
        let f = try SendWorkFixture(); defer { f.remove() }
        let service = V2DirectRoomOperationService(accountID: f.account, store: f.store, client: LocalDirectUnusedRemote())
        let workID = try await service.enqueue(publicIdentity: peer())
        let originalDate = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 2 * 86400)
        try await f.store.saveLocalDirectMessage(workID: workID, accountID: f.account, text: "waited offline", now: originalDate)
        let message = try #require(try await service.localMessages(workID: workID).first)
        try await complete(workID, room: f.room, store: f.store)
        try await service.prepareLocalMessages()
        let frozenDate = try await f.store.databasePool.read { db in
            try Double.fetchOne(db, sql: "SELECT created_at FROM v2_send_intents WHERE intent_id=?", arguments: [message.id.uuidString])
        }
        #expect(frozenDate == originalDate.timeIntervalSince1970)
        try await f.store.handOffSendIntent(message.id)
        let send = try await f.head()
        guard case .claimed = try await f.store.claimOperationWork(id: send.id, ownerID: UUID(), action: .submit, now: Date()) else {
            Issue.record("Waiting for a room must not expire an unsubmitted local message"); return
        }
        try await f.store.close()
    }

    private func peer() throws -> V2PublicIdentity {
        try .init(userID: .init(uuid: UUID()), handle: .init("local_peer"), displayName: "Local peer", accountKind: .regular)
    }
    private func complete(_ workID: UUID, room: RoomID, store: GRDBV2LocalSyncStore) async throws {
        guard case .claimed = try await store.claimOperationWork(id: workID, ownerID: UUID(), action: .submit, now: Date()) else {
            throw V2OperationWorkError.invalidTransition
        }
        let command = try await store.directRoomCommand(workID: workID)
        try await store.completeDirectRoom(.init(identity: command.identity, fingerprint: command.fingerprint,
            outcome: .opened(roomID: room, createdAtMilliseconds: 1_750_000_000_000), resolvedAtMilliseconds: 1_750_000_000_001), workID: workID)
    }
}

private struct LocalDirectUnusedRemote: V2DirectRoomOperationClient {
    func submit(_ command: V2DirectRoomOperationCommand) async throws -> V2DirectRoomOperationResult {
        Issue.record("Local enqueue must not call the network")
        throw CancellationError()
    }
    func recover(_ command: V2DirectRoomOperationCommand, action: V2OperationRecoveryRequest.Action) async throws -> V2DirectRoomOperationResult {
        Issue.record("Local enqueue must not call the network")
        throw CancellationError()
    }
}

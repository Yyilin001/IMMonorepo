import Foundation
import Testing
import IMV2Core
@testable import IMV2ClientRuntime
@testable import IMV2SharedRuntime

@Suite(.timeLimit(.minutes(1))) struct MessageFacadeTests {
    @Test func sendsAndRepliesFreezeBeforeDeliveryAndSurviveFacadeClose() async throws {
        let f = try Fixture(); try await f.seed()
        let id = try await f.service.send(in: f.room, text: "offline reply", replyTo: .init(messageID: f.message))
        let before = try await f.store.pendingResourceSendSnapshot(in: f.room, page: 0)
        #expect(before.submitted.contains { $0.id == id })
        await f.service.close()
        await #expect(throws: V2MessageServiceError.self) { try await f.service.send(in: f.room, text: "late") }
        let after = try await f.store.pendingResourceSendSnapshot(in: f.room, page: 0)
        #expect(after.submitted.map(\.id) == before.submitted.map(\.id))
        try await f.close()
    }
    @Test func mutationAdmissionPreservesIdentityAndRejectsStaleOrForeignReferences() async throws {
        let f = try Fixture(); try await f.seed()
        let first = try await f.service.edit(in: f.room, messageID: f.message, expectedRevision: 1, text: "edited")
        let second = try await f.service.edit(in: f.room, messageID: f.message, expectedRevision: 1, text: "edited")
        #expect(first == second)
        await #expect(throws: V2MessageServiceError.self) { try await f.service.withdraw(in: f.room, messageID: f.message, expectedRevision: 2) }
        await #expect(throws: V2MessageServiceError.self) { try await f.service.edit(in: RoomID(uuid: UUID()), messageID: f.message, expectedRevision: 1, text: "wrong room") }
        var updates = await f.service.mutationUpdates(in: f.room).makeAsyncIterator()
        #expect(try await updates.next()?.map(\.work.id) == [first])
        try await f.close()
    }
    @Test func forwardAndReactionsUseDurablePlansAndIndependentObservers() async throws {
        let f = try Fixture(); try await f.seed()
        var first = await f.service.reactionUpdates(in: f.room).makeAsyncIterator()
        var second = await f.service.reactionUpdates(in: f.room).makeAsyncIterator()
        _ = try await first.next(); _ = try await second.next()
        let reaction = try await f.service.react(in: f.room, messageID: f.message, reaction: "👍", targetState: .present)
        #expect(try await first.next()?.first?.intent.id == reaction)
        #expect(try await second.next()?.first?.intent.id == reaction)
        let plan = try await f.service.forward(sources: [.init(roomID: f.room, messageID: f.message, revision: .init(1))], to: [f.room])
        #expect(try await f.store.forwardPlanSnapshot(workID: plan).command.actorUserID == f.user)
        try await f.service.cancelForward(plan)
        #expect(try await f.store.forwardPlanSnapshot(workID: plan).cancellationRequested)
        try await f.close()
    }
    @Test func closingDrainsPreparationAndDoesNotDeleteDurableReaction() async throws {
        let f = try Fixture(); try await f.seed()
        await f.remote.block()
        let id = try await f.service.react(in: f.room, messageID: f.message, reaction: "👍", targetState: .present)
        let preparation = Task { try await f.service.runReactionPreparation() }
        try await f.remote.waitUntilEntered()
        let closing = Task { await f.service.close(); #expect(await f.remote.released) }
        while true {
            do { _ = try await f.service.message(in: f.room, id: f.message); await Task.yield() }
            catch V2MessageServiceError.closed { break }
            catch is CancellationError { break }
        }
        await f.remote.release()
        await closing.value; _ = await preparation.result
        var persisted = f.store.reactionPendingUpdates(roomID: f.room).makeAsyncIterator()
        #expect(try await persisted.next()?.contains { $0.intent.id == id } == true)
        try await f.close()
    }
}

private struct Fixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("message-facade-" + UUID().uuidString)
    let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID())
    let store: GRDBV2LocalSyncStore
    let service: V2MessageService
    let remote = OfflineRemote()
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try GRDBV2LocalSyncStore(databaseURL: root.appendingPathComponent("local.sqlite"), installationBinding: .init(value: UUID()), userID: user)
        service = .init(accountID: user, store: store,
            sends: .init(accountID: user, store: store, client: remote), mutations: .init(accountID: user, store: store, client: remote),
            reactions: .init(accountID: user, store: store, client: remote), forwards: .init(accountID: user, store: store, client: remote))
    }
    func seed() async throws {
        try await store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_room_profile_projections(room_id,source_event_id,title,owner_user_id,capacity_class,created_at) VALUES (?, ?, 'Group', ?, 'standard', 1)", arguments: [room.rawValue, UUID().uuidString, user.rawValue])
            try db.execute(sql: "INSERT INTO v2_room_event_authorizations VALUES (?, 1)", arguments: [room.rawValue])
            try db.execute(sql: "INSERT INTO v2_message_projections(message_id,source_event_id,room_id,room_sequence,timeline_sequence,message_revision,sender_user_id,text_body,server_created_at) VALUES (?, ?, ?, 1, 1, 1, ?, 'source', 1)", arguments: [message.rawValue, UUID().uuidString, room.rawValue, user.rawValue])
        }
    }
    func close() async throws { await service.close(); try await store.close(); try FileManager.default.removeItem(at: root) }
}
private actor OfflineRemote: V2MessageSendOperationClient, V2MessageMutationOperationClient, V2MessageReactionOperationClient, V2ForwardPlanOperationClient {
    private var shouldBlock = false, entered = false
    private(set) var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func block() { shouldBlock = true }
    func waitUntilEntered() async throws { while !entered { try Task.checkCancellation(); await Task.yield() } }
    func release() { released = true; continuation?.resume(); continuation = nil }
    func snapshot(roomID: RoomID, messageID: MessageID, reaction: String) async throws -> V2MessageReactionSnapshot {
        if shouldBlock { entered = true; await withCheckedContinuation { continuation = $0 } }
        throw URLError(.notConnectedToInternet)
    }
    func submit(_ command: V2MessageSendOperationCommand) throws -> V2MessageSendOperationRecoveryResult { throw URLError(.notConnectedToInternet) }
    func recover(_ request: V2MessageSendOperationRecoveryRequest) throws -> V2MessageSendOperationRecoveryResult { throw URLError(.notConnectedToInternet) }
    func submit(_ payload: V2MessageMutationPayload) throws -> V2MessageMutationRecoveryResult { throw URLError(.notConnectedToInternet) }
    func recover(_ request: V2MessageMutationRecoveryRequest) throws -> V2MessageMutationRecoveryResult { throw URLError(.notConnectedToInternet) }
    func submit(_ command: V2MessageReactionOperationCommand) throws -> V2MessageReactionRecoveryResult { throw URLError(.notConnectedToInternet) }
    func recover(_ request: V2MessageReactionRecoveryRequest) throws -> V2MessageReactionRecoveryResult { throw URLError(.notConnectedToInternet) }
    func submit(_ command: V2ForwardPlanOperationCommand) throws -> V2ForwardPlanRecoveryResult { throw URLError(.notConnectedToInternet) }
    func recover(_ command: V2ForwardPlanOperationCommand, action: V2ForwardPlanRecoveryAction) throws -> V2ForwardPlanRecoveryResult { throw URLError(.notConnectedToInternet) }
}

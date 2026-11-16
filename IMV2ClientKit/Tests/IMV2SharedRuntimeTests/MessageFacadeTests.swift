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
    @Test func forwardUsesDurablePlan() async throws {
        let f = try Fixture(); try await f.seed()
        let plan = try await f.service.forward(sources: [.init(roomID: f.room, messageID: f.message, revision: .init(1))], to: [f.room])
        #expect(try await f.store.forwardPlanSnapshot(workID: plan).command.actorUserID == f.user)
        try await f.service.cancelForward(plan)
        #expect(try await f.store.forwardPlanSnapshot(workID: plan).cancellationRequested)
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
            forwards: .init(accountID: user, store: store, client: remote))
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
private actor OfflineRemote: V2MessageSendOperationClient, V2MessageMutationOperationClient, V2ForwardPlanOperationClient {
    func submit(_ command: V2MessageSendOperationCommand) throws -> V2MessageSendOperationRecoveryResult { throw URLError(.notConnectedToInternet) }
    func recover(_ request: V2MessageSendOperationRecoveryRequest) throws -> V2MessageSendOperationRecoveryResult { throw URLError(.notConnectedToInternet) }
    func submit(_ payload: V2MessageMutationPayload) throws -> V2MessageMutationRecoveryResult { throw URLError(.notConnectedToInternet) }
    func recover(_ request: V2MessageMutationRecoveryRequest) throws -> V2MessageMutationRecoveryResult { throw URLError(.notConnectedToInternet) }
    func submit(_ command: V2ForwardPlanOperationCommand) throws -> V2ForwardPlanRecoveryResult { throw URLError(.notConnectedToInternet) }
    func recover(_ command: V2ForwardPlanOperationCommand, action: V2ForwardPlanRecoveryAction) throws -> V2ForwardPlanRecoveryResult { throw URLError(.notConnectedToInternet) }
}

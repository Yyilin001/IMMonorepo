import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2OutboxMutationCorrelationTests {
    @Test("withdrawal and reaction feedback belongs to the current operation", arguments: ["withdrawal", "reaction"], [false, true])
    func mutationCorrelation(kind: String, rejectOld: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-app-mutation-correlation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        do {
            let room = RoomID(uuid: UUID())
            let oldMessage = MessageID(uuid: UUID())
            let newMessage = MessageID(uuid: UUID())
            let transport = MutationTransport(rejectedMessage: rejectOld ? oldMessage : nil)
            if kind == "withdrawal" {
                let olderOutbox = V2MessageWithdrawalOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 999) })
                let older = try await olderOutbox.enqueueWithdrawal(roomID: room, messageID: oldMessage, expectedMessageRevision: 1)
                let outbox = V2MessageWithdrawalOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_000) })
                let adapter = V2OutboxMessageWithdrawer(outbox: outbox)
                #expect(try await adapter.withdraw(messageID: newMessage.rawValue, in: room.rawValue, expectedMessageRevision: 1) == .queuedForRetry)
                let commands = try await store.pendingMessageWithdrawals()
                let current = try #require(commands.first { $0.messageID == newMessage })
                #expect(current.state == .pending)
                #expect(commands.first { $0.operationID == older.operationID }?.state == (rejectOld ? .rejected : .acknowledged))
                #expect(try await outbox.flushOnce() == .acknowledged(current.operationID))
                #expect(try await store.pendingMessageWithdrawals().first { $0.operationID == current.operationID }?.state == .acknowledged)
            } else {
                let olderOutbox = V2MessageReactionOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 999) })
                let older = try await olderOutbox.enqueueReaction(roomID: room, messageID: oldMessage, reaction: "👍", action: .add)
                let outbox = V2MessageReactionOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_000) })
                let adapter = V2OutboxMessageReactionChanger(outbox: outbox)
                #expect(try await adapter.changeReaction(messageID: newMessage.rawValue, in: room.rawValue, reaction: "👍", action: .add) == .queuedForRetry)
                let commands = try await store.pendingMessageReactions()
                let current = try #require(commands.first { $0.messageID == newMessage })
                #expect(current.state == .pending)
                #expect(commands.first { $0.operationID == older.operationID }?.state == (rejectOld ? .rejected : .acknowledged))
                #expect(try await outbox.flushOnce() == .acknowledged(current.operationID))
                #expect(try await store.pendingMessageReactions().first { $0.operationID == current.operationID }?.state == .acknowledged)
            }
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }
}

private struct MutationTransport: V2ClientMessageWithdrawalTransport, V2ClientMessageReactionTransport {
    let rejectedMessage: MessageID?
    private func check(_ message: MessageID) throws {
        if message == rejectedMessage {
            throw V2RealtimeTransportError.server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: 0, currentRevision: nil)
        }
    }
    func withdrawMessage(roomID: RoomID, operationID: MessageWithdrawalOperationID, messageID: MessageID, expectedMessageRevision: UInt64) async throws -> V2ClientMessageWithdrawal {
        try check(messageID)
        return try .init(roomID: roomID, messageID: messageID, messageRevision: 2, roomSequence: 1, createdAt: Date(timeIntervalSince1970: 1_000))
    }
    func changeMessageReaction(roomID: RoomID, operationID: MessageReactionOperationID, messageID: MessageID, reaction: String, action: V2MessageReactionAction) async throws -> V2ClientMessageReactionChange {
        try check(messageID)
        return try .init(roomID: roomID, messageID: messageID, actorUserID: .init(uuid: UUID()), reaction: reaction, action: action, roomSequence: 1, createdAt: Date(timeIntervalSince1970: 1_000))
    }
}

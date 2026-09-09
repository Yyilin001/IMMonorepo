import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2OutboxCancelledMutationTests {
    @Test("already cancelled message mutations neither enqueue nor send", arguments: ["edit", "withdrawal", "reaction"])
    func cancelledMutation(kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-app-cancelled-mutation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        do {
            let room = RoomID(uuid: UUID())
            let message = MessageID(uuid: UUID())
            let transport = UnexpectedMutationTransport()
            let editor = V2OutboxMessageEditor(outbox: .init(store: store, transport: transport))
            let withdrawer = V2OutboxMessageWithdrawer(outbox: .init(store: store, transport: transport))
            let reactor = V2OutboxMessageReactionChanger(outbox: .init(store: store, transport: transport))
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                switch kind {
                case "edit": _ = try await editor.edit(messageID: message.rawValue, in: room.rawValue, expectedMessageRevision: 1, text: "edited")
                case "withdrawal": _ = try await withdrawer.withdraw(messageID: message.rawValue, in: room.rawValue, expectedMessageRevision: 1)
                default: _ = try await reactor.changeReaction(messageID: message.rawValue, in: room.rawValue, reaction: "👍", action: .add)
                }
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.pendingMessageEdits().isEmpty)
            #expect(try await store.pendingMessageWithdrawals().isEmpty)
            #expect(try await store.pendingMessageReactions().isEmpty)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }
}

private struct UnexpectedMutationTransport: V2ClientMessageEditTransport, V2ClientMessageWithdrawalTransport, V2ClientMessageReactionTransport {
    func editMessage(roomID: RoomID, operationID: MessageEditOperationID, messageID: MessageID, expectedMessageRevision: UInt64, text: String) async throws -> V2ClientMessageEdit {
        Issue.record("cancelled edit must not reach transport")
        throw CancellationError()
    }
    func withdrawMessage(roomID: RoomID, operationID: MessageWithdrawalOperationID, messageID: MessageID, expectedMessageRevision: UInt64) async throws -> V2ClientMessageWithdrawal {
        Issue.record("cancelled withdrawal must not reach transport")
        throw CancellationError()
    }
    func changeMessageReaction(roomID: RoomID, operationID: MessageReactionOperationID, messageID: MessageID, reaction: String, action: V2MessageReactionAction) async throws -> V2ClientMessageReactionChange {
        Issue.record("cancelled reaction must not reach transport")
        throw CancellationError()
    }
}

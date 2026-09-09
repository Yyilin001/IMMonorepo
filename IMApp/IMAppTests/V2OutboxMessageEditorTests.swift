import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2OutboxMessageEditorTests {
    @Test("older edit completion does not determine the current edit outcome", arguments: [false, true])
    func editOutcomeCorrelation(rejectOld: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-app-edit-correlation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        do {
            let transport = EditTransport(rejectOld: rejectOld)
            let olderOutbox = V2MessageEditOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 999) })
            let room = RoomID(uuid: UUID())
            let older = try await olderOutbox.enqueueEdit(roomID: room, messageID: .init(uuid: UUID()), expectedMessageRevision: 1, text: "old")
            let outbox = V2MessageEditOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_000) })
            let editor = V2OutboxMessageEditor(outbox: outbox)
            #expect(try await editor.edit(messageID: MessageID(uuid: UUID()).rawValue, in: room.rawValue, expectedMessageRevision: 1, text: "new") == .queuedForRetry)
            let commands = try await store.pendingMessageEdits()
            let current = try #require(commands.first { $0.text == "new" })
            #expect(current.state == .pending)
            #expect(commands.first { $0.operationID == older.operationID }?.state == (rejectOld ? .rejected : .acknowledged))
            #expect(try await outbox.flushOnce() == .acknowledged(current.operationID))
            #expect(try await store.pendingMessageEdits().first { $0.operationID == current.operationID }?.state == .acknowledged)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }
}

private struct EditTransport: V2ClientMessageEditTransport {
    let rejectOld: Bool
    func editMessage(roomID: RoomID, operationID: MessageEditOperationID, messageID: MessageID, expectedMessageRevision: UInt64, text: String) async throws -> V2ClientMessageEdit {
        if rejectOld && text == "old" {
            throw V2RealtimeTransportError.server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: 0, currentRevision: nil)
        }
        return try .init(roomID: roomID, messageID: messageID, text: text, messageRevision: 2, roomSequence: 1, createdAt: Date(timeIntervalSince1970: 1_000))
    }
}

import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2OutboxMessageSenderTests {
    @Test("sending behind older work reports the new command as queued", arguments: [false, true])
    func olderCommandDoesNotDetermineSendOutcome(rejectOld: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-app-send-correlation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        do {
            let transport = SuspendedSendTransport(rejectOld: rejectOld)
            let olderOutbox = V2CommandOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 999) })
            let room = RoomID(uuid: UUID())
            let older = try await olderOutbox.enqueueMessage(roomID: room, text: "old")
            let outbox = V2CommandOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_000) })
            let sender = V2OutboxConversationSender(outbox: outbox)
            #expect(try await sender.send(text: "new", media: [], mentions: [], in: room.rawValue) == .queuedForRetry)
            let commands = try await store.pendingMessageCommands()
            let current = try #require(commands.first { $0.text == "new" })
            #expect(current.state == .pending)
            #expect(commands.first { $0.clientMessageID == older.clientMessageID }?.state == (rejectOld ? .rejected : .accepted))
            #expect(await transport.calls == 1)
            #expect(try await outbox.flushOnce() == .accepted(current.clientMessageID))
            #expect(await transport.calls == 2)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("a cancelled sender does not enqueue a new message")
    func cancelledSendDoesNotEnqueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-app-cancelled-send-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        do {
            let transport = SuspendedSendTransport()
            let outbox = V2CommandOutboxEngine(store: store, transport: transport)
            let sender = V2OutboxConversationSender(outbox: outbox)
            let room = RoomID(uuid: UUID())
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await sender.send(text: "cancelled", media: [], mentions: [], in: room.rawValue)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.pendingMessageCommands().isEmpty)
            #expect(await transport.calls == 0)
            #expect(try await sender.send(text: "new send", media: [], mentions: [], in: room.rawValue) == .accepted)
            #expect(await transport.calls == 1)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("a suspended runtime still reports a durably queued message and resumes its original command")
    func suspendedSendReportsQueued() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-app-suspended-send-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        do {
            let transport = SuspendedSendTransport()
            let outbox = V2CommandOutboxEngine(store: store, transport: transport)
            let sender = V2OutboxConversationSender(outbox: outbox)
            await outbox.suspendCommandFlushing()
            let room = RoomID(uuid: UUID())
            #expect(try await sender.send(text: "queued", media: [], mentions: [], in: room.rawValue) == .queuedForRetry)
            let pending = try #require(try await store.pendingMessageCommands().first)
            #expect(pending.state == .pending && pending.text == "queued")
            #expect(await transport.calls == 0)
            await outbox.resumeCommandFlushing()
            #expect(try await outbox.flushOnce() == .accepted(pending.clientMessageID))
            #expect(try await store.pendingMessageCommands().first?.state == .accepted)
            #expect(await transport.calls == 1)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }
}

private actor SuspendedSendTransport: V2ClientMessageTransport {
    var calls = 0
    let rejectOld: Bool
    init(rejectOld: Bool = false) { self.rejectOld = rejectOld }
    func sendMessage(roomID: RoomID, clientMessageID: ClientMessageID, text: String, media: [V2MediaReference], mentions: [V2MentionTarget], entities: [V2MessageEntity], replyTo: V2MessageReplyReference?) throws -> V2ClientMessageAcceptance {
        calls += 1
        if rejectOld && text == "old" {
            throw V2RealtimeTransportError.server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: 0, currentRevision: 0)
        }
        return try .init(messageID: .init(uuid: UUID()), roomID: roomID, roomSequence: 1, createdAt: Date())
    }
}

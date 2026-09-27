import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Message outcome recovery without replacing the original intent")
struct V2MessageOperationRecoveryTests {
    @Test("expired sends survive terminal pruning and recover accepted with the original fingerprint")
    func expiredAcceptance() async throws {
        let store = try makeStore(), actor = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let transport = RecoveryOnlyMessageTransport()
        let started = Date(timeIntervalSince1970: 1_000), now = started.addingTimeInterval(V2IdempotencyPolicy.maximumClientRetryAge + 1)
        let initial = V2CommandOutboxEngine(store: store, transport: transport, now: { started })
        let command = try await initial.enqueueMessage(roomID: room, text: "An immutable send", media: [.init(mediaID: .init(uuid: UUID()))])
        let accepted = try V2MessageOperationAcceptance(messageID: .init(uuid: UUID()), roomSequence: 6)
        let remote = ScriptedRecoveryClient([.accepted(accepted)])
        try await store.expireStalePendingCommands(now: now)
        try await store.pruneTerminalCommands(olderThan: now.addingTimeInterval(86_400))
        let recovery = V2MessageOperationRecoveryController(store: store, remote: remote, actorUserID: { actor })
        let engine = V2CommandOutboxEngine(store: store, transport: transport, now: { now }, recovery: recovery)
        #expect(try await engine.flushOnce() == .accepted(command.clientMessageID))
        let requests = await remote.requests
        #expect(requests.count == 1)
        let expected = try V2SendMessageCommand(roomID: room, senderUserID: actor, clientMessageID: command.clientMessageID,
            text: command.text, media: command.media, limits: .init(maxUTF8Bytes: 1_024))
        #expect(requests.first?.fingerprint == expected.fingerprint)
        #expect(requests.first?.clientMessageID == command.clientMessageID)
        #expect(requests.first?.action == .closeIfAbsent)
        #expect(try await store.pendingMessageCommands().first?.acceptedMessageID == accepted.messageID)
        #expect(await transport.calls == 0)
        try await store.close()
    }

    @Test("unresolved recovery keeps the original operation, then records a permanent closure")
    func unresolvedThenClosed() async throws {
        let store = try makeStore(), actor = UserID(uuid: UUID()), transport = RecoveryOnlyMessageTransport()
        let now = Date(timeIntervalSince1970: 1_000)
        let enqueue = V2CommandOutboxEngine(store: store, transport: transport, now: { now })
        let command = try await enqueue.enqueueMessage(roomID: .init(uuid: UUID()), text: "Never duplicate")
        try await store.requireMessageOperationRecovery(command.clientMessageID, now: now)
        let remote = ScriptedRecoveryClient([.unresolved, .closed])
        let controller = V2MessageOperationRecoveryController(store: store, remote: remote, actorUserID: { actor })
        #expect(try await controller.flushOnce(now: now) == .retryScheduled(command.clientMessageID))
        #expect(try await store.nextReadyMessage(now: now.addingTimeInterval(1_000)) == nil)
        #expect(try await controller.flushOnce(now: now.addingTimeInterval(301)) == .rejected(command.clientMessageID, code: "MESSAGE_OPERATION_CLOSED"))
        let requests = await remote.requests
        #expect(requests.count == 2 && requests[0] == requests[1])
        #expect(try await store.pendingMessageCommands().count == 1)
        #expect(try await store.pendingMessageCommands().first?.terminalCode == "MESSAGE_OPERATION_CLOSED")
        try await store.close()
    }

    @Test("MEDIA_UNAVAILABLE enters durable recovery before any replacement can be sent")
    func unavailableMediaUsesRecoveryLane() async throws {
        let store = try makeStore(), actor = UserID(uuid: UUID()), transport = RecoveryOnlyMessageTransport()
        let now = Date(timeIntervalSince1970: 2_000)
        let remote = ScriptedRecoveryClient([.closed])
        let engine = V2CommandOutboxEngine(store: store, transport: transport, now: { now },
            recovery: .init(store: store, remote: remote, actorUserID: { actor }))
        let command = try await engine.enqueueMessage(roomID: .init(uuid: UUID()), text: "Attachment",
            media: [.init(mediaID: .init(uuid: UUID()))])
        #expect(try await engine.flushOnce() == .retryScheduled(command.clientMessageID))
        #expect(try await engine.flushOnce() == .rejected(command.clientMessageID, code: "MESSAGE_OPERATION_CLOSED"))
        #expect(await transport.calls == 1)
        #expect(try await engine.flushOnce() == .idle)
        try await store.close()
    }

    private func makeStore() throws -> GRDBV2LocalSyncStore {
        try .init(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("message-operation-recovery-\(UUID()).sqlite"),
                  installationBinding: .init(value: UUID()))
    }
}

private actor ScriptedRecoveryClient: V2MessageOperationRecovering {
    private var results: [V2MessageOperationRecoveryResult]
    private(set) var requests: [V2MessageOperationRecoveryRequest] = []
    init(_ results: [V2MessageOperationRecoveryResult]) { self.results = results }
    func recover(_ request: V2MessageOperationRecoveryRequest) async throws -> V2MessageOperationRecoveryResult {
        requests.append(request)
        return results.isEmpty ? .unresolved : results.removeFirst()
    }
}
private actor RecoveryOnlyMessageTransport: V2ClientMessageTransport {
    private(set) var calls = 0
    func sendMessage(roomID: RoomID, clientMessageID: ClientMessageID, text: String, media: [V2MediaReference],
                     mentions: [V2MentionTarget], entities: [V2MessageEntity], replyTo: V2MessageReplyReference?) async throws -> V2ClientMessageAcceptance {
        calls += 1
        throw V2RealtimeTransportError.server(code: "MEDIA_UNAVAILABLE", retryable: false, retryAfterSeconds: 0, currentRevision: nil)
    }
}

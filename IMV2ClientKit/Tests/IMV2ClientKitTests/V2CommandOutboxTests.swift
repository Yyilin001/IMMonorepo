import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 local command outbox")
struct V2CommandOutboxTests {
    @Test("network retry survives store restart and preserves the original client message ID")
    func retrySurvivesRestart() async throws {
        let url = temporaryOutboxDatabaseURL()
        let started = Date(timeIntervalSince1970: 1_750_000_000)
        let roomID = try RoomID("00000000-0000-0000-0000-000000000501")
        let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000502")!
        let transport = ScriptedMessageTransport(results: [.retryableFailure, .accepted])
        let firstStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let firstEngine = V2CommandOutboxEngine(store: firstStore, transport: transport, makeUUID: { clientID }, now: { started })

        let command = try await firstEngine.enqueueMessage(roomID: roomID, text: "offline message")
        #expect(command.clientMessageID.rawValue == clientID.uuidString)
        #expect(try await firstEngine.flushOnce() == .retryScheduled(command.clientMessageID))
        let retry = try #require(await firstStore.pendingMessageCommands().first)
        #expect(retry.state == .pending)
        #expect(retry.attemptCount == 1)

        let restartedStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let restartedEngine = V2CommandOutboxEngine(store: restartedStore, transport: transport, now: { started.addingTimeInterval(1) })
        #expect(try await restartedEngine.flushOnce() == .accepted(command.clientMessageID))
        let completed = try #require(await restartedStore.pendingMessageCommands().first)
        #expect(completed.clientMessageID == command.clientMessageID)
        #expect(completed.state == .accepted)
        #expect(completed.acceptedMessageID?.rawValue == "00000000-0000-0000-0000-000000000503")
        #expect(completed.acceptedRoomSequence == 1)
        #expect(await transport.clientMessageIDs() == [command.clientMessageID, command.clientMessageID])
    }

    @Test("response loss after remote acceptance retries the original durable idempotency key")
    func responseLossAfterAcceptanceSurvivesRestart() async throws {
        let url = temporaryOutboxDatabaseURL()
        let started = Date(timeIntervalSince1970: 1_750_000_000)
        let transport = ScriptedMessageTransport(results: [.acceptedThenResponseLost, .accepted])
        let firstStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let firstEngine = V2CommandOutboxEngine(
            store: firstStore,
            transport: transport,
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000508")! },
            now: { started }
        )
        let command = try await firstEngine.enqueueMessage(roomID: .init("00000000-0000-0000-0000-000000000509"), text: "accepted before response loss")

        #expect(try await firstEngine.flushOnce() == .retryScheduled(command.clientMessageID))
        #expect(await transport.remotelyAcceptedIDs() == [command.clientMessageID])
        let retrying = try #require(await firstStore.pendingMessageCommands().first)
        #expect(retrying.state == .pending)
        #expect(retrying.acceptedMessageID == nil)

        let restartedStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let restartedEngine = V2CommandOutboxEngine(store: restartedStore, transport: transport, now: { started.addingTimeInterval(1) })
        #expect(try await restartedEngine.flushOnce() == .accepted(command.clientMessageID))
        let completed = try #require(await restartedStore.pendingMessageCommands().first)
        #expect(completed.clientMessageID == command.clientMessageID)
        #expect(completed.state == .accepted)
        #expect(completed.acceptedMessageID?.rawValue == "00000000-0000-0000-0000-000000000503")
        #expect(await transport.clientMessageIDs() == [command.clientMessageID, command.clientMessageID])
        #expect(await transport.remotelyAcceptedIDs() == [command.clientMessageID])
    }

    @Test("terminal server conflict is recorded and never rescheduled")
    func terminalConflictIsNotRetried() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryOutboxDatabaseURL(), installationBinding: testInstallationBinding)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let engine = V2CommandOutboxEngine(store: store, transport: ScriptedMessageTransport(results: [.terminalConflict]), makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000504")! }, now: { now })
        let command = try await engine.enqueueMessage(roomID: .init("00000000-0000-0000-0000-000000000505"), text: "conflict")

        #expect(try await engine.flushOnce() == .rejected(command.clientMessageID, code: "IDEMPOTENCY_CONFLICT"))
        let rejected = try #require(await store.pendingMessageCommands().first)
        #expect(rejected.state == .rejected)
        #expect(rejected.terminalCode == "IDEMPOTENCY_CONFLICT")
        #expect(try await engine.flushOnce() == .idle)
    }

    @Test("an out-of-range accepted sequence leaves the durable command pending")
    func rejectsUnpersistableAcceptanceSequence() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryOutboxDatabaseURL(), installationBinding: testInstallationBinding)
        let engine = V2CommandOutboxEngine(store: store, transport: ScriptedMessageTransport(results: [.accepted]))
        let command = try await engine.enqueueMessage(roomID: .init("00000000-0000-0000-0000-000000000506"), text: "range")

        await #expect(throws: V2ClientCommandError.commandConflict) {
            try await store.markMessageAccepted(
                clientMessageID: command.clientMessageID,
                messageID: .init("00000000-0000-0000-0000-000000000507"),
                roomSequence: UInt64(Int64.max) + 1
            )
        }
        let pending = try #require(await store.pendingMessageCommands().first)
        #expect(pending.state == .pending)
        #expect(pending.acceptedRoomSequence == nil)
    }

    @Test("attachments and mentions survive durable retry and reach the transport unchanged")
    func attachmentsAndMentionsSurviveRetry() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let media = V2MediaReference(mediaID: try .init("00000000-0000-0000-0000-000000000510"))
        let mention: V2MentionTarget = .user(try .init("00000000-0000-0000-0000-000000000512"))
        let transport = ScriptedMessageTransport(results: [.retryableFailure, .accepted])
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryOutboxDatabaseURL(), installationBinding: testInstallationBinding)
        let engine = V2CommandOutboxEngine(store: store, transport: transport, now: { now })
        let command = try await engine.enqueueMessage(roomID: .init("00000000-0000-0000-0000-000000000511"), text: "", media: [media], mentions: [mention])

        #expect(command.media == [media])
        #expect(command.mentions == [mention])
        #expect(try await engine.flushOnce() == .retryScheduled(command.clientMessageID))
        #expect(try #require(await store.pendingMessageCommands().first).media == [media])
        #expect(try #require(await store.pendingMessageCommands().first).mentions == [mention])
        let retrying = V2CommandOutboxEngine(store: store, transport: transport, now: { now.addingTimeInterval(1) })
        #expect(try await retrying.flushOnce() == .accepted(command.clientMessageID))
        #expect(await transport.receivedMedia() == [[media], [media]])
        #expect(await transport.receivedMentions() == [[mention], [mention]])
    }

    @Test("取消后忽略非协作传输的迟到成功，保留同一 durable 命令")
    func cancellationAfterLateTransportSuccessDoesNotPersistAcceptance() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryOutboxDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        let transport = LateSuccessMessageTransport()
        let engine = V2CommandOutboxEngine(store: store, transport: transport)
        let command = try await engine.enqueueMessage(
            roomID: .init("00000000-0000-0000-0000-000000000513"),
            text: "cancel after remote success"
        )

        let flush = Task { try await engine.flushOnce() }
        await transport.waitUntilResponseIsPending()
        flush.cancel()
        await transport.resumeAccepted()

        await #expect(throws: CancellationError.self) {
            _ = try await flush.value
        }
        let pending = try #require(await store.pendingMessageCommands().first)
        #expect(pending.clientMessageID == command.clientMessageID)
        #expect(pending.state == .pending)
        #expect(pending.attemptCount == 0)
        #expect(pending.acceptedMessageID == nil)
    }
}

private actor ScriptedMessageTransport: V2ClientMessageTransport {
    enum Result: Sendable { case retryableFailure, terminalConflict, acceptedThenResponseLost, accepted }
    private var results: [Result]
    private var receivedIDs: [ClientMessageID] = []
    private var remoteAcceptedIDs: [ClientMessageID] = []
    private var receivedAttachments: [[V2MediaReference]] = []
    private var receivedMentionTargets: [[V2MentionTarget]] = []

    init(results: [Result]) { self.results = results }

    func sendMessage(roomID: RoomID, clientMessageID: ClientMessageID, text _: String, media: [V2MediaReference], mentions: [V2MentionTarget]) throws -> V2ClientMessageAcceptance {
        receivedIDs.append(clientMessageID)
        receivedAttachments.append(media)
        receivedMentionTargets.append(mentions)
        switch results.removeFirst() {
        case .retryableFailure: throw V2RealtimeTransportError.unexpectedResponse
        case .terminalConflict: throw V2RealtimeTransportError.server(code: "IDEMPOTENCY_CONFLICT", retryable: false, retryAfterSeconds: 0, currentRevision: nil)
        case .acceptedThenResponseLost:
            remoteAcceptedIDs.append(clientMessageID)
            throw V2RealtimeTransportError.unexpectedResponse
        case .accepted:
            if !remoteAcceptedIDs.contains(clientMessageID) {
                remoteAcceptedIDs.append(clientMessageID)
            }
            return try .init(messageID: .init("00000000-0000-0000-0000-000000000503"), roomID: roomID, roomSequence: 1, createdAt: .distantPast)
        }
    }

    func clientMessageIDs() -> [ClientMessageID] { receivedIDs }
    func remotelyAcceptedIDs() -> [ClientMessageID] { remoteAcceptedIDs }
    func receivedMedia() -> [[V2MediaReference]] { receivedAttachments }
    func receivedMentions() -> [[V2MentionTarget]] { receivedMentionTargets }
}

/// Models a transport that cannot observe cancellation until it has already
/// received a valid remote response. The outbox must fence its local write at
/// that boundary and preserve the original idempotency key for the next run.
private actor LateSuccessMessageTransport: V2ClientMessageTransport {
    private var responseWaiter: CheckedContinuation<V2ClientMessageAcceptance, Never>?
    private var responseReadyWaiter: CheckedContinuation<Void, Never>?
    private var pendingAcceptance: V2ClientMessageAcceptance?

    func sendMessage(
        roomID: RoomID,
        clientMessageID _: ClientMessageID,
        text _: String,
        media _: [V2MediaReference],
        mentions _: [V2MentionTarget]
    ) async throws -> V2ClientMessageAcceptance {
        let acceptance = try V2ClientMessageAcceptance(
            messageID: .init("00000000-0000-0000-0000-000000000514"),
            roomID: roomID,
            roomSequence: 1,
            createdAt: .distantPast
        )
        return await withCheckedContinuation { continuation in
            pendingAcceptance = acceptance
            responseWaiter = continuation
            responseReadyWaiter?.resume()
            responseReadyWaiter = nil
        }
    }

    func waitUntilResponseIsPending() async {
        guard responseWaiter == nil else { return }
        await withCheckedContinuation { responseReadyWaiter = $0 }
    }

    func resumeAccepted() {
        guard let acceptance = pendingAcceptance, let responseWaiter else { return }
        pendingAcceptance = nil
        self.responseWaiter = nil
        responseWaiter.resume(returning: acceptance)
    }
}

private func temporaryOutboxDatabaseURL() -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "im-v2-outbox-\(UUID().uuidString)", directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "state.sqlite")
}

private let testInstallationBinding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 message edit outbox")
struct V2MessageEditOutboxTests {
    @Test("restart retries the identical edit operation and persists its result")
    func retrySurvivesRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-edit-\(UUID().uuidString).sqlite")
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let transport = EditTransport(results: [.offline, .accepted])
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: editBinding)
        let first = V2MessageEditOutboxEngine(store: store, transport: transport, makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000961")! }, now: { now })
        let command = try await first.enqueueEdit(roomID: .init("00000000-0000-0000-0000-000000000962"), messageID: .init("00000000-0000-0000-0000-000000000963"), expectedMessageRevision: 1, text: "replacement")
        #expect(try await first.flushOnce() == .retryScheduled(command.operationID))

        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: editBinding)
        let second = V2MessageEditOutboxEngine(store: restarted, transport: transport, now: { now.addingTimeInterval(1) })
        #expect(try await second.flushOnce() == .acknowledged(command.operationID))
        let saved = try #require(await restarted.pendingMessageEdits().first)
        #expect(saved.operationID == command.operationID)
        #expect(saved.state == .acknowledged)
        #expect(saved.resultingMessageRevision == 2)
        #expect(await transport.operationIDs() == [command.operationID, command.operationID])
    }

    @Test("revision conflict is a durable terminal edit outcome")
    func revisionConflictIsTerminal() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-v2-edit-\(UUID().uuidString).sqlite"), installationBinding: editBinding)
        let engine = V2MessageEditOutboxEngine(store: store, transport: EditTransport(results: [.conflict]), makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000964")! })
        let command = try await engine.enqueueEdit(roomID: .init("00000000-0000-0000-0000-000000000965"), messageID: .init("00000000-0000-0000-0000-000000000966"), expectedMessageRevision: 1, text: "new")
        #expect(try await engine.flushOnce() == .rejected(command.operationID, code: "REVISION_CONFLICT"))
        let saved = try #require(await store.pendingMessageEdits().first)
        #expect(saved.terminalCurrentRevision == 2)
    }

    @Test("duplicate pending edit after restart reuses its original operation ID")
    func duplicatePendingEditReusesTheOriginalOperationAfterRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-edit-\(UUID().uuidString).sqlite")
        let roomID = try RoomID("00000000-0000-0000-0000-000000000968")
        let messageID = try MessageID("00000000-0000-0000-0000-000000000969")
        let originalStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: editBinding)
        let originalEngine = V2MessageEditOutboxEngine(
            store: originalStore,
            transport: EditTransport(results: []),
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000970")! }
        )
        let original = try await originalEngine.enqueueEdit(
            roomID: roomID,
            messageID: messageID,
            expectedMessageRevision: 4,
            text: "replacement"
        )

        let restartedStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: editBinding)
        let restartedEngine = V2MessageEditOutboxEngine(
            store: restartedStore,
            transport: EditTransport(results: [])
        )
        let reused = try await restartedEngine.enqueueEdit(
            roomID: roomID,
            messageID: messageID,
            expectedMessageRevision: 4,
            text: "replacement"
        )

        #expect(reused.operationID == original.operationID)
        let changedText = try await restartedEngine.enqueueEdit(
            roomID: roomID,
            messageID: messageID,
            expectedMessageRevision: 4,
            text: "a distinct replacement"
        )
        #expect(changedText.operationID != original.operationID)
        #expect(try await restartedStore.pendingMessageEdits().count == 2)
    }
}

private actor EditTransport: V2ClientMessageEditTransport {
    enum Result: Sendable { case offline, conflict, accepted }
    private var results: [Result]; private var received: [MessageEditOperationID] = []
    init(results: [Result]) { self.results = results }
    func editMessage(roomID: RoomID, operationID: MessageEditOperationID, messageID: MessageID, expectedMessageRevision _: UInt64, text: String) throws -> V2ClientMessageEdit {
        received.append(operationID)
        switch results.removeFirst() {
        case .offline: throw V2RealtimeTransportError.unexpectedResponse
        case .conflict: throw V2RealtimeTransportError.server(code: "REVISION_CONFLICT", retryable: false, retryAfterSeconds: 0, currentRevision: 2)
        case .accepted: return .init(roomID: roomID, messageID: messageID, text: text, messageRevision: 2, roomSequence: 9, createdAt: .distantPast)
        }
    }
    func operationIDs() -> [MessageEditOperationID] { received }
}

private let editBinding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000967")!)

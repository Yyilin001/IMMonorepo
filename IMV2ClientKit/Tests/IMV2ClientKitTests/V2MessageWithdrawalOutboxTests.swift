import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 message withdrawal outbox")
struct V2MessageWithdrawalOutboxTests {
    @Test("retry after restart retains one withdrawal operation ID")
    func retrySurvivesRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-withdrawal-\(UUID().uuidString).sqlite")
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let transport = ScriptedWithdrawalTransport(results: [.offline, .accepted])
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: withdrawalBinding)
        let engine = V2MessageWithdrawalOutboxEngine(store: store, transport: transport, makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000951")! }, now: { now })
        let command = try await engine.enqueueWithdrawal(roomID: .init("00000000-0000-0000-0000-000000000952"), messageID: .init("00000000-0000-0000-0000-000000000953"), expectedMessageRevision: 1)
        #expect(try await engine.flushOnce() == .retryScheduled(command.operationID))

        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: withdrawalBinding)
        let retryEngine = V2MessageWithdrawalOutboxEngine(store: restarted, transport: transport, now: { now.addingTimeInterval(1) })
        #expect(try await retryEngine.flushOnce() == .acknowledged(command.operationID))
        let saved = try #require(await restarted.pendingMessageWithdrawals().first)
        #expect(saved.operationID == command.operationID)
        #expect(saved.state == .acknowledged)
        #expect(saved.resultingMessageRevision == 2)
        #expect(await transport.operationIDs() == [command.operationID, command.operationID])
    }

    @Test("revision conflict is terminal and retains the server revision")
    func revisionConflictIsTerminal() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-v2-withdrawal-\(UUID().uuidString).sqlite"), installationBinding: withdrawalBinding)
        let engine = V2MessageWithdrawalOutboxEngine(store: store, transport: ScriptedWithdrawalTransport(results: [.conflict]), makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000954")! }, now: { Date(timeIntervalSince1970: 1_750_000_000) })
        let command = try await engine.enqueueWithdrawal(roomID: .init("00000000-0000-0000-0000-000000000955"), messageID: .init("00000000-0000-0000-0000-000000000956"), expectedMessageRevision: 1)
        #expect(try await engine.flushOnce() == .rejected(command.operationID, code: "REVISION_CONFLICT"))
        let saved = try #require(await store.pendingMessageWithdrawals().first)
        #expect(saved.state == .rejected)
        #expect(saved.terminalCurrentRevision == 2)
        #expect(try await engine.flushOnce() == .idle)
    }

    @Test("duplicate pending withdrawal after restart reuses its original operation ID")
    func duplicatePendingWithdrawalReusesTheOriginalOperationAfterRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-withdrawal-\(UUID().uuidString).sqlite")
        let roomID = try RoomID("00000000-0000-0000-0000-000000000958")
        let messageID = try MessageID("00000000-0000-0000-0000-000000000959")
        let originalStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: withdrawalBinding)
        let originalEngine = V2MessageWithdrawalOutboxEngine(
            store: originalStore,
            transport: ScriptedWithdrawalTransport(results: []),
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000960")! }
        )
        let original = try await originalEngine.enqueueWithdrawal(
            roomID: roomID,
            messageID: messageID,
            expectedMessageRevision: 3
        )

        let restartedStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: withdrawalBinding)
        let restartedEngine = V2MessageWithdrawalOutboxEngine(
            store: restartedStore,
            transport: ScriptedWithdrawalTransport(results: [])
        )
        let reused = try await restartedEngine.enqueueWithdrawal(
            roomID: roomID,
            messageID: messageID,
            expectedMessageRevision: 3
        )

        #expect(reused.operationID == original.operationID)
        #expect(try await restartedStore.pendingMessageWithdrawals().count == 1)
    }
}

private actor ScriptedWithdrawalTransport: V2ClientMessageWithdrawalTransport {
    enum Result: Sendable { case offline, conflict, accepted }
    private var results: [Result]
    private var received: [MessageWithdrawalOperationID] = []
    init(results: [Result]) { self.results = results }
    func withdrawMessage(roomID: RoomID, operationID: MessageWithdrawalOperationID, messageID: MessageID, expectedMessageRevision _: UInt64) throws -> V2ClientMessageWithdrawal {
        received.append(operationID)
        switch results.removeFirst() {
        case .offline: throw V2RealtimeTransportError.unexpectedResponse
        case .conflict: throw V2RealtimeTransportError.server(code: "REVISION_CONFLICT", retryable: false, retryAfterSeconds: 0, currentRevision: 2)
        case .accepted: return try .init(roomID: roomID, messageID: messageID, messageRevision: 2, roomSequence: 9, createdAt: .distantPast)
        }
    }
    func operationIDs() -> [MessageWithdrawalOperationID] { received }
}

private let withdrawalBinding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000957")!)

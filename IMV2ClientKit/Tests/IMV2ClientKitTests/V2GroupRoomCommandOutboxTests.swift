import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 durable group room creation outbox")
struct V2GroupRoomCommandOutboxTests {
    @Test("retry survives a local-store restart and keeps the original operation")
    func retrySurvivesRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-group-create-\(UUID().uuidString).sqlite")
        let started = Date(timeIntervalSince1970: 1_750_000_000)
        let operation = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
        let member = try UserID("00000000-0000-0000-0000-000000000702")
        let roomID = try RoomID("00000000-0000-0000-0000-000000000703")
        let transport = ScriptedGroupTransport(results: [.retryableFailure, .created(roomID)])
        let binding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000704")!)
        let first = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let firstEngine = V2GroupRoomCommandOutboxEngine(store: first, transport: transport, makeUUID: { operation }, now: { started })

        let command = try await firstEngine.enqueueCreation(title: " 项目群 ", deliveryMode: .standardFanout, initialMemberUserIDs: [member])
        #expect(command.title == "项目群")
        #expect(try await firstEngine.flushOnce() == .retryScheduled(command.operationID))
        let retried = try #require(await first.pendingGroupRoomCreations().first)
        #expect(retried.attemptCount == 1)

        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let restartedEngine = V2GroupRoomCommandOutboxEngine(store: restarted, transport: transport, now: { started.addingTimeInterval(1) })
        #expect(try await restartedEngine.flushOnce() == .acknowledged(command.operationID, roomID: roomID))
        let complete = try #require(await restarted.pendingGroupRoomCreations().first)
        #expect(complete.state == .acknowledged)
        #expect(complete.createdRoomID == roomID)
        #expect(await transport.operationIDs() == [command.operationID, command.operationID])
    }

    @Test("terminal server validation failure is not retried")
    func terminalFailureIsNotRetried() async throws {
        let binding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000705")!)
        let store = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-v2-group-rejected-\(UUID().uuidString).sqlite"), installationBinding: binding)
        let engine = V2GroupRoomCommandOutboxEngine(store: store, transport: ScriptedGroupTransport(results: [.rejected]), makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000706")! }, now: Date.init)
        let command = try await engine.enqueueCreation(title: "项目群", deliveryMode: .standardFanout, initialMemberUserIDs: [])
        #expect(try await engine.flushOnce() == .rejected(command.operationID, code: "INVALID_ARGUMENT"))
        #expect(try await engine.flushOnce() == .idle)
    }

    @Test("重启后重复提交相同待建群意图会复用原操作")
    func duplicatePendingCreationReusesTheOriginalOperationAfterRestart() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "im-v2-group-reuse-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let firstStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let firstOperation = UUID(uuidString: "00000000-0000-0000-0000-000000000707")!
        let firstEngine = V2GroupRoomCommandOutboxEngine(
            store: firstStore,
            transport: ScriptedGroupTransport(results: []),
            makeUUID: { firstOperation }
        )

        let original = try await firstEngine.enqueueCreation(title: " 项目群 ", deliveryMode: .standardFanout, initialMemberUserIDs: [])
        let restartedStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let restartedEngine = V2GroupRoomCommandOutboxEngine(
            store: restartedStore,
            transport: ScriptedGroupTransport(results: [])
        )
        let reused = try await restartedEngine.enqueueCreation(title: "项目群", deliveryMode: .standardFanout, initialMemberUserIDs: [])

        #expect(reused.operationID == original.operationID)
        let pending = try await restartedStore.pendingGroupRoomCreations()
        #expect(pending.count == 1)
    }
}

private actor ScriptedGroupTransport: V2ClientGroupMessagingTransport {
    enum Result: Sendable { case retryableFailure, created(RoomID), rejected }
    private var results: [Result]
    private var received: [GroupRoomOperationID] = []
    init(results: [Result]) { self.results = results }

    func createGroupRoom(operationID: GroupRoomOperationID, title: String, deliveryMode: V2GroupDeliveryMode, initialMemberUserIDs: [UserID]) throws -> V2ClientGroupRoom {
        received.append(operationID)
        switch results.removeFirst() {
        case .retryableFailure: throw V2RealtimeTransportError.unexpectedResponse
        case .rejected: throw V2RealtimeTransportError.server(code: "INVALID_ARGUMENT", retryable: false, retryAfterSeconds: 0, currentRevision: 0)
        case .created(let roomID): return .init(roomID: roomID, title: title.trimmingCharacters(in: .whitespacesAndNewlines), deliveryMode: deliveryMode, memberUserIDs: initialMemberUserIDs, memberCount: UInt32(initialMemberUserIDs.count + 1), createdAt: .distantPast)
        }
    }

    func operationIDs() -> [GroupRoomOperationID] { received }
}

import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 durable membership command outbox")
struct V2MembershipCommandOutboxTests {
    @Test("network retry survives restart and reuses the original membership operation ID")
    func retrySurvivesRestart() async throws {
        let url = temporaryMembershipOutboxDatabaseURL()
        let started = Date(timeIntervalSince1970: 1_750_000_000)
        let roomID = try RoomID("00000000-0000-0000-0000-000000000601")
        let targetUserID = try UserID("00000000-0000-0000-0000-000000000602")
        let operationUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000603")!
        let transport = ScriptedMembershipTransport(results: [.retryableFailure, .acknowledged])
        let firstStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: membershipOutboxBinding)
        let firstEngine = V2MembershipCommandOutboxEngine(store: firstStore, transport: transport, makeUUID: { operationUUID }, now: { started })

        let command = try await firstEngine.enqueueMembershipChange(
            roomID: roomID,
            targetUserID: targetUserID,
            action: .add,
            expectedMembershipRevision: 4
        )
        #expect(command.operationID.rawValue == operationUUID.uuidString)
        #expect(try await firstEngine.flushOnce() == .retryScheduled(command.operationID))
        let retry = try #require(await firstStore.pendingMembershipCommands().first)
        #expect(retry.state == .pending)
        #expect(retry.attemptCount == 1)

        let restartedStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: membershipOutboxBinding)
        let restartedEngine = V2MembershipCommandOutboxEngine(store: restartedStore, transport: transport, now: { started.addingTimeInterval(1) })
        #expect(try await restartedEngine.flushOnce() == .acknowledged(command.operationID))
        let completed = try #require(await restartedStore.pendingMembershipCommands().first)
        #expect(completed.operationID == command.operationID)
        #expect(completed.state == .acknowledged)
        #expect(completed.resultingMembershipRevision == 5)
        #expect(completed.resultingRoomSequence == 8)
        #expect(await transport.operationIDs() == [command.operationID, command.operationID])
    }

    @Test("revision conflict is terminal and is not retried")
    func revisionConflictIsNotRetried() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryMembershipOutboxDatabaseURL(), installationBinding: membershipOutboxBinding)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let engine = V2MembershipCommandOutboxEngine(
            store: store,
            transport: ScriptedMembershipTransport(results: [.revisionConflict]),
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000604")! },
            now: { now }
        )
        let command = try await engine.enqueueMembershipChange(
            roomID: .init("00000000-0000-0000-0000-000000000605"),
            targetUserID: .init("00000000-0000-0000-0000-000000000606"),
            action: .remove,
            expectedMembershipRevision: 4
        )

        #expect(try await engine.flushOnce() == .rejected(command.operationID, code: "REVISION_CONFLICT"))
        let rejected = try #require(await store.pendingMembershipCommands().first)
        #expect(rejected.state == .rejected)
        #expect(rejected.terminalCode == "REVISION_CONFLICT")
        #expect(rejected.terminalCurrentRevision == 9)
        #expect(try await engine.flushOnce() == .idle)
    }

    @Test("重启后重复提交相同待成员变更会复用原操作")
    func duplicatePendingMembershipChangeReusesTheOriginalOperationAfterRestart() async throws {
        let url = temporaryMembershipOutboxDatabaseURL()
        let roomID = try RoomID("00000000-0000-0000-0000-000000000608")
        let targetUserID = try UserID("00000000-0000-0000-0000-000000000609")
        let firstStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: membershipOutboxBinding)
        let firstOperation = UUID(uuidString: "00000000-0000-0000-0000-000000000610")!
        let firstEngine = V2MembershipCommandOutboxEngine(
            store: firstStore,
            transport: ScriptedMembershipTransport(results: []),
            makeUUID: { firstOperation }
        )

        let original = try await firstEngine.enqueueMembershipChange(
            roomID: roomID,
            targetUserID: targetUserID,
            action: .add,
            expectedMembershipRevision: 4
        )
        let restartedStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: membershipOutboxBinding)
        let restartedEngine = V2MembershipCommandOutboxEngine(
            store: restartedStore,
            transport: ScriptedMembershipTransport(results: [])
        )
        let reused = try await restartedEngine.enqueueMembershipChange(
            roomID: roomID,
            targetUserID: targetUserID,
            action: .add,
            expectedMembershipRevision: 4
        )

        #expect(reused.operationID == original.operationID)
        let pending = try await restartedStore.pendingMembershipCommands()
        #expect(pending.count == 1)
    }
}

private actor ScriptedMembershipTransport: V2ClientMembershipTransport {
    enum Result: Sendable { case retryableFailure, revisionConflict, acknowledged }

    private var results: [Result]
    private var receivedOperationIDs: [MembershipOperationID] = []

    init(results: [Result]) { self.results = results }

    func changeMembership(
        roomID: RoomID,
        operationID: MembershipOperationID,
        targetUserID: UserID,
        action: V2RoomMembershipAction,
        expectedMembershipRevision _: UInt64
    ) throws -> V2ClientMembershipChange {
        receivedOperationIDs.append(operationID)
        switch results.removeFirst() {
        case .retryableFailure:
            throw V2RealtimeTransportError.unexpectedResponse
        case .revisionConflict:
            throw V2RealtimeTransportError.server(code: "REVISION_CONFLICT", retryable: false, retryAfterSeconds: 0, currentRevision: 9)
        case .acknowledged:
            return .init(roomID: roomID, targetUserID: targetUserID, action: action, membershipRevision: 5, roomSequence: 8, createdAt: .distantPast)
        }
    }

    func operationIDs() -> [MembershipOperationID] { receivedOperationIDs }
}

private func temporaryMembershipOutboxDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "im-v2-membership-outbox-\(UUID().uuidString).sqlite")
}

private let membershipOutboxBinding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!)

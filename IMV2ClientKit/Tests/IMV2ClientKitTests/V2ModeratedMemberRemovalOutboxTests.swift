import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 moderated member removal outbox")
struct V2ModeratedMemberRemovalOutboxTests {
    @Test("audit removal retries after restart with the same operation identity")
    func retrySurvivesRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-moderated-removal-\(UUID().uuidString).sqlite")
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let transport = ScriptedRemovalTransport(results: [.offline, .accepted])
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: removalBinding)
        let engine = V2ModeratedMemberRemovalOutboxEngine(store: store, transport: transport, makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000981")! }, now: { now })
        let command = try await engine.enqueueRemoval(roomID: .init("00000000-0000-0000-0000-000000000982"), targetUserID: .init("00000000-0000-0000-0000-000000000983"), reasonCode: .init("policy_violation"))
        #expect(try await engine.flushOnce() == .retryScheduled(command.operationID))

        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: removalBinding)
        let retryEngine = V2ModeratedMemberRemovalOutboxEngine(store: restarted, transport: transport, now: { now.addingTimeInterval(1) })
        #expect(try await retryEngine.flushOnce() == .acknowledged(command.operationID))
        let saved = try #require(await restarted.pendingModeratedMemberRemovals().first)
        #expect(saved.state == .acknowledged)
        #expect(saved.resultingMembershipRevision == 8)
        #expect(saved.resultingRoomSequence == 9)
        #expect(await transport.operationIDs() == [command.operationID, command.operationID])
    }

    @Test("duplicate pending audit removal after restart reuses its original operation ID")
    func duplicatePendingRemovalReusesTheOriginalOperationAfterRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-moderated-removal-\(UUID().uuidString).sqlite")
        let roomID = try RoomID("00000000-0000-0000-0000-000000000985")
        let targetUserID = try UserID("00000000-0000-0000-0000-000000000986")
        let reasonCode = try V2ModerationReasonCode("policy_violation")
        let originalStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: removalBinding)
        let originalEngine = V2ModeratedMemberRemovalOutboxEngine(
            store: originalStore,
            transport: ScriptedRemovalTransport(results: []),
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000987")! }
        )
        let original = try await originalEngine.enqueueRemoval(
            roomID: roomID,
            targetUserID: targetUserID,
            reasonCode: reasonCode
        )

        let restartedStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: removalBinding)
        let restartedEngine = V2ModeratedMemberRemovalOutboxEngine(
            store: restartedStore,
            transport: ScriptedRemovalTransport(results: [])
        )
        let reused = try await restartedEngine.enqueueRemoval(
            roomID: roomID,
            targetUserID: targetUserID,
            reasonCode: reasonCode
        )

        #expect(reused.operationID == original.operationID)
        #expect(try await restartedStore.pendingModeratedMemberRemovals().count == 1)
    }
}

private actor ScriptedRemovalTransport: V2ClientModeratedMemberRemovalTransport {
    enum Result: Sendable { case offline, accepted }
    private var results: [Result]
    private var received: [ModerationOperationID] = []
    init(results: [Result]) { self.results = results }

    func removeMemberByModerator(roomID: RoomID, operationID: ModerationOperationID, targetUserID: UserID, reasonCode _: V2ModerationReasonCode) throws -> V2ClientModeratedMemberRemoval {
        received.append(operationID)
        switch results.removeFirst() {
        case .offline: throw V2RealtimeTransportError.unexpectedResponse
        case .accepted: return try .init(roomID: roomID, targetUserID: targetUserID, membershipRevision: 8, roomSequence: 9, createdAt: .distantPast)
        }
    }

    func operationIDs() -> [ModerationOperationID] { received }
}

private let removalBinding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000984")!)

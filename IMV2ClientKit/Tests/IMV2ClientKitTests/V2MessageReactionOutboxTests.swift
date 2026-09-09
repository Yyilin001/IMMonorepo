import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 message reaction outbox")
struct V2MessageReactionOutboxTests {
    @Test("retry after restart preserves one reaction operation ID")
    func retrySurvivesRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-reaction-\(UUID().uuidString).sqlite")
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let operation = UUID(uuidString: "00000000-0000-0000-0000-000000000951")!
        let transport = ReactionTransport(results: [.retry, .accepted])
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let first = V2MessageReactionOutboxEngine(store: store, transport: transport, makeUUID: { operation }, now: { now })
        let command = try await first.enqueueReaction(roomID: .init("00000000-0000-0000-0000-000000000952"), messageID: .init("00000000-0000-0000-0000-000000000953"), reaction: "👍", action: .add)
        #expect(try await first.flushOnce() == .retryScheduled(command.operationID))
        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let second = V2MessageReactionOutboxEngine(store: restarted, transport: transport, now: { now.addingTimeInterval(1) })
        #expect(try await second.flushOnce() == .acknowledged(command.operationID))
        let saved = try #require(await restarted.pendingMessageReactions().first)
        #expect(saved.operationID == command.operationID)
        #expect(saved.state == .acknowledged)
        #expect(saved.resultingRoomSequence == 8)
    }

    @Test("duplicate pending reaction after restart reuses its original operation ID")
    func duplicatePendingReactionReusesTheOriginalOperationAfterRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-reaction-\(UUID().uuidString).sqlite")
        let roomID = try RoomID("00000000-0000-0000-0000-000000000956")
        let messageID = try MessageID("00000000-0000-0000-0000-000000000957")
        let originalStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let originalEngine = V2MessageReactionOutboxEngine(
            store: originalStore,
            transport: ReactionTransport(results: []),
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000958")! }
        )
        let original = try await originalEngine.enqueueReaction(
            roomID: roomID,
            messageID: messageID,
            reaction: "👍",
            action: .add
        )

        let restartedStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let restartedEngine = V2MessageReactionOutboxEngine(
            store: restartedStore,
            transport: ReactionTransport(results: [])
        )
        let reused = try await restartedEngine.enqueueReaction(
            roomID: roomID,
            messageID: messageID,
            reaction: "👍",
            action: .add
        )

        #expect(reused.operationID == original.operationID)
        let removal = try await restartedEngine.enqueueReaction(
            roomID: roomID,
            messageID: messageID,
            reaction: "👍",
            action: .remove
        )
        #expect(removal.operationID != original.operationID)
        #expect(try await restartedStore.pendingMessageReactions().count == 2)
    }
}

private let binding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000954")!)

private actor ReactionTransport: V2ClientMessageReactionTransport {
    enum Result { case retry, accepted }
    private var results: [Result]
    init(results: [Result]) { self.results = results }
    func changeMessageReaction(roomID: RoomID, operationID _: MessageReactionOperationID, messageID: MessageID, reaction: String, action: V2MessageReactionAction) throws -> V2ClientMessageReactionChange {
        switch results.removeFirst() {
        case .retry: throw V2RealtimeTransportError.unexpectedResponse
        case .accepted: return try .init(roomID: roomID, messageID: messageID, actorUserID: try .init("00000000-0000-0000-0000-000000000955"), reaction: reaction, action: action, roomSequence: 8, createdAt: .distantPast)
        }
    }
}

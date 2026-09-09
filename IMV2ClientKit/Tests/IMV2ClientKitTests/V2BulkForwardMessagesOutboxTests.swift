import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 bulk forward plans")
struct V2BulkForwardMessagesOutboxTests {
    @Test("large plans are lazily chunked, resumable, and complete with exact totals")
    func chunksLargePlan() async throws {
        let store = try makeStore()
        let transport = BulkForwardTransport()
        let engine = V2BulkForwardMessagesOutboxEngine(
            store: store,
            transport: transport,
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-00000000f001")! }
        )
        let sources = try (1 ... 45).map { try MessageID(String(format: "00000000-0000-0000-0000-%012x", $0)) }
        let targets = try [RoomID("00000000-0000-0000-0000-00000000f101"), RoomID("00000000-0000-0000-0000-00000000f102")]

        let plan = try await engine.enqueue(sources: try sources.map(testForwardReference), targetRoomIDs: targets)
        #expect(plan.totalForwardCount == 90)

        for _ in 0 ..< 6 {
            guard case .chunkAcknowledged = try await engine.flushOnce() else {
                Issue.record("expected a forward chunk")
                return
            }
        }
        #expect(try await engine.flushOnce() == .idle)
        let completed = try #require(await engine.plan(operationID: plan.operationID))
        #expect(completed.state == .completed)
        #expect(completed.succeededCount == 90)
        #expect(completed.failedCount == 0)

        let commands = await transport.commands
        #expect(commands.count == 6)
        #expect(commands.allSatisfy { $0.sourceMessageIDs.count <= 20 && $0.targetRoomIDs.count == 1 })
        let expectedIDs = try (0..<6).map { try V2ForwardChunkIdentity.operationID(planID: plan.operationID, chunkIndex: UInt64($0)) }
        #expect(commands.map(\.operationID) == expectedIDs)
        #expect(commands.allSatisfy { $0.operationID.uuidValue != nil })
    }

    @Test("cancelling a plan stops undelivered chunks without changing completed work")
    func cancelStopsUndeliveredChunks() async throws {
        let store = try makeStore()
        let transport = BulkForwardTransport()
        let engine = V2BulkForwardMessagesOutboxEngine(
            store: store,
            transport: transport,
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-00000000f201")! }
        )
        let sources = try (1 ... 25).map { try MessageID(String(format: "00000000-0000-0000-0000-%012x", 500 + $0)) }
        let target = try RoomID("00000000-0000-0000-0000-00000000f202")
        let plan = try await engine.enqueue(sources: try sources.map(testForwardReference), targetRoomIDs: [target])

        guard case .chunkAcknowledged = try await engine.flushOnce() else {
            Issue.record("expected first chunk")
            return
        }
        try await engine.cancel(operationID: plan.operationID)
        #expect(try await engine.flushOnce() == .idle)
        let cancelled = try #require(await engine.plan(operationID: plan.operationID))
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.succeededCount == 20)
        #expect(cancelled.failedCount == 0)
    }

    @Test("a restart resumes the deterministic next chunk of a durable plan")
    func restartResumesPlan() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-bulk-forward-restart-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let sources = try (1 ... 25).map { try MessageID(String(format: "00000000-0000-0000-0000-%012x", 900 + $0)) }
        let target = try RoomID("00000000-0000-0000-0000-00000000f302")
        let firstTransport = BulkForwardTransport()
        let first = V2BulkForwardMessagesOutboxEngine(
            store: try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding),
            transport: firstTransport,
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-00000000f301")! }
        )
        let plan = try await first.enqueue(sources: try sources.map(testForwardReference), targetRoomIDs: [target])
        guard case .chunkAcknowledged = try await first.flushOnce() else {
            Issue.record("expected first chunk")
            return
        }

        let secondTransport = BulkForwardTransport()
        let restarted = V2BulkForwardMessagesOutboxEngine(
            store: try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding),
            transport: secondTransport
        )
        guard case .chunkAcknowledged = try await restarted.flushOnce() else {
            Issue.record("expected resumed chunk")
            return
        }
        let completed = try #require(await restarted.plan(operationID: plan.operationID))
        #expect(completed.state == .completed)
        #expect(completed.succeededCount == 25)
        #expect((await secondTransport.commands).map(\.sourceMessageIDs.count) == [5])
    }

    private func makeStore() throws -> GRDBV2LocalSyncStore {
        try .init(
            databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-v2-bulk-forward-\(UUID().uuidString).sqlite"),
            installationBinding: .init(value: UUID())
        )
    }
}

private actor BulkForwardTransport: V2ClientForwardMessagesTransport {
    private(set) var commands: [V2ForwardMessagesCommand] = []

    func forwardMessages(command: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult] {
        commands.append(command)
        return try command.sourceMessageIDs.map { source in
            try .init(sourceMessageID: source, targetRoomID: command.targetRoomIDs[0], messageID: source, roomSequence: 1, errorCode: nil)
        }
    }
}

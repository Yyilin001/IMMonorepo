import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Forward chunk UUID restart preserves retry identity")
struct V2ForwardChunkIdentityRestartTests {
    @Test("reopening preserves completed and pending UUID identities")
    func restartPreservesIdentity() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-forward-uuid-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let local = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let sources = try (0..<25).map { _ in try testForwardReference(.init(uuid: UUID())) }
        let target = RoomID(uuid: UUID())
        let transport = UUIDForwardTransport()
        let first = V2BulkForwardMessagesOutboxEngine(store: local, transport: transport, now: { Date(timeIntervalSince1970: 100) })
        let plan = try await first.enqueue(sources: sources, targetRoomIDs: [target])
        guard case .chunkAcknowledged(_, let completedID, let results) = try await first.flushOnce() else { Issue.record("first chunk did not complete"); return }
        let pending = try #require(try await local.nextReadyForwardPlanChunk(now: Date(timeIntervalSince1970: 100)))
        try await local.scheduleForwardPlanChunkRetry(operationID: pending.command.operationID, nextAttemptAt: Date(timeIntervalSince1970: 300))
        let second = V2BulkForwardMessagesOutboxEngine(store: local, transport: transport, now: { Date(timeIntervalSince1970: 200) })
        let validPlan = try await second.enqueue(sources: [sources[0]], targetRoomIDs: [target])
        let validPending = try #require(try await local.nextReadyForwardPlanChunk(now: Date(timeIntervalSince1970: 200)))
        try await local.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let retry = try #require(try await reopened.nextReadyForwardPlanChunk(now: Date(timeIntervalSince1970: 300)))
        #expect(retry.command == pending.command)
        #expect(retry.attemptCount == 1 && retry.nextAttemptAt == Date(timeIntervalSince1970: 300))
        #expect(try await reopened.forwardPlan(operationID: plan.operationID)?.succeededCount == 20)
        #expect(try await reopened.markForwardPlanChunkAcknowledged(operationID: completedID, results: results, now: .now) == plan.operationID)
        let inspect = try DatabaseQueue(path: url.path)
        try await inspect.read { db in
            let validID = try String.fetchOne(db, sql: "SELECT operation_id FROM v2_forward_message_chunks WHERE plan_id = ?", arguments: [validPlan.operationID.rawValue])
            let completed = try String.fetchOne(db, sql: "SELECT operation_id FROM v2_forward_message_chunks WHERE plan_id = ? AND chunk_index = 0", arguments: [plan.operationID.rawValue])
            #expect(validID == validPending.command.operationID.rawValue)
            #expect(completed == completedID.rawValue)
        }
        try inspect.close()
        let resumed = V2BulkForwardMessagesOutboxEngine(store: reopened, transport: transport, now: { Date(timeIntervalSince1970: 300) })
        _ = try await resumed.flushOnce()
        #expect(try await resumed.plan(operationID: plan.operationID)?.succeededCount == 25)
        #expect(await transport.operations.allSatisfy { $0.uuidValue != nil })
        try await reopened.close()
    }
}

private actor UUIDForwardTransport: V2ClientForwardMessagesTransport {
    private(set) var operations: [MessageForwardOperationID] = []
    func forwardMessages(command: V2ForwardMessagesCommand) throws -> [V2ForwardMessageResult] {
        guard command.operationID.uuidValue != nil else { throw V2CoreError.invalidIdentifier }
        operations.append(command.operationID)
        return try command.sources.map { try .init(sourceMessageID: $0.messageID, targetRoomID: command.targetRoomIDs[0], messageID: .init(uuid: UUID()), roomSequence: 1, errorCode: nil) }
    }
}

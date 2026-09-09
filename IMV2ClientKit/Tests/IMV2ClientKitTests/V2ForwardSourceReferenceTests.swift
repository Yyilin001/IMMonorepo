import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Forward source intent survives persistence and protocol boundaries")
struct V2ForwardSourceReferenceTests {
    @Test("lazy chunks preserve mixed source rooms and revisions after reopen and reject changed plan input")
    func durableReferences() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-forward-context-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let local = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let wire = ReferenceForwardWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: UInt8(IMV2ProtocolVersion.current))
        let sources = try (0..<25).map { index in
            V2ForwardMessageReference(roomID: .init(uuid: index % 2 == 0 ? UUID(uuidString: "00000000-0000-0000-0000-00000000a001")! : UUID(uuidString: "00000000-0000-0000-0000-00000000a002")!), messageID: .init(uuid: UUID()), revision: try .init(UInt64(index + 1)))
        }
        let targets: [RoomID] = [.init(uuid: UUID())]
        let first = V2BulkForwardMessagesOutboxEngine(store: local, transport: transport)
        let plan = try await first.enqueue(sources: sources, targetRoomIDs: targets)
        _ = try await first.flushOnce()
        try await local.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let resumed = V2BulkForwardMessagesOutboxEngine(store: reopened, transport: transport)
        for changed in [
            V2ForwardMessageReference(roomID: .init(uuid: UUID()), messageID: sources[0].messageID, revision: sources[0].revision),
            V2ForwardMessageReference(roomID: sources[0].roomID, messageID: sources[0].messageID, revision: try .init(42))
        ] {
            await #expect(throws: V2ClientCommandError.commandConflict) {
                try await reopened.enqueueForwardPlan(plan, sources: [changed] + sources.dropFirst(), targetRoomIDs: targets, now: .now)
            }
        }
        _ = try await resumed.flushOnce()
        let requests = await wire.requests
        #expect(requests.count == 2)
        #expect(requests.flatMap(\.sources).map(\.roomID) == sources.map { $0.roomID.rawValue })
        #expect(requests.flatMap(\.sources).map(\.messageID) == sources.map { $0.messageID.rawValue })
        #expect(requests.flatMap(\.sources).map(\.revision) == sources.map { $0.revision.rawValue })
        #expect(try await resumed.plan(operationID: plan.operationID)?.succeededCount == 25)
        try await reopened.close()
    }

    @Test("upgrading an old queue preserves completed receipts but never invents the selected version")
    func legacyQueueMigration() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-forward-legacy-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let local = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let transport = V2ProtobufSyncTransport(wire: ReferenceForwardWire(), protocolVersion: UInt8(IMV2ProtocolVersion.current))
        let sources = try (0..<25).map { _ in try testForwardReference(.init(uuid: UUID())) }
        let target = RoomID(uuid: UUID())
        let engine = V2BulkForwardMessagesOutboxEngine(store: local, transport: transport)
        let plan = try await engine.enqueue(sources: sources, targetRoomIDs: [target])
        guard case .chunkAcknowledged(_, let completedID, let results) = try await engine.flushOnce() else { Issue.record("expected first chunk"); return }
        _ = try await local.nextReadyForwardPlanChunk(now: .now)
        let ordinary = try await V2ForwardMessagesOutboxEngine(store: local, transport: transport).enqueue(sources: [sources[0]], targetRoomIDs: [target])
        try await local.close()
        let old = try DatabaseQueue(path: url.path)
        try await old.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'bindForwardSourceReferences'")
            for table in ["v2_pending_forward_messages", "v2_forward_message_plans", "v2_forward_message_chunks"] {
                try db.execute(sql: "ALTER TABLE \(table) DROP COLUMN source_references")
            }
            try db.execute(sql: "ALTER TABLE v2_forward_message_plans DROP COLUMN terminal_code")
        }
        try old.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let migrated = try #require(try await reopened.forwardPlan(operationID: plan.operationID))
        #expect(migrated.state == .cancelled && migrated.terminalCode == "SOURCE_RESELECTION_REQUIRED")
        #expect(migrated.succeededCount == 20 && migrated.failedCount == 0 && migrated.totalForwardCount == 25)
        #expect(try await reopened.nextReadyForwardPlanChunk(now: .distantFuture) == nil)
        #expect(try await reopened.nextReadyForwardMessages(now: .distantFuture) == nil)
        // The already committed chunk digest remains independently replayable.
        #expect(try await reopened.markForwardPlanChunkAcknowledged(operationID: completedID, results: results, now: .now) == plan.operationID)
        let inspection = try DatabaseQueue(path: url.path)
        try await inspection.read { db in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT state, terminal_code, source_references FROM v2_pending_forward_messages WHERE operation_id = ?", arguments: [ordinary.command.operationID.rawValue]))
            #expect(row["state"] as String == "rejected")
            #expect(row["terminal_code"] as String == "SOURCE_RESELECTION_REQUIRED")
            #expect(row["source_references"] as String? == nil)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM v2_forward_message_chunks WHERE state = 'cancelled' AND terminal_code = 'SOURCE_RESELECTION_REQUIRED'") == 1)
        }
        try inspection.close()
        try await reopened.close()
    }
}

private actor ReferenceForwardWire: V2AuthenticatedFrameTransport {
    private(set) var requests: [IMV2ForwardMessages] = []
    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        guard UUID(uuidString: request.forwardMessages.operationID) != nil else { throw V2CoreError.invalidIdentifier }
        requests.append(request.forwardMessages)
        var response = IMV2Envelope()
        response.protocolVersion = request.protocolVersion
        response.requestID = request.requestID
        response.messagesForwarded = .init()
        response.messagesForwarded.results = request.forwardMessages.sources.map { source in
            var result = IMV2ForwardMessageResult()
            result.sourceMessageID = source.messageID
            result.targetRoomID = request.forwardMessages.targetRoomIds[0]
            result.messageID = UUID().uuidString
            result.roomSequence = 1
            return result
        }
        return try V2ProtobufFrameCodec.encode(response, frameVersion: frame.version)
    }
}

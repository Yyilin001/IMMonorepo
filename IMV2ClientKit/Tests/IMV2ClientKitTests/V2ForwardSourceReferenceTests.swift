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

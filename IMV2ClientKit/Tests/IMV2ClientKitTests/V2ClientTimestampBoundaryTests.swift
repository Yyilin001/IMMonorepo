import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

struct V2ClientTimestampBoundaryTests {
    @Test("member administration rejects out-of-domain millisecond timestamps", arguments: [UInt64(0), UInt64(Int64.max) + 1, UInt64.max])
    func invalidMuteTimestamp(milliseconds: UInt64) throws {
        #expect(throws: V2MemberAdministrationValidationError.invalidIntent) {
            try V2MemberAdministrationIntent(roomID: .init(uuid: UUID()), actorUserID: .init(uuid: UUID()),
                operationID: .init(uuid: UUID()), targetUserID: .init(uuid: UUID()),
                action: .mute(untilMilliseconds: milliseconds), reasonCode: .init("policy_violation"),
                expectedMembershipRevision: 0, confirmedUntilMilliseconds: 1_750_000_120_000)
        }
    }

    @Test("heartbeat rejects nonfinite and UInt64-overflow timestamps before writing", arguments: [
        Double.nan, Double.infinity, -Double.infinity, Double(UInt64.max) / 1_000
    ])
    func heartbeatRejectsInvalidTime(seconds: Double) async throws {
        let wire = TimestampWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: UInt8(IMV2ProtocolVersion.current))
        await #expect(throws: V2RealtimeTransportError.unexpectedResponse) {
            try await transport.sendHeartbeat(clientTime: Date(timeIntervalSince1970: seconds))
        }
        #expect(await wire.times().isEmpty)
    }

    @Test("heartbeat keeps truncation, pre-epoch clamping and representable large unsigned times", arguments: [
        (1_750_000_000.1239, UInt64(1_750_000_000_123)), (-1.5, UInt64(0)),
        (10_000_000_000_000_000.0, UInt64(10_000_000_000_000_000_000))
    ])
    func heartbeatPreservesValidTime(sample: (Double, UInt64)) async throws {
        let wire = TimestampWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: UInt8(IMV2ProtocolVersion.current))
        try await transport.sendHeartbeat(clientTime: Date(timeIntervalSince1970: sample.0))
        #expect(await wire.times() == [sample.1])
    }

    @Test("moderation's largest wire timestamp survives SQLite readback and reopen")
    func moderationExtremeTimestampSurvivesReadback() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-timestamp-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "client.sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let room = RoomID(uuid: UUID())
        let event = try V2ClientGroupEvent(
            sourceEventID: EventID(uuid: UUID()), roomSequence: 1, projectionKind: "moderation",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "member.muted", "room_id": room.rawValue,
                "room_sequence": 1, "actor_user_id": UUID().uuidString,
                "target_user_id": UUID().uuidString, "mute_until_ms": Int64.max,
                "server_created_at_ms": 1_750_000_000_000
            ])
        )
        _ = try await store.applyGroupEventPage(.init(roomID: room, events: [event], nextRoomSequence: 1, hasMore: false))
        let first = try #require(await store.moderationActions().first)
        #expect(first.muteUntil == Date(timeIntervalSince1970: Double(Int64.max) / 1_000))
        try await store.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        #expect(try await reopened.moderationActions() == [first])
        try await reopened.close()
    }
}

private actor TimestampWire: V2AuthenticatedFrameTransport {
    private var received: [UInt64] = []
    func times() -> [UInt64] { received }
    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        guard case .heartbeat(let heartbeat) = request.body else {
            Issue.record("Invalid mutation must not reach the wire")
            throw V2RealtimeTransportError.unexpectedResponse
        }
        received.append(heartbeat.clientTimeMs)
        var response = IMV2Envelope()
        response.requestID = request.requestID
        response.protocolVersion = UInt32(frame.version)
        response.heartbeatAck = .init()
        return try V2ProtobufFrameCodec.encode(response, frameVersion: frame.version)
    }
}

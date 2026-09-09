import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

struct V2ClientTimestampBoundaryTests {
    @Test("invalid mute dates are rejected before persistence or a network request", arguments: [
        Double.nan, Double.infinity, -Double.infinity, Double(Int64.max) / 1_000,
        Double(Int64.min).nextDown / 1_000
    ])
    func invalidMuteDateHasNoSideEffects(seconds: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-timestamp-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "client.sqlite"), installationBinding: .init(value: UUID()))
        let wire = TimestampWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: UInt8(IMV2ProtocolVersion.current))
        let engine = V2MemberMuteOutboxEngine(store: store, transport: transport)
        let room = RoomID(uuid: UUID()), target = UserID(uuid: UUID())
        let expiry = Date(timeIntervalSince1970: seconds)
        await #expect(throws: V2ModerationValidationError.invalidMuteExpiry) {
            try await engine.enqueueMute(roomID: room, targetUserID: target, muteUntil: expiry, reasonCode: .init("policy_violation"))
        }
        await #expect(throws: V2RealtimeTransportError.unexpectedResponse) {
            try await transport.muteMember(roomID: room, operationID: .init(UUID().uuidString), targetUserID: target, muteUntil: expiry, reasonCode: .init("policy_violation"))
        }
        #expect(try await store.pendingMemberMutes().isEmpty)
        #expect(await wire.times().isEmpty)
        try await store.close()
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
        let record = try V2ClientSyncRecord(
            sequence: 1, sourceEventID: EventID(uuid: UUID()), projectionKind: "moderation",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "member.muted", "room_id": UUID().uuidString,
                "room_sequence": 1, "actor_user_id": UUID().uuidString,
                "target_user_id": UUID().uuidString, "mute_until_ms": Int64.max,
                "server_created_at_ms": 1_750_000_000_000
            ])
        )
        _ = try await store.apply(.init(generation: 1, records: [record], nextSyncToken: .init("token"),
            receipt: .init("receipt"), hasMore: false, capabilityProfile: "base"))
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

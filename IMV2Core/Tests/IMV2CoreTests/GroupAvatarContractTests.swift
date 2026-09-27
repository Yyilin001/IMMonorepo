import Foundation
import IMV2Core
import Testing

@Suite("Group avatar logical contracts")
struct GroupAvatarContractTests {
    @Test("durable intents and receipts round trip without provider state")
    func roundTrip() throws {
        let room = RoomID(uuid: UUID()), media = MediaID(uuid: UUID())
        let command = try V2GroupAvatarCommand(operationID: .init(uuid: UUID()), roomID: room,
            expectedRevision: 0, mutation: .set(media))
        let receipt = try V2GroupAvatarChange(state: .init(roomID: room, mediaID: media, revision: 1),
            roomSequence: 5, updatedAt: Date(timeIntervalSince1970: 1_800_000_000.123))
        #expect(try JSONDecoder().decode(V2GroupAvatarCommand.self, from: JSONEncoder().encode(command)) == command)
        #expect(try JSONDecoder().decode(V2GroupAvatarChange.self, from: JSONEncoder().encode(receipt)) == receipt)
        let removed = try V2GroupAvatarState(roomID: room, mediaID: nil, revision: 2)
        #expect(try JSONDecoder().decode(V2GroupAvatarState.self, from: JSONEncoder().encode(removed)) == removed)
        #expect(try V2GroupAvatarState(roomID: room, mediaID: nil, revision: 0).revision == 0)
    }

    @Test("decoding enforces UUIDs, durable revision range and nonzero receipt sequence")
    func invalidDecode() throws {
        let room = RoomID(uuid: UUID()), media = MediaID(uuid: UUID())
        let command = try V2GroupAvatarCommand(operationID: .init(uuid: UUID()), roomID: room,
            expectedRevision: 0, mutation: .set(media))
        for (key, value): (String, Any) in [("expectedRevision", UInt64.max), ("operationID", "invalid"), ("roomID", "invalid")] {
            let bytes = try mutated(command, key: key, value: value)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(V2GroupAvatarCommand.self, from: bytes) }
        }
        let state = try V2GroupAvatarState(roomID: room, mediaID: media, revision: 1)
        let invalidState = try mutated(state, key: "revision", value: 0)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(V2GroupAvatarState.self, from: invalidState) }
        let receipt = try V2GroupAvatarChange(state: state, roomSequence: 1, updatedAt: Date())
        let invalidReceipt = try mutated(receipt, key: "roomSequence", value: 0)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(V2GroupAvatarChange.self, from: invalidReceipt) }
    }

    private func mutated<T: Encodable>(_ value: T, key: String, value replacement: Any) throws -> Data {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        json[key] = replacement
        return try JSONSerialization.data(withJSONObject: json)
    }

    @Test("command replies bind the immutable receipt to the full original intent")
    func commandResponse() throws {
        let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID())
        let command = try V2GroupAvatarCommand(operationID: .init(uuid: UUID()), roomID: room, expectedRevision: 1, mutation: .remove)
        let change = try V2GroupAvatarChange(state: .init(roomID: room, mediaID: nil, revision: 2), roomSequence: 7, updatedAt: Date())
        let response = try V2GroupAvatarCommandResponse(actorUserID: actor, deviceID: device, command: command, outcome: .committed(change))
        #expect(try JSONDecoder().decode(V2GroupAvatarCommandResponse.self, from: JSONEncoder().encode(response)) == response)
        let mismatched = try V2GroupAvatarCommand(operationID: command.operationID, roomID: room, expectedRevision: 0, mutation: .remove)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mismatched))
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(V2GroupAvatarCommandResponse.self, from: mutated(response, key: "command", value: json))
        }
        let wrongMedia = try V2GroupAvatarCommand(operationID: command.operationID, roomID: room, expectedRevision: 1, mutation: .set(.init(uuid: UUID())))
        #expect(throws: (any Error).self) {
            try V2GroupAvatarCommandResponse(actorUserID: actor, deviceID: device, command: wrongMedia, outcome: .committed(change))
        }
        for outcome: V2GroupAvatarCommandResponse.Outcome in [.revisionConflict, .idempotencyConflict, .resourceUnavailable, .forbidden] {
            let value = try V2GroupAvatarCommandResponse(actorUserID: actor, deviceID: device, command: command, outcome: outcome)
            #expect(try JSONDecoder().decode(V2GroupAvatarCommandResponse.self, from: JSONEncoder().encode(value)) == value)
        }
    }

    @Test("recovery binds its action and full command; close cannot return an unresolved result")
    func recoveryContract() throws {
        let room = RoomID(uuid: UUID()), actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
        let command = try V2GroupAvatarCommand(operationID: .init(uuid: UUID()), roomID: room, expectedRevision: 0, mutation: .remove)
        for result: V2GroupAvatarRecoveryResult in [.closed, .unresolved, .idempotencyConflict] {
            let response = try V2GroupAvatarRecoveryResponse(actorUserID: actor, deviceID: device,
                request: .init(command: command, action: .query), result: result)
            #expect(try JSONDecoder().decode(V2GroupAvatarRecoveryResponse.self, from: JSONEncoder().encode(response)) == response)
        }
        #expect(throws: (any Error).self) {
            try V2GroupAvatarRecoveryResponse(actorUserID: actor, deviceID: device,
                request: .init(command: command, action: .closeIfAbsent), result: .unresolved)
        }
        let committed = try V2GroupAvatarChange(state: .init(roomID: room, mediaID: .init(uuid: UUID()), revision: 1), roomSequence: 1, updatedAt: Date())
        #expect(throws: (any Error).self) {
            try V2GroupAvatarRecoveryResponse(actorUserID: actor, deviceID: device,
                request: .init(command: command, action: .query), result: .committed(committed))
        }
    }

    @Test("group presentation binds viewer, resource generation and independent byte/display deadlines")
    func presentationLease() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
        let state = try V2GroupAvatarState(roomID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()), revision: 2)
        let checksum = try V2ResourceChecksum(value: String(repeating: "1", count: 64))
        let access = try V2ResourceAvatarAccess(mediaID: #require(state.mediaID), variantID: .init(uuid: UUID()), version: 1,
            checksum: checksum, plan: .init(mode: .httpGet, url: #require(URL(string: "https://delivery.invalid/avatar")),
                expiresAt: now.addingTimeInterval(120), expectedByteCount: 8, checksum: checksum))
        let value = try V2GroupAvatarPresentation(actorUserID: actor, deviceID: device, state: state,
            membershipRevision: 3, resourceGeneration: 1, canManage: false, avatar: access,
            observedAt: now, validUntil: now.addingTimeInterval(300), serverNow: now)
        #expect(try JSONDecoder().decode(V2GroupAvatarPresentation.self, from: JSONEncoder().encode(value)) == value)
        for (key, replacement): (String, Any) in [("resourceGeneration", NSNull()), ("avatar", NSNull()),
            ("validUntilUnixMilliseconds", Int64.max), ("serverNowUnixMilliseconds", value.validUntilUnixMilliseconds),
            ("observedAtUnixMilliseconds", value.observedAtUnixMilliseconds - 1), ("actorUserID", "bad")] {
            let bytes = try mutated(value, key: key, value: replacement)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(V2GroupAvatarPresentation.self, from: bytes) }
        }
    }
}

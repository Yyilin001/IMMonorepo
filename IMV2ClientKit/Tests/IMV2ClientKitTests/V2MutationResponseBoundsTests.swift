import Foundation
import IMV2ClientKit
import IMV2Core
import Testing

struct V2MutationResponseBoundsTests {
    @Test(arguments: ["editRevision", "editSequence", "withdrawalRevision", "withdrawalSequence", "membershipRevision", "membershipSequence", "redactionRevision", "redactionSequence", "muteSequence", "removalRevision", "removalSequence", "receiptSequence", "reactionSequence"],
          [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func responseIntegers(scenario: String, value: UInt64) async throws {
        let transport = V2ProtobufSyncTransport(wire: MutationBoundsWire(scenario: scenario, value: value), protocolVersion: 1)
        let room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID()), user = UserID(uuid: UUID())
        let expected: UInt64 = scenario.hasSuffix("Revision") && value > 1 && value <= UInt64(Int64.max) ? value - 1 : 1
        func returnedValue() async throws -> UInt64 {
            switch scenario {
            case "editRevision", "editSequence":
                let result = try await transport.editMessage(roomID: room, operationID: .init(uuid: UUID()), messageID: message, expectedMessageRevision: expected, text: "text")
                return scenario.hasSuffix("Revision") ? result.messageRevision : result.roomSequence
            case "withdrawalRevision", "withdrawalSequence":
                let result = try await transport.withdrawMessage(roomID: room, operationID: .init(uuid: UUID()), messageID: message, expectedMessageRevision: expected)
                return scenario.hasSuffix("Revision") ? result.messageRevision : result.roomSequence
            case "membershipRevision", "membershipSequence":
                let result = try await transport.changeMembership(roomID: room, operationID: .init(uuid: UUID()), targetUserID: user, action: .add, expectedMembershipRevision: expected)
                return scenario.hasSuffix("Revision") ? result.membershipRevision : result.roomSequence
            case "redactionRevision", "redactionSequence":
                let result = try await transport.redactMessage(roomID: room, operationID: .init(uuid: UUID()), messageID: message, reasonCode: .init("test"))
                return scenario.hasSuffix("Revision") ? result.messageRevision : result.roomSequence
            case "muteSequence":
                return try await transport.muteMember(roomID: room, operationID: .init(uuid: UUID()), targetUserID: user, muteUntil: Date(timeIntervalSince1970: 2_000_000_000), reasonCode: .init("test")).roomSequence
            case "removalRevision", "removalSequence":
                let result = try await transport.removeMemberByModerator(roomID: room, operationID: .init(uuid: UUID()), targetUserID: user, reasonCode: .init("test"))
                return scenario.hasSuffix("Revision") ? result.membershipRevision : result.roomSequence
            case "receiptSequence":
                return try await transport.recordReadReceipt(roomID: room, operationID: .init(uuid: UUID()), readThroughRoomSequence: 1).readThroughRoomSequence
            default:
                return try await transport.changeMessageReaction(roomID: room, operationID: .init(uuid: UUID()), messageID: message, reaction: "👍", action: .add).roomSequence
            }
        }
        let advancesContent = ["editRevision", "withdrawalRevision", "redactionRevision", "membershipRevision"].contains(scenario)
        if value == 0 || value > UInt64(Int64.max) || (advancesContent && value == 1) {
            await #expect(throws: V2RealtimeTransportError.unexpectedResponse) { _ = try await returnedValue() }
        } else {
            #expect(try await returnedValue() == value)
        }
    }

    @Test(arguments: ["editRevision", "withdrawalRevision", "membershipRevision"],
          [UInt64(1), UInt64(Int64.max) - 1, UInt64(Int64.max)])
    func committedRevision(scenario: String, expected: UInt64) async throws {
        let room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID()), user = UserID(uuid: UUID())
        for returned in [expected - 1, expected, expected + 1, expected + 2] {
            let transport = V2ProtobufSyncTransport(wire: MutationBoundsWire(scenario: scenario, value: returned), protocolVersion: 1)
            func result() async throws -> UInt64 {
                switch scenario {
                case "editRevision":
                    return try await transport.editMessage(roomID: room, operationID: .init(uuid: UUID()), messageID: message, expectedMessageRevision: expected, text: "text").messageRevision
                case "withdrawalRevision":
                    return try await transport.withdrawMessage(roomID: room, operationID: .init(uuid: UUID()), messageID: message, expectedMessageRevision: expected).messageRevision
                default:
                    return try await transport.changeMembership(roomID: room, operationID: .init(uuid: UUID()), targetUserID: user, action: .add, expectedMembershipRevision: expected).membershipRevision
                }
            }
            if returned == expected + 1 && returned <= UInt64(Int64.max) {
                #expect(try await result() == returned)
            } else {
                await #expect(throws: V2RealtimeTransportError.unexpectedResponse) { _ = try await result() }
            }
        }
    }
}

private actor MutationBoundsWire: V2AuthenticatedFrameTransport {
    let scenario: String
    let value: UInt64
    init(scenario: String, value: UInt64) { self.scenario = scenario; self.value = value }
    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        let revision: UInt64 = scenario.hasSuffix("Revision") ? value : 2
        let sequence: UInt64 = scenario.hasSuffix("Sequence") ? value : 2
        var response = IMV2Envelope()
        response.protocolVersion = 1
        response.requestID = frame.requestID
        switch request.body {
        case .editMessage(let request):
            response.messageEdited.roomID = request.roomID; response.messageEdited.messageID = request.messageID
            response.messageEdited.text = request.content.text; response.messageEdited.messageRevision = revision
            response.messageEdited.roomSequence = sequence; response.messageEdited.serverCreatedAtMs = 1_000
        case .withdrawMessage(let request):
            response.messageWithdrawn.roomID = request.roomID; response.messageWithdrawn.messageID = request.messageID
            response.messageWithdrawn.messageRevision = revision; response.messageWithdrawn.roomSequence = sequence; response.messageWithdrawn.serverCreatedAtMs = 1_000
        case .changeRoomMembership(let request):
            response.membershipChanged.roomID = request.roomID; response.membershipChanged.targetUserID = request.targetUserID
            response.membershipChanged.action = request.action; response.membershipChanged.membershipRevision = revision
            response.membershipChanged.roomSequence = sequence; response.membershipChanged.serverCreatedAtMs = 1_000
        case .moderateMessage(let request):
            response.messageRedacted.roomID = request.roomID; response.messageRedacted.messageID = request.messageID
            response.messageRedacted.messageRevision = revision; response.messageRedacted.roomSequence = sequence; response.messageRedacted.serverCreatedAtMs = 1_000
        case .muteMember(let request):
            response.memberMuted.roomID = request.roomID; response.memberMuted.targetUserID = request.targetUserID
            response.memberMuted.muteUntilMs = request.muteUntilMs; response.memberMuted.roomSequence = sequence; response.memberMuted.serverCreatedAtMs = 1_000
        case .moderateMemberRemoval(let request):
            response.memberRemovedByModerator.roomID = request.roomID; response.memberRemovedByModerator.targetUserID = request.targetUserID
            response.memberRemovedByModerator.membershipRevision = revision; response.memberRemovedByModerator.roomSequence = sequence; response.memberRemovedByModerator.serverCreatedAtMs = 1_000
        case .recordReadReceipt(let request):
            response.readReceiptRecorded.roomID = request.roomID; response.readReceiptRecorded.userID = UUID().uuidString
            response.readReceiptRecorded.readThroughRoomSequence = sequence; response.readReceiptRecorded.recordedAtMs = 1_000
        case .changeMessageReaction(let request):
            response.messageReactionChanged.roomID = request.roomID; response.messageReactionChanged.messageID = request.messageID
            response.messageReactionChanged.actorUserID = UUID().uuidString; response.messageReactionChanged.reaction = request.reaction
            response.messageReactionChanged.action = request.action; response.messageReactionChanged.roomSequence = sequence; response.messageReactionChanged.serverCreatedAtMs = 1_000
        default: throw V2RealtimeTransportError.unexpectedResponse
        }
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }
}

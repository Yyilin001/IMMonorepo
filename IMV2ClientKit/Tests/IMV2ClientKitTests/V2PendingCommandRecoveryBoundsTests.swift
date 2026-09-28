import Foundation
import IMV2Core
import GRDB
@testable import IMV2ClientKit
import Testing

struct V2PendingCommandRecoveryBoundsTests {
    static let fields = [
        "edit.expected_message_revision", "edit.resulting_message_revision", "edit.resulting_room_sequence", "edit.terminal_current_revision",
        "withdrawal.expected_message_revision", "withdrawal.resulting_message_revision", "withdrawal.resulting_room_sequence", "withdrawal.terminal_current_revision",
        "membership.expected_membership_revision", "membership.resulting_membership_revision", "membership.resulting_room_sequence", "membership.terminal_current_revision",
        "receipt.read_through_room_sequence", "receipt.resulting_room_sequence"
    ]

    @Test(arguments: fields, [Int64.min, -1, 0, 1, Int64.max])
    func storedIntegers(scenario: String, value: Int64) throws {
        try checkStoredValue(scenario: scenario, value: value.databaseValue,
            expected: value < 0 ? nil : UInt64(value))
    }

    @Test(arguments: fields, [1.5, Double(Int64.max)])
    func storedNonintegers(scenario: String, value: Double) throws {
        try checkStoredValue(scenario: scenario, value: value.databaseValue, expected: nil)
    }

    @Test("reaction edit baseline and immutable receipt have independent numeric bounds",arguments:["0","1","9223372036854775806","9223372036854775807","9223372036854775808","-1","1.5"])
    func reactionTypedBounds(number:String) throws {
        let command=try V2MessageReactionOperationCommand(command:.init(roomID:.init(uuid:UUID()),actorUserID:.init(uuid:UUID()),operationID:.init(uuid:UUID()),messageID:.init(uuid:UUID()),reaction:"👍",action:.add),expectedReactionRevision:1,firstSubmissionDeadlineMilliseconds:1_000)
        let encoded=String(decoding:try JSONEncoder().encode(command),as:UTF8.self)
        let data=Data(encoded.replacingOccurrences(of:"\"expectedReactionRevision\":1",with:"\"expectedReactionRevision\":"+number).utf8)
        if let n=UInt64(number),n<UInt64(Int64.max) { #expect(try JSONDecoder().decode(V2MessageReactionOperationCommand.self,from:data).expectedReactionRevision==n) }
        else { #expect(throws:(any Error).self) { _ = try JSONDecoder().decode(V2MessageReactionOperationCommand.self,from:data) } }
        let commit=Data("{\"targetState\":\"present\",\"revision\":\(number)}".utf8)
        if let n=UInt64(number),n>0,n<=UInt64(Int64.max) { #expect(try JSONDecoder().decode(V2MessageReactionCommit.self,from:commit).revision==n) }
        else { #expect(throws:(any Error).self) { _ = try JSONDecoder().decode(V2MessageReactionCommit.self,from:commit) } }
    }

    private func checkStoredValue(scenario: String, value: DatabaseValue, expected: UInt64?) throws {
        let parts = scenario.split(separator: ".").map(String.init)
        let kind = parts[0], field = parts[1]
        func decodedValue() throws -> UInt64? {
            switch kind {
            case "edit", "withdrawal":
                let numeric:String
                switch value.storage { case .int64(let number):numeric=String(number)
                case .double(let number):numeric=String(number)
                default:throw V2MessageOperationValidationError.invalidReceipt }
                let actor=UserID(uuid:UUID()),room=RoomID(uuid:UUID()),message=MessageID(uuid:UUID())
                let payload:V2MessageMutationPayload = kind=="edit"
                    ? .edit(try .init(command:.init(roomID:room,actorUserID:actor,operationID:.init(uuid:UUID()),messageID:message,expectedMessageRevision:1,text:"text",maximumUTF8Bytes:1024),firstSubmissionDeadlineMilliseconds:1000))
                    : .withdraw(try .init(command:.init(roomID:room,actorUserID:actor,operationID:.init(uuid:UUID()),messageID:message,expectedMessageRevision:1),firstSubmissionDeadlineMilliseconds:1000))
                if field=="expected_message_revision" {
                    let encoded=String(decoding:try JSONEncoder().encode(payload),as:UTF8.self)
                    let data=Data(encoded.replacingOccurrences(of:"\"expectedMessageRevision\":1",with:"\"expectedMessageRevision\":"+numeric).utf8)
                    let result=try JSONDecoder().decode(V2MessageMutationPayload.self,from:data)
                    switch result { case .edit(let command):return command.expectedMessageRevision
                    case .withdraw(let command):return command.expectedMessageRevision }
                }
                let outcome:V2MessageMutationTerminalOutcome = field=="terminal_current_revision"
                    ? .rejected(.revisionConflict(current:1))
                    : .committed(try .init(messageID:message,messageRevision:1,roomSequence:1,eventID:.init(uuid:UUID())))
                let receipt=try V2MessageMutationReceipt(identity:payload.identity,fingerprint:payload.fingerprint,outcome:outcome,resolvedAtMilliseconds:1000)
                let key=field=="resulting_message_revision" ? "messageRevision" : field=="resulting_room_sequence" ? "roomSequence" : "current"
                let encoded=String(decoding:try JSONEncoder().encode(receipt),as:UTF8.self)
                let data=Data(encoded.replacingOccurrences(of:"\""+key+"\":1",with:"\""+key+"\":"+numeric).utf8)
                let decoded=try JSONDecoder().decode(V2MessageMutationReceipt.self,from:data)
                switch decoded.outcome { case .committed(let result):return key=="roomSequence" ? result.roomSequence : result.messageRevision
                case .rejected(.revisionConflict(let revision)):return revision
                default:throw V2MessageOperationValidationError.invalidReceipt }
            case "membership":
                let numeric:String
                switch value.storage { case .int64(let n):numeric=String(n)
                case .double(let n):numeric=String(n)
                default:throw V2MembershipOperationValidationError.invalidReceipt }
                let intent=try V2MembershipIntent(roomID:.init(uuid:UUID()),actorUserID:.init(uuid:UUID()),operationID:.init(uuid:UUID()),targetUserID:.init(uuid:UUID()),action:.add,expectedMembershipRevision:1,confirmedUntilMilliseconds:1000)
                if field=="expected_membership_revision" {
                    let encoded=String(decoding:try JSONEncoder().encode(intent),as:UTF8.self)
                    let data=Data(encoded.replacingOccurrences(of:"\"expectedMembershipRevision\":1",with:"\"expectedMembershipRevision\":"+numeric).utf8)
                    return try JSONDecoder().decode(V2MembershipIntent.self,from:data).expectedMembershipRevision
                }
                let outcome:V2MembershipTerminalOutcome = field=="terminal_current_revision"
                    ? .rejected(.membershipChanged(currentRevision:1))
                    : .changed(try .init(membershipRevision:1,roomSequence:1,eventID:.init(uuid:UUID())))
                let receipt=try V2MembershipReceipt(identity:intent.identity,fingerprint:intent.fingerprint,outcome:outcome,resolvedAtMilliseconds:1000)
                let key=field=="resulting_membership_revision" ? "membershipRevision" : field=="resulting_room_sequence" ? "roomSequence" : "currentRevision"
                let encoded=String(decoding:try JSONEncoder().encode(receipt),as:UTF8.self)
                let data=Data(encoded.replacingOccurrences(of:"\""+key+"\":1",with:"\""+key+"\":"+numeric).utf8)
                switch try JSONDecoder().decode(V2MembershipReceipt.self,from:data).outcome {
                case .changed(let result):return key=="roomSequence" ? result.roomSequence : result.membershipRevision
                case .rejected(.membershipChanged(let revision)):return revision
                default:throw V2MembershipOperationValidationError.invalidReceipt
                }
            default:
                let numeric: String
                switch value.storage {
                case .int64(let value): numeric = String(value)
                case .double(let value): numeric = String(value)
                default: throw V2ReadReceiptValidationError.invalidRoomSequence
                }
                let data: Data
                if field == "read_through_room_sequence" {
                    let command = try V2RecordReadReceiptCommand(roomID:.init(uuid:UUID()),actorUserID:.init(uuid:UUID()),operationID:.init(uuid:UUID()),readThroughRoomSequence:1)
                    let encoded = String(decoding:try JSONEncoder().encode(command),as:UTF8.self)
                    data = Data(encoded.replacingOccurrences(of:"\"readThroughRoomSequence\":1",with:"\"readThroughRoomSequence\":" + numeric).utf8)
                    return try JSONDecoder().decode(V2RecordReadReceiptCommand.self,from:data).readThroughRoomSequence
                }
                let receipt = try V2ReadReceipt(roomID:.init(uuid:UUID()),userID:.init(uuid:UUID()),readThroughRoomSequence:1,recordedAt:Date())
                let encoded = String(decoding:try JSONEncoder().encode(receipt),as:UTF8.self)
                data = Data(encoded.replacingOccurrences(of:"\"readThroughRoomSequence\":1",with:"\"readThroughRoomSequence\":" + numeric).utf8)
                return try JSONDecoder().decode(V2ReadReceipt.self,from:data).readThroughRoomSequence
            }
        }
        let zeroAllowed = kind=="membership" && (field=="expected_membership_revision" || field=="terminal_current_revision")
        let maximumExcluded = kind=="membership" && field=="expected_membership_revision" && expected==UInt64(Int64.max)
        if expected == nil || (expected == 0 && !zeroAllowed) || maximumExcluded {
            #expect(throws: (any Error).self) { _ = try decodedValue() }
        } else {
            #expect(try decodedValue() == expected)
        }
    }
}

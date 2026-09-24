import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing

@Suite("Room receipt wire identities")
struct V2ActorRoomReceiptContractTests {
    @Test("record has stable room-scoped identity while readers is read-only")
    func identities() throws {
        let room = try RoomID("room-1")
        let user = try UserID("user-1")
        let operation = try ReadReceiptOperationID("receipt-1")
        let record = try V2ActorRecordReadReceiptWire(roomID: room, actorUserID: user,
            operationID: operation, readThroughRoomSequence: 9)
        let command = V2RoomReceiptCommand.record(record)
        #expect(command.roomID == room)
        #expect(command.actorUserID == user)
        #expect(command.operationID == operation)
        #expect(command.replayPolicy == .durableIdempotent)
        #expect(try JSONDecoder().decode(V2RoomReceiptCommand.self,
            from: JSONEncoder().encode(command)) == command)
        let reader = try V2ActorReadReceiptReadersQueryWire(roomID: room,
            messageID: MessageID("message-1"), actorUserID: user,
            cursor: "opaque", pageSize: 100)
        let query = V2RoomReceiptQuery.readerCandidates(reader)
        #expect(query.replayPolicy == .readOnly)
        #expect(try JSONDecoder().decode(V2RoomReceiptQuery.self,
            from: JSONEncoder().encode(query)) == query)
        #expect(throws: V2ReadReceiptValidationError.invalidRoomSequence) {
            try V2ActorRecordReadReceiptWire(roomID: room, actorUserID: user,
                operationID: operation, readThroughRoomSequence: 0)
        }
        #expect(throws: V2ActorRoomReceiptWireError.invalidRequest) {
            try V2ActorReadReceiptReadersQueryWire(roomID: room,
                messageID: MessageID("message-1"), actorUserID: user, cursor: nil, pageSize: 101)
        }
    }

    @Test("physical microbatch retains order and individual error cases")
    func batch() throws {
        let room = try RoomID("room-1")
        let user = try UserID("user-1")
        let request = try V2ActorRecordReadReceiptWire(roomID: room, actorUserID: user,
            operationID: ReadReceiptOperationID("receipt-1"), readThroughRoomSequence: 1)
        let batch = try V2ActorReadReceiptRecordBatchWire(requests: [request])
        #expect(try JSONDecoder().decode(V2ActorReadReceiptRecordBatchWire.self,
            from: JSONEncoder().encode(batch)) == batch)
        let result = V2ActorReadReceiptRecordBatchResultWire(results: [
            .failure(.ownerChanged), .failure(.roomSequenceNotFound),
            .success(.idempotencyConflict),
        ])
        #expect(try JSONDecoder().decode(V2ActorReadReceiptRecordBatchResultWire.self,
            from: JSONEncoder().encode(result)) == result)
    }
}

@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("Room receipt domain mapping")
struct V2ActorRoomReceiptMapperTests {
    @Test("record, replay, readers and batch outcomes preserve every field")
    func fullFields() throws {
        let room = try RoomID("room-1")
        let user = try UserID("user-1")
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let receipt = try V2ReadReceipt(roomID: room, userID: user,
            readThroughRoomSequence: 42, recordedAt: time)
        for outcome in [V2ReadReceiptOutcome.recorded(receipt), .idempotent(receipt),
                        .idempotencyConflict] {
            let wire = V2ActorRecordReadReceiptResultWire(outcome)
            let decoded = try JSONDecoder().decode(V2ActorRecordReadReceiptResultWire.self,
                from: JSONEncoder().encode(wire))
            #expect(try decoded.domainValue() == outcome)
        }
        let reader = V2ReadReceiptReader(userID: user)
        let page = try V2ReadReceiptReadersPage(roomID: room,
            messageID: MessageID("message-1"), readers: [reader], nextCursor: "next")
        let pageWire = V2ActorReadReceiptReadersPageWire(page)
        let encodedReader = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(pageWire.readers[0])) as? [String: Any])
        #expect(Set(encodedReader.keys) == ["userID"])
        #expect(try pageWire.domainValue() == page)
        #expect(try JSONDecoder().decode(V2ActorReadReceiptReadersPageWire.self,
            from: JSONEncoder().encode(pageWire)) == pageWire)
        let results: [V2ReadReceiptRecordResult] = [
            .success(.recorded(receipt)), .failure(.ownerChanged),
            .success(.idempotent(receipt)), .failure(.roomSequenceNotFound),
        ]
        let batch = try V2ActorReadReceiptRecordBatchResultWire(results, expectedCount: 4)
        #expect(try batch.domainValue(expectedCount: 4) == results)
        let request = try V2ActorRecordReadReceiptWire(roomID: room, actorUserID: user,
            operationID: ReadReceiptOperationID("receipt-1"), readThroughRoomSequence: 42)
        let stamped = try V2ActorReadReceiptRecordBatchWire(requests: [request]).recordRequests(now: time)
        #expect(stamped.count == 1)
        #expect(stamped[0].command.readThroughRoomSequence == 42)
        #expect(stamped[0].now == time)
    }

    @Test("duplicate reader and invalid sequence throw; profile content is a separate contract")
    func invalid() throws {
        let room = try RoomID("room-1")
        let user = try UserID("user-1")
        let valid = V2ActorReadReceiptReaderWire(userID: user)
        let duplicate = V2ActorReadReceiptReadersPageWire(roomID: room,
            messageID: try MessageID("message-1"), readers: [valid, valid], nextCursor: nil)
        #expect(throws: V2ReadReceiptValidationError.invalidReaderPage) {
            try duplicate.domainValue()
        }
        #expect(throws: (any Error).self) {
            try V2ActorReadReceiptWire(roomID: room, userID: user,
                readThroughRoomSequence: 0,
                recordedAt: Date(timeIntervalSince1970: 1_700_000_000)).domainValue()
        }
        let noncanonical = V2ActorPublicIdentityWire(userID: user, handle: "Reader_1",
            displayName: "Reader", accountKind: .regular)
        #expect(throws: V2ActorRoomDirectoryWireError.invalidIdentity) {
            try noncanonical.domainValue()
        }
    }
}

@Suite("Room receipt error mapping")
struct V2ActorRoomReceiptErrorMapperTests {
    @Test("store rejection and admission busy have different wire cases")
    func failures() throws {
        let store = V2ActorRoomReceiptFailureWire(V2ReadReceiptStoreError.ownerChanged)
        let busy = V2ActorRoomReceiptFailureWire(V2ReadReceiptBatcherError.serverBusy)
        #expect(store == .store(.ownerChanged))
        #expect(busy == .serverBusy)
        #expect(store.domainValue() == .store(.ownerChanged))
        #expect(busy.domainValue() == .serverBusy)
        for value in [V2RoomReceiptResult.recordFailure(store),
                      .recordFailure(busy), .readersFailure(.invalidRequest)] {
            #expect(try JSONDecoder().decode(V2RoomReceiptResult.self,
                from: JSONEncoder().encode(value)) == value)
        }
    }
}

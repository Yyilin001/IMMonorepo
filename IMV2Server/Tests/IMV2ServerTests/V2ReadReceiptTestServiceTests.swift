@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("Read receipt domain request construction")
struct V2ReadReceiptTestServiceTests {
    @Test("Receipt sequence bounds are checked before storage",
          arguments: [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func validatesSequenceBeforeAdmission(sequence: UInt64) async throws {
        let store = ReceiptStoreSpy()
        let service = V2ReadReceiptTestService(store: store,
            now: { Date(timeIntervalSince1970: 1_750_000_000) })
        let request = V2AuthenticatedReadReceipt(roomID: .init(uuid: UUID()), actorUserID: .init(uuid: UUID()),
            operationID: .init(uuid: UUID()), readThroughRoomSequence: sequence)
        if sequence == 0 || sequence > UInt64(Int64.max) {
            await #expect(throws: V2ReadReceiptValidationError.invalidRoomSequence) { try await service.record(request) }
            #expect(await store.command() == nil)
        } else {
            guard case .recorded(let receipt) = try await service.record(request) else { throw CancellationError() }
            #expect(receipt.readThroughRoomSequence == sequence)
            #expect(await store.command()?.readThroughRoomSequence == sequence)
        }
    }

    @Test("explicit viewing state reaches the store independently of sync acknowledgements")
    func forwardsReadReceipt() async throws {
        let store = ReceiptStoreSpy()
        let service = V2ReadReceiptTestService(store: store, now: { Date(timeIntervalSince1970: 1_750_000_000) })
        let request = V2AuthenticatedReadReceipt(roomID: try .init("00000000-0000-0000-0000-000000000971"), actorUserID: try .init("00000000-0000-0000-0000-000000000972"), operationID: try .init("00000000-0000-0000-0000-000000000973"), readThroughRoomSequence: 8)
        let expected = try V2RecordReadReceiptCommand(roomID: request.roomID, actorUserID: request.actorUserID, operationID: request.operationID, readThroughRoomSequence: 8)
        let result = try await service.record(request)
        guard case .recorded(let receipt) = result else { Issue.record("expected receipt"); return }
        #expect(await store.command() == expected)
        #expect(receipt.readThroughRoomSequence == 8)
    }
}

private actor ReceiptStoreSpy: V2ReadReceiptStore {
    private var captured: V2RecordReadReceiptCommand?
    func record(command: V2RecordReadReceiptCommand, now: Date) throws -> V2ReadReceiptOutcome {
        captured = command
        return .recorded(try .init(roomID: command.roomID, userID: command.actorUserID, readThroughRoomSequence: command.readThroughRoomSequence, recordedAt: now))
    }
    func readers(roomID _: RoomID, messageID _: MessageID, actorUserID _: UserID, cursor _: String?, pageSize _: Int) throws -> V2ReadReceiptReadersPage {
        throw V2ReadReceiptStoreError.corruptPersistenceState
    }
    func command() -> V2RecordReadReceiptCommand? { captured }
}

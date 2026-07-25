import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 read receipt service")
struct V2ReadReceiptServiceTests {
    @Test("explicit viewing state reaches the store independently of sync acknowledgements")
    func forwardsReadReceipt() async throws {
        let store = ReceiptStoreSpy()
        let service = V2ReadReceiptService(store: store, now: { Date(timeIntervalSince1970: 1_750_000_000) })
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
        return .recorded(.init(roomID: command.roomID, userID: command.actorUserID, readThroughRoomSequence: command.readThroughRoomSequence, recordedAt: now))
    }
    func command() -> V2RecordReadReceiptCommand? { captured }
}

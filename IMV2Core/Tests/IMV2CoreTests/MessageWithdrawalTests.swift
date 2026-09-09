import Foundation
import IMV2Core
import Testing

@Suite("V2 message withdrawal command")
struct MessageWithdrawalTests {
    @Test("withdrawal command preserves its durable operation and revision fence")
    func commandValue() throws {
        let command = try V2WithdrawMessageCommand(
            roomID: try .init("00000000-0000-0000-0000-000000000901"),
            actorUserID: try .init("00000000-0000-0000-0000-000000000902"),
            operationID: try .init("00000000-0000-0000-0000-000000000903"),
            messageID: try .init("00000000-0000-0000-0000-000000000904"),
            expectedMessageRevision: 1
        )
        #expect(command.expectedMessageRevision == 1)
        #expect(command.operationID.rawValue == "00000000-0000-0000-0000-000000000903")
    }
}

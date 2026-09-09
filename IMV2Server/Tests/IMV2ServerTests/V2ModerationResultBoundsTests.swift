import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

struct V2ModerationResultBoundsTests {
    @Test(arguments: ["sequence", "message", "membership"], [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func persistenceBounds(field: String, value: UInt64) throws {
        func result() throws -> V2ModerationResult {
            try .init(roomID: .init("room"), operationID: .init("operation"),
                      action: field == "membership" ? .removeMember : .redactMessage,
                      targetUserID: field == "membership" ? .init("target") : nil,
                      messageID: field == "membership" ? nil : .init("message"),
                      messageRevision: field == "message" ? value : nil,
                      membershipRevision: field == "membership" ? value : nil,
                      muteUntil: nil, roomSequence: field == "sequence" ? value : 1,
                      eventID: .init("event"), fanoutPlanID: .init("plan"), createdAt: .distantPast)
        }
        if value == 0 || value > UInt64(Int64.max) {
            #expect(throws: V2RevisionValidationError.outOfRange) { _ = try result() }
        } else {
            let actual = try result()
            #expect(actual.roomSequence == (field == "sequence" ? value : 1))
            #expect(actual.messageRevision == (field == "message" ? value : nil))
            #expect(actual.membershipRevision == (field == "membership" ? value : nil))
        }
    }
}

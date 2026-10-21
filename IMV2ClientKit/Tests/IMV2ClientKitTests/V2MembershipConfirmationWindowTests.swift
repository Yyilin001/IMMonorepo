import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Membership click confirmation")
struct V2MembershipConfirmationWindowTests {
    @Test("target lookup consumes the original confirmation window")
    func lookupCannotRenew() throws {
        let activation=UUID(),start=ContinuousClock.now
        let click=try V2MembershipConfirmationWindow(roomID:.init(uuid:UUID()),action:.add,expectedMembershipRevision:0,activationID:activation,wallNow:Date(timeIntervalSince1970:1000),monotonicNow:start)
        #expect(click.confirmedUntilMilliseconds==1_115_000)
        #expect(click.validates(activationID:activation,now:start.advanced(by:.seconds(110))))
        #expect(!click.validates(activationID:activation,now:start.advanced(by:.seconds(115))))
        #expect(!click.validates(activationID:UUID(),now:start))
        let copied=click
        #expect(copied.operationID==click.operationID)
        #expect(copied.deadline==click.deadline)
    }
    @Test("different user confirmations and actions remain separate identities")
    func noActionCoalescing() throws {
        let room=RoomID(uuid:UUID()),activation=UUID()
        let add=try V2MembershipConfirmationWindow(roomID:room,action:.add,expectedMembershipRevision:0,activationID:activation)
        let remove=try V2MembershipConfirmationWindow(roomID:room,action:.remove,expectedMembershipRevision:0,activationID:activation)
        #expect(add.operationID != remove.operationID)
        #expect(add.action != remove.action)
    }
}

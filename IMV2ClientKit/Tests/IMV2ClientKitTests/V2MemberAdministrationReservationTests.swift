import Foundation
import Testing
import IMV2Core
@testable import IMV2ClientKit

@Suite("Member administration reservation")
struct V2MemberAdministrationReservationTests {
    @Test("freeze transfers the exact full-quota reservation without double counting")
    func reservation() async throws {
        let f=try AdministrationFixture();defer { f.remove() }
        let now=Date()
        let intent=try V2MemberAdministrationIntent(roomID:f.room,actorUserID:f.account,operationID:.init(uuid:UUID()),targetUserID:f.target,action:.remove,reasonCode:.init("ADMIN_ACTION"),expectedMembershipRevision:0,confirmedUntilMilliseconds:UInt64((now.timeIntervalSince1970+120)*1000))
        let id=try await f.store.enqueueMemberAdministration(intent,activationID:UUID(),now:now,limits:.init(maximumActiveCount:1,maximumPayloadBytes:73728))
        await #expect(throws:V2OperationWorkError.capacityExceeded) {
            let second=try V2MemberAdministrationIntent(roomID:f.room,actorUserID:f.account,operationID:.init(uuid:UUID()),targetUserID:.init(uuid:UUID()),action:.remove,reasonCode:.init("ADMIN_ACTION"),expectedMembershipRevision:0,confirmedUntilMilliseconds:intent.confirmedUntilMilliseconds)
            _ = try await f.store.enqueueMemberAdministration(second,activationID:UUID(),now:now,limits:.init(maximumActiveCount:1,maximumPayloadBytes:73728))
        }
        if case .admitted(let admission)=try await f.remote.admit(intent) {
            #expect(try await f.store.freezeMemberAdministration(id:id,admission:admission,limits:.init(maximumActiveCount:1,maximumPayloadBytes:73728)) != nil)
        }
        #expect(try await f.store.memberAdministrationPending(id:id).work != nil)
        try await f.store.close()
    }
}

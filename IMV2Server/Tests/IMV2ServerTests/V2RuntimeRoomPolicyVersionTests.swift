import Foundation
import Testing
@testable import IMV2ServerInfrastructure

struct V2RuntimeRoomPolicyVersionTests {
    @Test("restored policy facts still invalidate room projection state after a version change")
    func restoredFactsRetainChangedVersion() throws {
        let sender = UUID(), recipient = UUID()
        let accounts = try [sender, recipient].map { user in
            try V2PolicyFactsSnapshot(scope: .account(user), version: 1,
                facts: .account(.init(userID: user, isActive: true, specialKind: nil,
                    specialStatus: nil, allowsServiceMessages: nil, allowsCustomerMessages: nil)))
        }
        let before = try V2PolicyFactsSnapshot(scope: .pair(sender, recipient), version: 1,
            facts: .pair(.init(blocked: false, isFriend: true)))
        let restored = try V2PolicyFactsSnapshot(scope: .pair(sender, recipient), version: 3,
            facts: .pair(.init(blocked: false, isFriend: true)))
        let initial = try #require(V2CurrentRoomPolicySnapshot.direct(pair: .init(sender: sender, recipient: recipient),
            snapshots: accounts + [before]).policy)
        let current = try #require(V2CurrentRoomPolicySnapshot.direct(pair: .init(sender: sender, recipient: recipient),
            snapshots: accounts + [restored]).policy)
        #expect(initial.sender == current.sender && initial.recipient == current.recipient)
        #expect(initial.isFriend == current.isFriend && initial.blocked == current.blocked)
        #expect(initial != current)
    }
}

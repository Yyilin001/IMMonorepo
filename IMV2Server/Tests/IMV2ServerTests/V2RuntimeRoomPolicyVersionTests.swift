import Foundation
import Testing
import IMV2ServerApplication
@testable import IMV2ServerInfrastructure

struct V2RuntimeRoomPolicyVersionTests {
    @Test("only confirmed ordinary conversations may omit stranger facts", arguments: [false, true], [false, true])
    func replyDependency(confirmed: Bool, special: Bool) throws {
        let sender = UUID(), recipient = UUID(), pair = V2DirectSendControlPair(sender: sender, recipient: recipient)
        let accounts = try [sender, recipient].map { user in
            try V2PolicyFactsSnapshot(scope: .account(user), version: 1,
                facts: .account(.init(userID: user, isActive: true,
                    specialKind: special && user == recipient ? "customer_support" : nil,
                    specialStatus: special && user == recipient ? "active" : nil,
                    allowsServiceMessages: nil, allowsCustomerMessages: nil)))
        }
        let social = try V2PolicyFactsSnapshot(scope: .pair(sender, recipient), version: 1,
            facts: .pair(.init(blocked: true, isFriend: false)))
        if confirmed && !special {
            let policy = try #require(V2CurrentRoomPolicySnapshot.direct(pair: pair, snapshots: accounts + [social],
                recipientReplyConfirmed: confirmed).policy)
            #expect(policy.blocked)
            #expect(!policy.isFriend && !policy.allowsStrangers)
            #expect(policy.stateVersions?.count == 3)
        } else {
            #expect(throws: V2PolicyAuthorizationLifecycleError.invalidRequest) {
                _ = try V2CurrentRoomPolicySnapshot.direct(pair: pair, snapshots: accounts + [social],
                    recipientReplyConfirmed: confirmed)
            }
        }
    }

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

import Foundation
import IMV2ServerApplication

enum V2RegisteredRoomPolicySnapshot: Sendable {
    case direct(V2RegisteredDirectPolicySnapshot)
    case account(V2RegisteredAccountPolicySnapshot)
    var holder: V2PolicyAuthorizationHolder {
        switch self { case .direct(let value): value.holder; case .account(let value): value.holder }
    }
    var versions: V2RoomPolicyAuthorizationGate.Versions {
        switch self { case .direct(let value): value.versions; case .account(let value): value.versions }
    }
    var deadline: ContinuousClock.Instant {
        switch self { case .direct(let value): value.deadline; case .account(let value): value.deadline }
    }
    var policy: V2DirectSendControlPolicy? { if case .direct(let value) = self { return value.policy }; return nil }
    var account: V2PolicyAccountFacts? { if case .account(let value) = self { return value.account }; return nil }
    var senderID: UUID { switch self { case .direct(let value): value.policy.sender.userID; case .account(let value): value.account.userID } }
    var recipientID: UUID? { policy?.recipient.userID }
    var roomKind: String { if case .direct = self { return "direct" }; return "group" }
    func gatePolicy() throws -> V2RoomPolicyAuthorizationGate.Policy {
        switch self {
        case .account(let value): return try value.gatePolicy()
        case .direct(let value):
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return .init(versions: value.versions, senderActive: value.policy.sender.isActive,
                recipientActive: value.policy.recipient.isActive, blocked: value.policy.blocked,
                friend: value.policy.isFriend, allowsStrangers: value.policy.allowsStrangers,
                senderFacts: try encoder.encode(value.policy.sender), recipientFacts: try encoder.encode(value.policy.recipient))
        }
    }
}

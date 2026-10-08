import Foundation
import IMV2ServerApplication

/// Facts sampled from the owning scopes' current committed state. It has
/// no durable room registration and is never cached by a room direction.
/// Its deadline bounds this send attempt, not the lifetime of permission facts.
/// The writer combines these facts with locked room-local reply/membership
/// state and persists the final business result in the message transaction.
enum V2CurrentRoomPolicySnapshot: Sendable {
    case direct(V2DirectSendControlPolicy, deadline: ContinuousClock.Instant)
    case account(V2PolicyAccountFacts, deadline: ContinuousClock.Instant)

    static func direct(pair: V2DirectSendControlPair, snapshots: [V2PolicyFactsSnapshot], recipientReplyConfirmed: Bool = false) throws -> Self {
        guard pair.sender != pair.recipient, (3...4).contains(snapshots.count),
              Set(snapshots.map { $0.scope.key }).count == snapshots.count,
              let sender = snapshots.first(where: { $0.scope == .account(pair.sender) }),
              let recipient = snapshots.first(where: { $0.scope == .account(pair.recipient) }),
              let relationship = snapshots.first(where: { $0.scope.key == V2PolicyAuthorizationScope.pair(pair.sender, pair.recipient).key }),
              case .account(let from) = sender.facts, case .account(let to) = recipient.facts,
              case .pair(let social) = relationship.facts else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        let allowsStrangers: Bool
        if social.isFriend {
            guard snapshots.count == 3 else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
            allowsStrangers = false
        } else if recipientReplyConfirmed, from.specialKind == nil, to.specialKind == nil {
            guard snapshots.count == 3 else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
            // The ordinary-room reply fact authorizes this conversation. Keep
            // the irrelevant stranger value restrictive, never fabricate allow.
            allowsStrangers = false
        } else {
            guard snapshots.count == 4, let stranger = snapshots.first(where: { $0.scope == .stranger(pair.recipient) }),
                  case .stranger(let settings) = stranger.facts else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
            allowsStrangers = settings.allowsStrangers
        }
        var policy = V2DirectSendControlPolicy(sender: from.controlAccount, recipient: to.controlAccount,
            blocked: social.blocked, isFriend: social.isFriend, allowsStrangers: allowsStrangers)
        policy.stateVersions = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.scope.key, $0.version) })
        return .direct(policy, deadline: V2RoomSQLDeadline.boundedTransactionDeadline())
    }
    static func account(sender: UUID, snapshots: [V2PolicyFactsSnapshot]) throws -> Self {
        guard snapshots.count == 1, snapshots[0].scope == .account(sender),
              case .account(let account) = snapshots[0].facts else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        return .account(account, deadline: V2RoomSQLDeadline.boundedTransactionDeadline())
    }

    static func direct(pair: V2DirectSendControlPair, states: [V2PolicyOwnerState]) throws -> Self {
        guard pair.sender != pair.recipient, (3...4).contains(states.count),
              Set(states.map { $0.owner.scope.key }).count == states.count,
              states.allSatisfy({ $0.deadline > .now && $0.owner.revision > 0 }),
              let sender = states.first(where: { $0.owner.scope == .account(pair.sender) }),
              let recipient = states.first(where: { $0.owner.scope == .account(pair.recipient) }),
              let relationship = states.first(where: { $0.owner.scope.key == V2PolicyAuthorizationScope.pair(pair.sender, pair.recipient).key }),
              case .account(let from) = sender.facts, from.userID == pair.sender,
              case .account(let to) = recipient.facts, to.userID == pair.recipient,
              case .pair(let social) = relationship.facts else {
            throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
        let allowsStrangers: Bool
        if social.isFriend {
            guard states.count == 3 else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
            allowsStrangers = false
        } else {
            guard states.count == 4,
                  let state = states.first(where: { $0.owner.scope == .stranger(pair.recipient) }),
                  case .stranger(let settings) = state.facts, settings.userID == pair.recipient else {
                throw V2PolicyAuthorizationLifecycleError.invalidRequest
            }
            allowsStrangers = settings.allowsStrangers
        }
        return .direct(.init(sender: from.controlAccount, recipient: to.controlAccount,
            blocked: social.blocked, isFriend: social.isFriend, allowsStrangers: allowsStrangers),
            deadline: states.map(\.deadline).min()!)
    }

    static func account(sender: UUID, states: [V2PolicyOwnerState]) throws -> Self {
        guard states.count == 1, let state = states.first,
              state.owner.scope == .account(sender), state.owner.revision > 0, state.deadline > .now,
              case .account(let account) = state.facts, account.userID == sender else {
            throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
        return .account(account, deadline: state.deadline)
    }

    var deadline: ContinuousClock.Instant {
        switch self { case .direct(_, let deadline), .account(_, let deadline): deadline }
    }
    var senderID: UUID {
        switch self { case .direct(let value, _): value.sender.userID; case .account(let value, _): value.userID }
    }
    var recipientID: UUID? { policy?.recipient.userID }
    var policy: V2DirectSendControlPolicy? { if case .direct(let value, _) = self { return value }; return nil }
    var account: V2PolicyAccountFacts? { if case .account(let value, _) = self { return value }; return nil }
    var roomKind: String { if case .direct = self { return "direct" }; return "group" }
}

enum V2RoomPolicySnapshot: Sendable {
    case registered(V2RegisteredRoomPolicySnapshot)
    case current(V2CurrentRoomPolicySnapshot)

    var deadline: ContinuousClock.Instant {
        switch self { case .registered(let value): value.deadline; case .current(let value): value.deadline }
    }
    var policy: V2DirectSendControlPolicy? {
        switch self { case .registered(let value): value.policy; case .current(let value): value.policy }
    }
    var account: V2PolicyAccountFacts? {
        switch self { case .registered(let value): value.account; case .current(let value): value.account }
    }
    var roomKind: String {
        switch self { case .registered(let value): value.roomKind; case .current(let value): value.roomKind }
    }
}

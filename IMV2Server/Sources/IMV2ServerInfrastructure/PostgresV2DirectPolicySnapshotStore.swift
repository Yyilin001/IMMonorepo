import Foundation
import FluentKit
import IMV2ServerApplication
import SQLKit

/// Complete control policy, including special-account rules. Room-local facts
/// remain the room owner's responsibility.
struct V2RegisteredDirectPolicySnapshot: Sendable {
    let policy: V2DirectSendControlPolicy
    let holder: V2PolicyAuthorizationHolder
    let versions: V2RoomPolicyAuthorizationGate.Versions
    let deadline: ContinuousClock.Instant
}

struct PostgresV2DirectPolicySnapshotStore: Sendable {
    private let journal: PostgresV2PolicyAuthorizationJournal
    private let reader: V2DirectSendControlPolicyFence

    init(database: any Database, schema: String = "im_v2") {
        journal = .init(database: database, schema: schema)
        reader = .init(database: database, schema: schema)
    }

    func register(pair: V2DirectSendControlPair, owners: [V2PolicyOwnerLease], registrationID: UUID,
                  roomID: UUID, activationID: UUID, roomOwnerEpoch: Int64,
                  endpoint: String, durationSeconds: Double) async throws -> V2RegisteredDirectPolicySnapshot {
        guard pair.sender != pair.recipient, owners.count == 4,
              let sender = owners.first(where: { $0.scope.key == V2PolicyAuthorizationScope.account(pair.sender).key }),
              let recipient = owners.first(where: { $0.scope.key == V2PolicyAuthorizationScope.account(pair.recipient).key }),
              let stranger = owners.first(where: { $0.scope == .stranger(pair.recipient) }),
              let relationship = owners.first(where: { $0.scope.key == V2PolicyAuthorizationScope.pair(pair.sender, pair.recipient).key })
        else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        return try await journal.registerSnapshot(owners: owners, registrationID: registrationID,
            roomID: roomID, activationID: activationID, roomOwnerEpoch: roomOwnerEpoch,
            endpoint: endpoint, durationSeconds: durationSeconds) { transaction, holder in
                let policies = try await reader.readLockedPolicies(pairs: [pair], transaction: transaction)
                guard let policy = policies[pair] else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                guard let sql = transaction as? any SQLDatabase else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                // Start before sampling database time. Network/commit delay
                // consumes this conservative deadline instead of extending it.
                let sampled = ContinuousClock.now
                guard let clock = try await sql.raw("SELECT clock_timestamp() AS value").first(decoding: Clock.self) else {
                    throw V2PolicyAuthorizationLifecycleError.corruptPersistence
                }
                let remaining = holder.validUntil.timeIntervalSince(clock.value)
                guard remaining > 0 else { throw V2PolicyAuthorizationLifecycleError.staleVersion }
                return .init(policy: policy, holder: holder,
                    versions: .init(sender: sender.revision, recipient: recipient.revision, pair: relationship.revision,
                        stranger: stranger.revision),
                    deadline: sampled + .seconds(remaining))
            }
    }
    /// The scope facts came from their owners' revision-fenced memory. The
    /// registration transaction validates every revision before minting a lease.
    func register(pair: V2DirectSendControlPair, states: [V2PolicyOwnerState], registrationID: UUID,
                  roomID: UUID, activationID: UUID, roomOwnerEpoch: Int64,
                  endpoint: String, durationSeconds: Double) async throws -> V2RegisteredDirectPolicySnapshot {
        guard pair.sender != pair.recipient, (states.count == 3 || states.count == 4),
              Set(states.map { $0.owner.scope.key }).count == states.count,
              states.allSatisfy({ $0.deadline > .now }),
              let sender = states.first(where: { $0.owner.scope.key == V2PolicyAuthorizationScope.account(pair.sender).key }),
              let recipient = states.first(where: { $0.owner.scope.key == V2PolicyAuthorizationScope.account(pair.recipient).key }),
              let relationship = states.first(where: { $0.owner.scope.key == V2PolicyAuthorizationScope.pair(pair.sender, pair.recipient).key }),
              case .account(let from) = sender.facts, from.userID == pair.sender,
              case .account(let to) = recipient.facts, to.userID == pair.recipient,
              case .pair(let social) = relationship.facts else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        let stranger = states.first(where: { $0.owner.scope == .stranger(pair.recipient) })
        let allowsStrangers: Bool
        let dependencies: [V2PolicyOwnerLease]
        if social.isFriend {
            guard states.count == 3 else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
            allowsStrangers = false // This permission does not depend on that setting.
            dependencies = [sender.owner, recipient.owner, relationship.owner]
        } else {
            guard states.count == 4, let stranger, case .stranger(let settings) = stranger.facts,
                  settings.userID == pair.recipient else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
            allowsStrangers = settings.allowsStrangers
            dependencies = states.map(\.owner)
        }
        let policy = V2DirectSendControlPolicy(sender: from.controlAccount, recipient: to.controlAccount,
            blocked: social.blocked, isFriend: social.isFriend, allowsStrangers: allowsStrangers)
        return try await journal.registerSnapshot(owners: dependencies, registrationID: registrationID,
            roomID: roomID, activationID: activationID, roomOwnerEpoch: roomOwnerEpoch,
            endpoint: endpoint, durationSeconds: durationSeconds) { transaction, holder in
                guard let sql = transaction as? any SQLDatabase else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                let sampled = ContinuousClock.now
                guard let clock = try await sql.raw("SELECT clock_timestamp() AS value").first(decoding: Clock.self) else {
                    throw V2PolicyAuthorizationLifecycleError.corruptPersistence
                }
                let remaining = holder.validUntil.timeIntervalSince(clock.value)
                guard remaining > 0 else { throw V2PolicyAuthorizationLifecycleError.staleVersion }
                return .init(policy: policy, holder: holder,
                    versions: .init(sender: sender.owner.revision, recipient: recipient.owner.revision, pair: relationship.owner.revision, stranger: social.isFriend ? nil : stranger?.owner.revision),
                    deadline: sampled + .seconds(remaining))
            }
    }
    private struct Clock: Decodable { let value: Date }
}

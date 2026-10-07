import Foundation
import FluentKit
import IMV2ServerApplication
import SQLKit

/// One sending account dependency for group messages. The room transaction
/// owns membership, mute and role checks; no recipient/pair state is invented.
struct V2RegisteredAccountPolicySnapshot: Sendable {
    let account: V2PolicyAccountFacts
    let holder: V2PolicyAuthorizationHolder
    let versions: V2RoomPolicyAuthorizationGate.Versions
    let deadline: ContinuousClock.Instant

    func gatePolicy() throws -> V2RoomPolicyAuthorizationGate.Policy {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return .init(accountVersion: holderPolicyRevision, senderActive: account.isActive,
            senderFacts: try encoder.encode(account))
    }

    private let holderPolicyRevision: Int64
    init(account: V2PolicyAccountFacts, holder: V2PolicyAuthorizationHolder,
         revision: Int64, deadline: ContinuousClock.Instant) {
        self.account = account; self.holder = holder; self.holderPolicyRevision = revision
        self.versions = .init(accountSender: revision); self.deadline = deadline
    }
}

struct PostgresV2AccountPolicySnapshotStore: Sendable {
    private let journal: PostgresV2PolicyAuthorizationJournal
    init(database: any Database, schema: String = "im_v2") {
        journal = .init(database: database, schema: schema)
    }

    func register(sender: UUID, state: V2PolicyOwnerState, registrationID: UUID,
        roomID: UUID, activationID: UUID, roomOwnerEpoch: Int64,
        endpoint: String, durationSeconds: Double) async throws -> V2RegisteredAccountPolicySnapshot {
        guard state.owner.scope == .account(sender), state.deadline > .now,
              case .account(let account) = state.facts, account.userID == sender else {
            throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
        return try await journal.registerSnapshot(owners: [state.owner], registrationID: registrationID,
            roomID: roomID, activationID: activationID, roomOwnerEpoch: roomOwnerEpoch,
            endpoint: endpoint, durationSeconds: durationSeconds) { transaction, holder in
                guard let sql = transaction as? any SQLDatabase else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                let sampled = ContinuousClock.now
                guard let clock = try await sql.raw("SELECT clock_timestamp() AS value").first(decoding: Clock.self) else {
                    throw V2PolicyAuthorizationLifecycleError.corruptPersistence
                }
                let remaining = holder.validUntil.timeIntervalSince(clock.value)
                let deadline = min(state.deadline, sampled + .seconds(remaining))
                guard remaining > 0, deadline > .now else { throw V2PolicyAuthorizationLifecycleError.staleVersion }
                return .init(account: account, holder: holder, revision: state.owner.revision, deadline: deadline)
            }
    }
    private struct Clock: Decodable { let value: Date }
}

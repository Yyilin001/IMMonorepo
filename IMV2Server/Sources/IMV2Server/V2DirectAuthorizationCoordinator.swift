import Fluent
import Foundation

enum V2DirectAuthorizationCoordinationError: Error, Equatable, Sendable {
    case ownerUnavailable, revocationIncomplete, invalidLimit
}

public struct V2DirectAuthorizationRecoveryResult: Equatable, Sendable {
    public let claimed: Int
    public let resolved: Int
    public let deferred: Int
}

/// Durable owner abort/proof followed by control acknowledgement. The control
/// pool must be independent of policy-writer AND grant-reservation pools, even
/// when colocated: reservations may occupy connections while waiting for the
/// policy lock held by a writer that needs to acknowledge owner proofs.
/// Policy writers call drain before mutation. Runtime composition and recovery
/// lifecycle registration are still required.
public struct V2DirectAuthorizationCoordinator: Sendable {
    private let intents: PostgresV2DirectAuthorizationIntentStore
    private let ownerAbort: @Sendable (V2DirectAuthorizationAttempt, Date) async throws -> V2DirectAuthorizationReceipt

    public init(controlDatabase: any Database, ownerDatabases: [String: any Database]) {
        self.intents = .init(database: controlDatabase)
        self.ownerAbort = { attempt, now in
            guard let database = ownerDatabases[attempt.ownerShardID] else {
                throw V2DirectAuthorizationCoordinationError.ownerUnavailable
            }
            return try await PostgresV2DirectAuthorizationReceiptStore().abort(attempt, now: now, database: database)
        }
    }

    init(intents: PostgresV2DirectAuthorizationIntentStore,
         ownerAbort: @escaping @Sendable (V2DirectAuthorizationAttempt, Date) async throws -> V2DirectAuthorizationReceipt) {
        self.intents = intents; self.ownerAbort = ownerAbort
    }

    /// Call under the policy's exclusive control lock, before changing policy.
    /// Every proof is acknowledged on an independent control connection so a
    /// rollback/unavailable owner cannot erase already completed drain progress.
    /// Large queues make bounded progress and require a retry, never fake success.
    func drain(_ scope: V2DirectAuthorizationRevocationScope, transaction: any Database, now: Date, limit: Int = 128) async throws {
        guard (1...128).contains(limit) else { throw V2DirectAuthorizationCoordinationError.invalidLimit }
        try Task.checkCancellation()
        let pending = try await intents.held(in: scope, limit: limit, transaction: transaction)
        for grant in pending {
            try Task.checkCancellation()
            let receipt = try await ownerAbort(grant.attempt, now)
            guard try await intents.resolve(grant.attempt, receipt: receipt, now: now) else {
                throw V2DirectAuthorizationCoordinationError.revocationIncomplete
            }
        }
        guard try await intents.held(in: scope, limit: 1, transaction: transaction).isEmpty else {
            throw V2DirectAuthorizationCoordinationError.revocationIncomplete
        }
    }

    /// A due job may cancel its exact generation, including one whose original
    /// caller is still running: the owner lock/tombstone makes that cancellation
    /// durable. An unavailable owner only defers the job; it never frees a grant.
    public func recover(limit: Int, now: Date) async throws -> V2DirectAuthorizationRecoveryResult {
        try Task.checkCancellation()
        let claimed = try await intents.claim(limit: limit, now: now)
        var resolved = 0, deferred = 0
        for grant in claimed {
            do {
                try Task.checkCancellation()
                let receipt = try await ownerAbort(grant.attempt, now)
                if try await intents.resolve(grant.attempt, receipt: receipt, now: now) { resolved += 1 }
            } catch {
                try await intents.deferClaim(grant, now: now)
                if error is CancellationError { throw error }
                deferred += 1
            }
        }
        return .init(claimed: claimed.count, resolved: resolved, deferred: deferred)
    }
}

/// Policy writers must fail closed even if composition omitted the coordinator.
/// The caller holds the corresponding account/pair/preference exclusive lock.
func v2DrainDirectAuthorizations(_ scope: V2DirectAuthorizationRevocationScope,
    coordinator: V2DirectAuthorizationCoordinator?, transaction: any Database, now: Date) async throws {
    if let coordinator {
        try await coordinator.drain(scope, transaction: transaction, now: now)
    } else {
        let pending = try await PostgresV2DirectAuthorizationIntentStore(database: transaction)
            .held(in: scope, limit: 1, transaction: transaction)
        guard pending.isEmpty else { throw V2DirectAuthorizationCoordinationError.ownerUnavailable }
    }
}

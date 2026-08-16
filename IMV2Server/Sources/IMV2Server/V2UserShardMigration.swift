import Foundation
import IMV2Core

/// The durable control record for a user-shard move. Physical copy mechanics
/// are injected elsewhere; this state machine prevents a route cutover from
/// being mistaken for proof that the target data was copied and verified.
public enum V2UserShardMigrationPhase: String, Codable, Equatable, Sendable {
    case prepared, copying, copied, verifying, forwarding, verified, cutover, retention, completed, rolledBack = "rolled_back", failed
}

public enum V2UserShardMigrationAction: Equatable, Sendable {
    case beginCopy, copySucceeded, beginVerification, verificationSucceeded, forwardingVerificationSucceeded
    case cutOver, beginRetention, complete, rollback, fail
}

public enum V2UserShardMigrationError: Error, Equatable, Sendable { case invalidTransition }

public struct V2UserShardMigrationStateMachine: Sendable {
    public static func transition(from phase: V2UserShardMigrationPhase, by action: V2UserShardMigrationAction) throws -> V2UserShardMigrationPhase {
        switch (phase, action) {
        case (.prepared, .beginCopy), (.failed, .beginCopy): return .copying
        case (.copying, .copySucceeded): return .copied
        case (.copied, .beginVerification), (.failed, .beginVerification): return .verifying
        case (.verifying, .verificationSucceeded): return .forwarding
        case (.forwarding, .forwardingVerificationSucceeded): return .verified
        case (.verified, .cutOver): return .cutover
        case (.cutover, .beginRetention): return .retention
        case (.retention, .complete): return .completed
        // Rollback is deliberately unavailable after cleanup/complete.
        case (.cutover, .rollback), (.retention, .rollback): return .rolledBack
        case (.prepared, .fail), (.copying, .fail), (.copied, .fail), (.verifying, .fail), (.forwarding, .fail), (.verified, .fail): return .failed
        default: throw V2UserShardMigrationError.invalidTransition
        }
    }
}

public struct V2UserShardMigrationRecord: Equatable, Sendable {
    public let migrationID: UUID
    public let userID: UserID
    public let sourceBucket: String
    public let targetBucket: String
    public let sourceRouterEpoch: Int64
    public let phase: V2UserShardMigrationPhase
    public let sourceFingerprint: String?
    public let targetFingerprint: String?
    public let verifiedAt: Date?
    public let lastErrorCode: V2UserShardMigrationFailureCode?
    public let cutoverOperationID: UUID?
    public let retentionUntil: Date?

    public init(
        migrationID: UUID,
        userID: UserID,
        sourceBucket: String,
        targetBucket: String,
        sourceRouterEpoch: Int64,
        phase: V2UserShardMigrationPhase,
        sourceFingerprint: String?,
        targetFingerprint: String?,
        verifiedAt: Date? = nil,
        lastErrorCode: V2UserShardMigrationFailureCode? = nil,
        cutoverOperationID: UUID? = nil,
        retentionUntil: Date? = nil
    ) {
        self.migrationID = migrationID
        self.userID = userID
        self.sourceBucket = sourceBucket
        self.targetBucket = targetBucket
        self.sourceRouterEpoch = sourceRouterEpoch
        self.phase = phase
        self.sourceFingerprint = sourceFingerprint
        self.targetFingerprint = targetFingerprint
        self.verifiedAt = verifiedAt
        self.lastErrorCode = lastErrorCode
        self.cutoverOperationID = cutoverOperationID
        self.retentionUntil = retentionUntil
    }
}

/// Stable, non-sensitive failure categories. Never persist an adapter error
/// string: cross-store providers may include host names, identifiers or other
/// operational data that does not belong in a durable control record.
public enum V2UserShardMigrationFailureCode: String, Codable, Equatable, Sendable {
    case copyFailed = "copy_failed"
    case verificationFailed = "verification_failed"
    case fingerprintMismatch = "fingerprint_mismatch"
}

public struct V2UserShardMigrationPreparation: Sendable {
    public let migrationID: UUID
    public let userID: UserID
    public let sourceBucket: String
    public let targetBucket: String
    public let sourceRouterEpoch: Int64

    public init(migrationID: UUID, userID: UserID, sourceBucket: String, targetBucket: String, sourceRouterEpoch: Int64) throws {
        let route = try V2UserShardRoute(bucket: targetBucket, observedRouterEpoch: sourceRouterEpoch)
        let source = sourceBucket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, source != route.bucket else { throw V2UserShardMigrationStoreError.invalidPreparation }
        self.migrationID = migrationID
        self.userID = userID
        self.sourceBucket = source
        self.targetBucket = route.bucket
        self.sourceRouterEpoch = sourceRouterEpoch
    }
}

public enum V2UserShardMigrationStoreError: Error, Equatable, Sendable {
    case invalidPreparation
    case recordNotFound
    case requestConflict
    case phaseConflict
    case invalidFingerprint
}

/// This persistence boundary owns phase fencing. Copying and verification are
/// deliberately performed outside its transaction, then committed only when
/// the expected prior phase is still current.
public protocol V2UserShardMigrationStoring: Sendable {
    func prepare(_ request: V2UserShardMigrationPreparation, now: Date) async throws -> V2UserShardMigrationRecord
    func load(migrationID: UUID) async throws -> V2UserShardMigrationRecord?
    func load(userID: UserID) async throws -> V2UserShardMigrationRecord?
    func advance(
        migrationID: UUID,
        expectedPhase: V2UserShardMigrationPhase,
        action: V2UserShardMigrationAction,
        fingerprints: (source: String, target: String)?,
        now: Date
    ) async throws -> V2UserShardMigrationRecord
    func fail(
        migrationID: UUID,
        expectedPhase: V2UserShardMigrationPhase,
        code: V2UserShardMigrationFailureCode,
        now: Date
    ) async throws -> V2UserShardMigrationRecord
}

public struct V2UserShardMigrationRetentionLease: Equatable, Sendable {
    public let record: V2UserShardMigrationRecord
    public let claimToken: UUID

    public init(record: V2UserShardMigrationRecord, claimToken: UUID) {
        precondition(record.phase == .retention)
        self.record = record
        self.claimToken = claimToken
    }
}

/// Source deletion is external I/O. It receives a short durable lease rather
/// than running while the migration-control database transaction is open.
public protocol V2UserShardMigrationRetentionStoring: Sendable {
    func claimExpiredRetention(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2UserShardMigrationRetentionLease]
    func completeRetention(_ lease: V2UserShardMigrationRetentionLease, now: Date) async throws -> Bool
}

public protocol V2UserShardMigrationRetentionCleaning: Sendable {
    /// Must be idempotent for a migration ID. The row has already passed copy,
    /// verification and the configured rollback retention window.
    func cleanSource(for record: V2UserShardMigrationRecord) async throws
}

public struct V2UserShardMigrationRetentionReport: Equatable, Sendable {
    public let claimedCount: Int
    public let completedCount: Int
    public let failedCount: Int
}

public struct V2UserShardMigrationRetentionWorker: Sendable {
    private let store: any V2UserShardMigrationRetentionStoring
    private let cleaner: any V2UserShardMigrationRetentionCleaning
    private let leaseDuration: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        store: any V2UserShardMigrationRetentionStoring,
        cleaner: any V2UserShardMigrationRetentionCleaning,
        leaseDuration: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(leaseDuration > 0)
        self.store = store
        self.cleaner = cleaner
        self.leaseDuration = leaseDuration
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2UserShardMigrationRetentionReport {
        precondition(limit > 0)
        let leases = try await store.claimExpiredRetention(now: now(), leaseDuration: leaseDuration, limit: limit)
        var completed = 0
        var failed = 0
        for lease in leases {
            do {
                try await cleaner.cleanSource(for: lease.record)
                if try await store.completeRetention(lease, now: now()) { completed += 1 }
            } catch {
                // Retain the claim through expiry to avoid a hot destructive
                // retry loop. A later worker can reclaim it with a new token.
                failed += 1
            }
        }
        return .init(claimedCount: leases.count, completedCount: completed, failedCount: failed)
    }
}

/// Copy and verification are deliberately separate dependency boundaries. A
/// real cross-store adapter may stream/checkpoint data; tests can inject a
/// deterministic fingerprint provider without a network or a second cluster.
public protocol V2UserShardMigrationCopying: Sendable {
    func copy(_ record: V2UserShardMigrationRecord) async throws
}

public protocol V2UserShardMigrationVerifying: Sendable {
    func fingerprints(for record: V2UserShardMigrationRecord) async throws -> (source: String, target: String)
}

public enum V2UserShardMigrationVerificationError: Error, Equatable, Sendable { case fingerprintMismatch }

/// Durable orchestration for a single migration attempt. It never holds a
/// PostgreSQL transaction while a cross-store adapter is doing network I/O;
/// every continuation is fenced by the persisted phase instead.
public struct V2DurableUserShardMigrationCoordinator: Sendable {
    private let store: any V2UserShardMigrationStoring
    private let copier: any V2UserShardMigrationCopying
    private let verifier: any V2UserShardMigrationVerifying
    private let now: @Sendable () -> Date

    public init(
        store: any V2UserShardMigrationStoring,
        copier: any V2UserShardMigrationCopying,
        verifier: any V2UserShardMigrationVerifying,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.copier = copier
        self.verifier = verifier
        self.now = now
    }

    /// Returns a durably `verified` record. A process loss after any external
    /// call leaves an observable nonterminal phase for an operator-approved,
    /// idempotent adapter retry rather than silently cutting over the route.
    public func copyThenVerify(migrationID: UUID) async throws -> V2UserShardMigrationRecord {
        guard let current = try await store.load(migrationID: migrationID),
              current.phase == .prepared || current.phase == .failed
        else { throw V2UserShardMigrationError.invalidTransition }

        let copying = try await store.advance(
            migrationID: migrationID, expectedPhase: current.phase,
            action: .beginCopy, fingerprints: nil, now: now()
        )
        do {
            try await copier.copy(copying)
        } catch {
            _ = try? await store.fail(migrationID: migrationID, expectedPhase: .copying, code: .copyFailed, now: now())
            throw error
        }

        let copied = try await store.advance(
            migrationID: migrationID, expectedPhase: .copying,
            action: .copySucceeded, fingerprints: nil, now: now()
        )
        let verifying = try await store.advance(
            migrationID: migrationID, expectedPhase: copied.phase,
            action: .beginVerification, fingerprints: nil, now: now()
        )
        let fingerprints: (source: String, target: String)
        do {
            fingerprints = try await verifier.fingerprints(for: verifying)
        } catch {
            _ = try? await store.fail(migrationID: migrationID, expectedPhase: .verifying, code: .verificationFailed, now: now())
            throw error
        }
        guard fingerprints.source == fingerprints.target else {
            _ = try? await store.fail(migrationID: migrationID, expectedPhase: .verifying, code: .fingerprintMismatch, now: now())
            throw V2UserShardMigrationVerificationError.fingerprintMismatch
        }
        return try await store.advance(
            migrationID: migrationID, expectedPhase: .verifying,
            action: .verificationSucceeded, fingerprints: fingerprints, now: now()
        )
    }

    /// Forwarding starts only after the initial equality proof. A later
    /// operator-approved final verification must run after the worker has
    /// mirrored source-owner effects into target before cutover is possible.
    public func verifyForwarding(migrationID: UUID) async throws -> V2UserShardMigrationRecord {
        guard let current = try await store.load(migrationID: migrationID), current.phase == .forwarding else {
            throw V2UserShardMigrationError.invalidTransition
        }
        let fingerprints: (source: String, target: String)
        do { fingerprints = try await verifier.fingerprints(for: current) }
        catch {
            _ = try? await store.fail(migrationID: migrationID, expectedPhase: .forwarding, code: .verificationFailed, now: now())
            throw error
        }
        guard fingerprints.source == fingerprints.target else {
            _ = try? await store.fail(migrationID: migrationID, expectedPhase: .forwarding, code: .fingerprintMismatch, now: now())
            throw V2UserShardMigrationVerificationError.fingerprintMismatch
        }
        return try await store.advance(
            migrationID: migrationID, expectedPhase: .forwarding,
            action: .forwardingVerificationSucceeded, fingerprints: fingerprints, now: now()
        )
    }
}

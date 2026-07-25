import Foundation

public enum V2UserShardMigrationOperatorError: Error, Equatable, Sendable {
    /// Another attempt has a durable in-flight phase. Its outcome must be
    /// inspected or retried intentionally rather than starting a second copy.
    case inProgress
}

/// One-user migration control-plane service. It owns preparation/idempotency
/// around the physical executor but deliberately does not own route cutover:
/// the latter remains a separately authorized, epoch-CAS operation.
public struct V2UserShardMigrationOperatorService: Sendable {
    private let store: any V2UserShardMigrationStoring
    private let executor: any V2UserShardMigrationExecuting
    private let now: @Sendable () -> Date

    public init(
        store: any V2UserShardMigrationStoring,
        executor: any V2UserShardMigrationExecuting,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.executor = executor
        self.now = now
    }

    /// Returns `(record, wasIdempotent)`. Only an already-forwarding identical
    /// request is idempotent; nonterminal work is never silently duplicated.
    public func prepareCopyAndVerify(
        _ request: V2UserShardMigrationPreparation
    ) async throws -> (record: V2UserShardMigrationRecord, wasIdempotent: Bool) {
        let prepared = try await store.prepare(request, now: now())
        switch prepared.phase {
        case .forwarding:
            return (prepared, true)
        case .prepared, .failed:
            return (try await executor.copyThenVerify(migrationID: prepared.migrationID), false)
        case .copying, .copied, .verifying:
            throw V2UserShardMigrationOperatorError.inProgress
        case .verified, .cutover, .retention, .completed, .rolledBack:
            throw V2UserShardMigrationError.invalidTransition
        }
    }

    public func verifyForwarding(migrationID: UUID) async throws -> (record: V2UserShardMigrationRecord, wasIdempotent: Bool) {
        guard let current = try await store.load(migrationID: migrationID) else { throw V2UserShardMigrationStoreError.recordNotFound }
        switch current.phase {
        case .verified: return (current, true)
        case .forwarding: return (try await executor.verifyForwarding(migrationID: migrationID), false)
        default: throw V2UserShardMigrationOperatorError.inProgress
        }
    }
}

public protocol V2UserShardMigrationCopyVerifyHandling: Sendable {
    func prepareCopyAndVerify(
        _ request: V2UserShardMigrationPreparation
    ) async throws -> (record: V2UserShardMigrationRecord, wasIdempotent: Bool)
}

public protocol V2UserShardMigrationForwardingVerifyHandling: Sendable {
    func verifyForwarding(migrationID: UUID) async throws -> (record: V2UserShardMigrationRecord, wasIdempotent: Bool)
}

extension V2UserShardMigrationOperatorService: V2UserShardMigrationCopyVerifyHandling {}
extension V2UserShardMigrationOperatorService: V2UserShardMigrationForwardingVerifyHandling {}

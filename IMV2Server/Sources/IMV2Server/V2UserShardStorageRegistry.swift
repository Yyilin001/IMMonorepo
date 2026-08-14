import Fluent
import Foundation
import IMV2Core

/// Runtime-only storage lookup. The logical router remains the sole owner of
/// user assignment; this registry merely resolves its selected bucket to a
/// configured connection and schema. Fluent's `Database` capability is
/// already `Sendable`; this immutable value deliberately carries no mutable
/// routing or connection-pool state of its own.
public struct V2UserShardStorageLocation: Sendable {
    public let bucket: String
    public let database: any Database
    public let schema: String

    public init(bucket: String, database: any Database, schema: String) throws {
        guard !bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
        else { throw V2UserShardStorageRegistryError.invalidLocation }
        self.bucket = bucket
        self.database = database
        self.schema = schema
    }
}

public enum V2UserShardStorageRegistryError: Error, Equatable, Sendable {
    case invalidLocation
    case duplicateBucket
    case unknownBucket
}

public protocol V2UserShardStorageResolving: Sendable {
    func location(for bucket: String) throws -> V2UserShardStorageLocation
}

public protocol V2UserShardMigrationExecuting: Sendable {
    func copyThenVerify(migrationID: UUID) async throws -> V2UserShardMigrationRecord
    func verifyForwarding(migrationID: UUID) async throws -> V2UserShardMigrationRecord
}

/// Physical synchronization performed while route control holds its exclusive
/// generation fence. A cutover cannot publish a new owner until the final
/// source-to-target copy and equality proof succeed; rollback applies the same
/// rule in the reverse direction.
public protocol V2UserShardCutoverFinalizing: Sendable {
    func finalizeForCutover(
        migrationID: UUID, userID: UserID,
        sourceBucket: String, targetBucket: String, sourceRouterEpoch: Int64,
        controlTransaction: any Database
    ) async throws
    func finalizeForRollback(
        migrationID: UUID, userID: UserID,
        sourceBucket: String, targetBucket: String, sourceRouterEpoch: Int64,
        controlTransaction: any Database
    ) async throws
}

public extension V2UserShardMigrationExecuting {
    func verifyForwarding(migrationID _: UUID) async throws -> V2UserShardMigrationRecord {
        throw V2UserShardMigrationError.invalidTransition
    }
}

public struct V2StaticUserShardStorageRegistry: V2UserShardStorageResolving, Sendable {
    private let locations: [String: V2UserShardStorageLocation]

    public init(locations: [V2UserShardStorageLocation]) throws {
        var result: [String: V2UserShardStorageLocation] = [:]
        for location in locations {
            guard result[location.bucket] == nil else { throw V2UserShardStorageRegistryError.duplicateBucket }
            result[location.bucket] = location
        }
        self.locations = result
    }

    public func location(for bucket: String) throws -> V2UserShardStorageLocation {
        guard let location = locations[bucket] else { throw V2UserShardStorageRegistryError.unknownBucket }
        return location
    }
}

/// Resolves the physical endpoints for one durable migration and feeds the
/// existing copy/verify coordinator. It makes a cross-store move impossible
/// to start when either logical bucket is absent from deployment configuration.
public struct V2UserShardProjectionMigrationExecutor: V2UserShardMigrationExecuting, Sendable {
    private let store: any V2UserShardMigrationStoring
    private let registry: any V2UserShardStorageResolving
    private let pageSize: Int
    private let coLocatedControlBuckets: Set<String>
    private let now: @Sendable () -> Date

    public init(
        store: any V2UserShardMigrationStoring,
        registry: any V2UserShardStorageResolving,
        pageSize: Int = 1_000,
        coLocatedControlBuckets: Set<String> = [],
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(pageSize > 0)
        self.store = store
        self.registry = registry
        self.pageSize = pageSize
        self.coLocatedControlBuckets = coLocatedControlBuckets
        self.now = now
    }

    public func copyThenVerify(migrationID: UUID) async throws -> V2UserShardMigrationRecord {
        guard let record = try await store.load(migrationID: migrationID) else {
            throw V2UserShardMigrationStoreError.recordNotFound
        }
        let source = try registry.location(for: record.sourceBucket)
        let target = try registry.location(for: record.targetBucket)
        let transfer = try PostgresV2UserShardProjectionTransfer(
            source: source.database, target: target.database,
            sourceBucket: source.bucket, targetBucket: target.bucket,
            sourceSchema: source.schema, targetSchema: target.schema, pageSize: pageSize
        )
        return try await V2DurableUserShardMigrationCoordinator(
            store: store, copier: transfer, verifier: transfer, now: now
        ).copyThenVerify(migrationID: migrationID)
    }

    public func verifyForwarding(migrationID: UUID) async throws -> V2UserShardMigrationRecord {
        guard let record = try await store.load(migrationID: migrationID) else {
            throw V2UserShardMigrationStoreError.recordNotFound
        }
        let source = try registry.location(for: record.sourceBucket)
        let target = try registry.location(for: record.targetBucket)
        let transfer = try PostgresV2UserShardProjectionTransfer(
            source: source.database, target: target.database,
            sourceBucket: source.bucket, targetBucket: target.bucket,
            sourceSchema: source.schema, targetSchema: target.schema, pageSize: pageSize
        )
        return try await V2DurableUserShardMigrationCoordinator(
            store: store, copier: transfer, verifier: transfer, now: now
        ).verifyForwarding(migrationID: migrationID)
    }
}

extension V2UserShardProjectionMigrationExecutor: V2UserShardCutoverFinalizing {
    public func finalizeForCutover(
        migrationID: UUID, userID: UserID,
        sourceBucket: String, targetBucket: String, sourceRouterEpoch: Int64,
        controlTransaction: any Database
    ) async throws {
        let context = try transferContext(
            migrationID: migrationID, userID: userID,
            sourceBucket: sourceBucket, targetBucket: targetBucket,
            sourceRouterEpoch: sourceRouterEpoch,
            controlTransaction: controlTransaction
        )
        try await context.transfer.copy(context.record)
        let fingerprints = try await context.transfer.fingerprints(for: context.record)
        guard fingerprints.source == fingerprints.target else {
            throw V2UserShardMigrationVerificationError.fingerprintMismatch
        }
    }

    public func finalizeForRollback(
        migrationID: UUID, userID: UserID,
        sourceBucket: String, targetBucket: String, sourceRouterEpoch: Int64,
        controlTransaction: any Database
    ) async throws {
        let context = try transferContext(
            migrationID: migrationID, userID: userID,
            sourceBucket: sourceBucket, targetBucket: targetBucket,
            sourceRouterEpoch: sourceRouterEpoch,
            controlTransaction: controlTransaction
        )
        let reverse = try PostgresV2UserShardProjectionTransfer(
            source: context.target.database, target: context.source.database,
            sourceBucket: context.record.targetBucket,
            targetBucket: context.record.sourceBucket,
            sourceSchema: context.target.schema, targetSchema: context.source.schema,
            pageSize: pageSize
        )
        let reverseRecord = V2UserShardMigrationRecord(
            migrationID: context.record.migrationID, userID: context.record.userID,
            sourceBucket: context.record.targetBucket,
            targetBucket: context.record.sourceBucket,
            sourceRouterEpoch: context.record.sourceRouterEpoch,
            phase: context.record.phase,
            sourceFingerprint: context.record.targetFingerprint,
            targetFingerprint: context.record.sourceFingerprint,
            verifiedAt: context.record.verifiedAt,
            lastErrorCode: context.record.lastErrorCode,
            cutoverOperationID: context.record.cutoverOperationID,
            retentionUntil: context.record.retentionUntil
        )
        // Sequence numbers are part of the sync contract and cannot be
        // reconciled row-by-row after the target has accepted post-cutover
        // writes. Rebuild the retained source from the authoritative target
        // while the route fence excludes all routed writes. A failure leaves
        // the route on the target; the operator can safely retry the rebuild.
        try await context.transfer.cleanSource(for: context.record)
        try await reverse.copy(reverseRecord)
        let fingerprints = try await reverse.fingerprints(for: reverseRecord)
        guard fingerprints.source == fingerprints.target else {
            throw V2UserShardMigrationVerificationError.fingerprintMismatch
        }
    }

    private func transferContext(
        migrationID: UUID, userID: UserID,
        sourceBucket: String, targetBucket: String, sourceRouterEpoch: Int64,
        controlTransaction: any Database
    ) throws -> (
        record: V2UserShardMigrationRecord,
        source: V2UserShardStorageLocation,
        target: V2UserShardStorageLocation,
        transfer: PostgresV2UserShardProjectionTransfer
    ) {
        let record = V2UserShardMigrationRecord(
            migrationID: migrationID, userID: userID,
            sourceBucket: sourceBucket, targetBucket: targetBucket,
            sourceRouterEpoch: sourceRouterEpoch, phase: .verified,
            sourceFingerprint: nil, targetFingerprint: nil
        )
        let configuredSource = try registry.location(for: sourceBucket)
        let configuredTarget = try registry.location(for: targetBucket)
        let source = try coLocatedControlBuckets.contains(sourceBucket)
            ? V2UserShardStorageLocation(
                bucket: configuredSource.bucket, database: controlTransaction,
                schema: configuredSource.schema
            ) : configuredSource
        let target = try coLocatedControlBuckets.contains(targetBucket)
            ? V2UserShardStorageLocation(
                bucket: configuredTarget.bucket, database: controlTransaction,
                schema: configuredTarget.schema
            ) : configuredTarget
        return (
            record, source, target,
            try PostgresV2UserShardProjectionTransfer(
                source: source.database, target: target.database,
                sourceBucket: source.bucket, targetBucket: target.bucket,
                sourceSchema: source.schema, targetSchema: target.schema,
                pageSize: pageSize
            )
        )
    }
}

/// Runtime source-cleaner backed by the same registry used for copy/verify.
/// It cannot accidentally clean a bucket that was not explicitly configured.
public struct V2UserShardProjectionSourceCleaner: V2UserShardMigrationRetentionCleaning {
    private let registry: any V2UserShardStorageResolving
    private let pageSize: Int

    public init(registry: any V2UserShardStorageResolving, pageSize: Int = 1_000) {
        precondition(pageSize > 0)
        self.registry = registry
        self.pageSize = pageSize
    }

    public func cleanSource(for record: V2UserShardMigrationRecord) async throws {
        let source = try registry.location(for: record.sourceBucket)
        let target = try registry.location(for: record.targetBucket)
        let transfer = try PostgresV2UserShardProjectionTransfer(
            source: source.database, target: target.database,
            sourceBucket: source.bucket, targetBucket: target.bucket,
            sourceSchema: source.schema, targetSchema: target.schema, pageSize: pageSize
        )
        try await transfer.cleanSource(for: record)
    }
}

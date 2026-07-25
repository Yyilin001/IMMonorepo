import Fluent
import Foundation

/// Runtime-only storage lookup. The logical router remains the sole owner of
/// user assignment; this registry merely resolves its selected bucket to a
/// configured connection and schema.
public struct V2UserShardStorageLocation: @unchecked Sendable {
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

public extension V2UserShardMigrationExecuting {
    func verifyForwarding(migrationID _: UUID) async throws -> V2UserShardMigrationRecord {
        throw V2UserShardMigrationError.invalidTransition
    }
}

public struct V2StaticUserShardStorageRegistry: V2UserShardStorageResolving, @unchecked Sendable {
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
    private let now: @Sendable () -> Date

    public init(
        store: any V2UserShardMigrationStoring,
        registry: any V2UserShardStorageResolving,
        pageSize: Int = 1_000,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(pageSize > 0)
        self.store = store
        self.registry = registry
        self.pageSize = pageSize
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

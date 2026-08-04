import Fluent
import Foundation
import IMV2Core
import SQLKit

/// One operator-authorized reset request. The operation UUID is also the
/// snapshot ID, making a lost response safe to retry without staging another
/// reset for the same device.
public struct V2DeviceSnapshotResetCommand: Sendable {
    public let operationID: UUID
    public let userID: UserID
    public let deviceID: DeviceID

    public init(operationID: UUID, userID: UserID, deviceID: DeviceID) {
        self.operationID = operationID
        self.userID = userID
        self.deviceID = deviceID
    }
}

public struct V2DeviceSnapshotResetResult: Equatable, Sendable {
    public let generation: UInt64
    public let wasIdempotent: Bool
    public init(generation: UInt64, wasIdempotent: Bool) { self.generation = generation; self.wasIdempotent = wasIdempotent }
}

public enum V2DeviceSnapshotResetError: Error, Equatable, Sendable {
    case deviceUnavailable
    case resetAlreadyPending
    case malformedPersistence
    case unavailable
}

public protocol V2DeviceSnapshotResetting: Sendable {
    func stage(_ command: V2DeviceSnapshotResetCommand) async throws -> V2DeviceSnapshotResetResult
}

/// Routes one reset to the current write-owner shard. The account/device check
/// is performed against that shard before a read-only materialization begins;
/// an operator can neither reset a revoked device nor create a cursor for an
/// arbitrary user/device pair. This is intentionally an operator recovery
/// boundary, never a gateway or account-edge API.
public struct V2PostgresDeviceSnapshotResetService: V2DeviceSnapshotResetting, Sendable {
    private let router: any V2UserShardRouter
    private let registry: any V2UserShardStorageResolving
    private let capabilityProfile: String

    public init(
        router: any V2UserShardRouter,
        registry: any V2UserShardStorageResolving,
        capabilityProfile: String
    ) throws {
        let normalized = capabilityProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw V2DeviceSnapshotResetError.unavailable }
        self.router = router
        self.registry = registry
        self.capabilityProfile = normalized
    }

    public func stage(_ command: V2DeviceSnapshotResetCommand) async throws -> V2DeviceSnapshotResetResult {
        let location = try await location(for: command.userID)
        guard let sql = location.database as? any SQLDatabase else { throw V2DeviceSnapshotResetError.unavailable }
        let userUUID = try snapshotResetUUID(command.userID)
        let deviceUUID = try snapshotResetUUID(command.deviceID)
        let snapshotID = try SnapshotID(command.operationID.uuidString)
        let snapshotUUID = command.operationID

        guard try await sql.raw("SELECT 1 FROM \(unsafeRaw: location.schema).auth_devices WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID) AND revoked_at IS NULL").first() != nil else {
            throw V2DeviceSnapshotResetError.deviceUnavailable
        }
        if let existing = try await generation(for: snapshotUUID, userID: userUUID, deviceID: deviceUUID, schema: location.schema, sql: sql) {
            return .init(generation: existing, wasIdempotent: true)
        }

        let sync = V2SyncService(store: PostgresV2SyncStore(database: location.database, schema: location.schema))
        let stager = V2ServerSnapshotResetStager(
            materializer: .init(database: location.database, schema: location.schema),
            sync: sync
        )
        do {
            let generation = try await stager.stageReset(
                userID: command.userID,
                deviceID: command.deviceID,
                capabilityProfile: capabilityProfile,
                snapshotID: snapshotID
            )
            return .init(generation: generation, wasIdempotent: false)
        } catch V2SyncStoreError.resetAlreadyPending {
            if let existing = try await generation(for: snapshotUUID, userID: userUUID, deviceID: deviceUUID, schema: location.schema, sql: sql) {
                return .init(generation: existing, wasIdempotent: true)
            }
            throw V2DeviceSnapshotResetError.resetAlreadyPending
        }
    }

    private func location(for userID: UserID) async throws -> V2UserShardStorageLocation {
        let routes = try await router.routes(for: [userID])
        guard let route = routes.first, routes.count == 1 else { throw V2DeviceSnapshotResetError.unavailable }
        return try registry.location(for: route.bucket)
    }

    private func generation(for snapshotID: UUID, userID: UUID, deviceID: UUID, schema: String, sql: any SQLDatabase) async throws -> UInt64? {
        let row = try await sql.raw("SELECT reset_generation FROM \(unsafeRaw: schema).sync_snapshots WHERE snapshot_id = \(bind: snapshotID) AND user_id = \(bind: userID) AND device_id = \(bind: deviceID)").first(decoding: SnapshotResetRow.self)
        guard let row else { return nil }
        guard row.generation >= 0 else { throw V2DeviceSnapshotResetError.malformedPersistence }
        return UInt64(row.generation)
    }
}

private struct SnapshotResetRow: Decodable { let generation: Int64; enum CodingKeys: String, CodingKey { case generation = "reset_generation" } }
private func snapshotResetUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = UUID(uuidString: identifier.rawValue) else { throw V2DeviceSnapshotResetError.malformedPersistence }
    return value
}

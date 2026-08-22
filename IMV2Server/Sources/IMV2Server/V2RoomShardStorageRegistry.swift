import Fluent
import Foundation

/// Runtime-only mapping from a durable logical room owner to its physical
/// PostgreSQL location. A room row stores only `room_shard_id`; connection
/// details stay in deployment configuration and therefore never enter an
/// event, delivery record, log line, or client response.
public struct V2RoomShardStorageLocation: Sendable {
    public let shardID: String
    public let database: any Database
    public let schema: String

    public init(shardID: String, database: any Database, schema: String) throws {
        guard !shardID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
        else { throw V2RoomShardStorageRegistryError.invalidLocation }
        self.shardID = shardID
        self.database = database
        self.schema = schema
    }
}

public enum V2RoomShardStorageRegistryError: Error, Equatable, Sendable {
    case invalidLocation
    case duplicateShardID
    case unknownShardID
}

/// Resolves a persisted room owner. It deliberately accepts only the logical
/// shard ID, never a client-supplied endpoint or a freshly computed hash.
public protocol V2RoomShardStorageResolving: Sendable {
    func location(for shardID: String) throws -> V2RoomShardStorageLocation
}

public struct V2StaticRoomShardStorageRegistry: V2RoomShardStorageResolving, Sendable {
    private let locations: [String: V2RoomShardStorageLocation]

    public init(locations: [V2RoomShardStorageLocation]) throws {
        var result: [String: V2RoomShardStorageLocation] = [:]
        for location in locations {
            guard result[location.shardID] == nil else {
                throw V2RoomShardStorageRegistryError.duplicateShardID
            }
            result[location.shardID] = location
        }
        self.locations = result
    }

    public func location(for shardID: String) throws -> V2RoomShardStorageLocation {
        guard let location = locations[shardID] else {
            throw V2RoomShardStorageRegistryError.unknownShardID
        }
        return location
    }
}

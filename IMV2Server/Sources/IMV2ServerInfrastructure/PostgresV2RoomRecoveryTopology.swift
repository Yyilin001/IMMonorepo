import IMV2ServerApplication
import IMV2ServerContracts
import IMV2Core
import Crypto
import FluentKit
import Foundation
import SQLKit

/// 将部署身份与事务更新的路由栅栏结合起来。
/// 使用控制数据库，不使用所有者副本或缓存的路由快照。
public struct PostgresV2RoomRecoveryTopology: V2RoomRecoveryDirectoryReading {
    private let database: any Database
    private let schema: String
    private let stores: [any V2UserRoomDirectoryReading]
    private let configurationDigest: String
    package struct AtomicStore: Sendable {
        package let store: PostgresV2RoomRecoveryStore
        package let shardIDs: Set<String>
        package init(store: PostgresV2RoomRecoveryStore, shardIDs: Set<String>) {
            self.store = store; self.shardIDs = shardIDs
        }
    }
    private let atomicStores: [Int: AtomicStore]
    public var storeCount: Int { stores.count }

    package init(database: any Database, schema: String = "im_v2",
                stores: [any V2UserRoomDirectoryReading], orderedStoreIdentities: [String], atomicStores: [Int: AtomicStore]) throws {
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
              !stores.isEmpty, stores.count == orderedStoreIdentities.count,
              orderedStoreIdentities.allSatisfy({ !$0.isEmpty }),
              Set(orderedStoreIdentities).count == orderedStoreIdentities.count else {
            throw V2RoomRecoveryReadError.invalidRequest
        }
        self.database = database
        self.schema = schema
        guard atomicStores.keys.allSatisfy({ stores.indices.contains($0) }),
              atomicStores.values.allSatisfy({ !$0.shardIDs.isEmpty }) else { throw V2RoomRecoveryReadError.invalidRequest }
        self.stores = stores; self.atomicStores = atomicStores
        // 长度限定编码可避免配置身份产生歧义。
        let encoded = try JSONEncoder().encode(orderedStoreIdentities)
        self.configurationDigest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    public func generation() async throws -> String {
        try Task.checkCancellation()
        guard let sql = database as? any SQLDatabase else { throw V2RoomRecoveryReadError.corruptPersistence }
        guard let row = try await sql.raw("""
            SELECT generation FROM \(unsafeRaw: schema).room_recovery_topology WHERE singleton = true
            """).first(decoding: GenerationRow.self) else {
            throw V2RoomRecoveryReadError.corruptPersistence
        }
        return configurationDigest + ":" + row.generation.uuidString.lowercased()
    }
    public func snapshot(actorUserID: UserID, after: RoomID?, limit: Int, storeIndex: Int) async throws -> V2RoomRecoveryDirectorySnapshot {
        guard stores.indices.contains(storeIndex) else { throw V2RoomRecoveryReadError.invalidCursor }
        if let atomic = atomicStores[storeIndex] {
            let snapshot = try await atomic.store.roomsWithTopology(actorUserID: actorUserID, after: after,
                limit: limit, controlSchema: schema, physicalStoreShardIDs: atomic.shardIDs)
            return try .init(generation: configurationDigest + ":" + snapshot.generation.uuidString.lowercased(), slice: snapshot.slice)
        }
        // Separate physical databases require the authoritative control fence
        // around their remote page; they cannot share a PostgreSQL MVCC snapshot.
        let before = try await generation()
        let slice = try await stores[storeIndex].rooms(actorUserID: actorUserID, after: after, limit: limit)
        guard try await generation() == before else { throw V2RoomRecoveryReadError.topologyChanged }
        return try .init(generation: before, slice: slice)
    }

}

private struct GenerationRow: Decodable {
    let generation: UUID
}

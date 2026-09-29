import Foundation
import IMV2Core

public struct V2UserRoomDirectoryPage: Sendable {
    public let rooms: [V2UserRoomDirectoryEntry]
    public let nextCursor: String?
    public let topologyGeneration: String

    package init(rooms: [V2UserRoomDirectoryEntry], nextCursor: String?, topologyGeneration: String) {
        self.rooms = rooms
        self.nextCursor = nextCursor
        self.topologyGeneration = topologyGeneration
    }
}

/// 同一代次内，物理存储必须去重并保持一致的排序。
public struct V2RoomRecoveryTopology: Sendable {
    public let generation: String
    public let stores: [any V2UserRoomDirectoryReading]

    public init(generation: String, stores: [any V2UserRoomDirectoryReading]) throws {
        guard !generation.isEmpty, generation.utf8.count <= 128, !stores.isEmpty,
              stores.count <= Int(Int32.max) else { throw V2RoomRecoveryReadError.invalidRequest }
        self.generation = generation
        self.stores = stores
    }
}

public protocol V2RoomRecoveryTopologyReading: Sendable {
    /// 只要扫描可能漏掉跨物理存储迁移的房间，代次就会变化。
    func topology() async throws -> V2RoomRecoveryTopology
}

import IMV2Core

/// Filters migration copies without changing the physical scan position.
/// The enclosing directory service must also fence the scan by topology generation.
public struct V2OwnerValidatedRoomDirectoryStore: V2UserRoomDirectoryReading {
    private let underlying: any V2UserRoomDirectoryReading
    private let router: any V2RoomShardRouting
    private let physicalStoreShardIDs: Set<String>

    public init(underlying: any V2UserRoomDirectoryReading,
                router: any V2RoomShardRouting, physicalStoreShardIDs: Set<String>) throws {
        guard !physicalStoreShardIDs.isEmpty,
              physicalStoreShardIDs.allSatisfy({ !$0.isEmpty }) else {
            throw V2RoomRecoveryReadError.invalidRequest
        }
        self.underlying = underlying
        self.router = router
        self.physicalStoreShardIDs = physicalStoreShardIDs
    }

    public func rooms(actorUserID: UserID, after: RoomID?, limit: Int) async throws -> V2UserRoomDirectorySlice {
        guard limit > 0, limit <= 100 else { throw V2RoomRecoveryReadError.invalidRequest }
        try Task.checkCancellation()
        let slice = try await underlying.rooms(actorUserID: actorUserID, after: after, limit: limit)
        guard slice.entries.count <= limit,
              Set(slice.entries.map(\.roomID)).count == slice.entries.count else {
            throw V2RoomRecoveryReadError.corruptPersistence
        }
        guard !slice.entries.isEmpty else { return slice }
        let routes = try await router.routes(for: slice.entries.map(\.roomID))
        try Task.checkCancellation()
        var entries: [V2UserRoomDirectoryEntry] = []
        for entry in slice.entries {
            // Missing or inconsistent routing must fail the page, never advance
            // past an unverified member as though it had been fully checked.
            guard let route = routes[entry.roomID] else {
                throw V2RoomRecoveryReadError.corruptPersistence
            }
            guard physicalStoreShardIDs.contains(route.shardID) else { continue }
            guard UInt64(route.epoch) == entry.ownerEpoch else {
                throw V2RoomRecoveryReadError.topologyChanged
            }
            entries.append(entry)
        }
        return .init(entries: entries, scannedThrough: slice.scannedThrough, hasMore: slice.hasMore)
    }
}

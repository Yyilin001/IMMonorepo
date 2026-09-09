import Foundation
import IMV2Core

/// Routes existing room writes to the physical owner recorded by the control
/// plane. A command never tries a second owner after the selected store fails:
/// retry/idempotency remains the caller's responsibility and the room keeps a
/// single serial writer.
public struct V2RoutedRoomWriteStore: V2AtomicRoomWriteBatchStore {
    private let router: any V2RoomShardRouting
    private let stores: [String: any V2OwnerValidatedRoomWriteStore]
    /// Logical owner IDs may share one physical database during a staged
    /// rollout.  Commands on such IDs can retain a single atomic append
    /// transaction; commands on distinct keys never cross a physical owner.
    private let physicalStoreKeyByShard: [String: String]

    public init(
        router: any V2RoomShardRouting,
        stores: [String: any V2OwnerValidatedRoomWriteStore],
        physicalStoreKeyByShard: [String: String]? = nil
    ) throws {
        guard !stores.isEmpty, stores.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw V2RoomShardStorageRegistryError.invalidLocation
        }
        let keys = physicalStoreKeyByShard ?? Dictionary(
            uniqueKeysWithValues: stores.keys.map { ($0, $0) }
        )
        guard Set(keys.keys) == Set(stores.keys),
              keys.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw V2RoomShardStorageRegistryError.invalidLocation }
        self.router = router
        self.stores = stores
        self.physicalStoreKeyByShard = keys
    }

    public func accept(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) async throws -> V2SendMessageOutcome {
        let route = try await router.route(for: command.roomID)
        guard let store = stores[route.shardID] else {
            throw V2RoomShardStorageRegistryError.unknownShardID
        }
        return try await store.acceptOwnerValidated(
            request: .init(command: command, capacityProfile: capacityProfile,
                identifiers: identifiers, now: now), ownerRoute: route
        )
    }

    public func atomicBatchEligibility(
        requests: [V2RoomWriteRequest]
    ) async -> [Bool] {
        guard !requests.isEmpty else { return [] }
        do {
            let groups = try await groupedRequests(requests)
            return await withTaskGroup(
                of: [(Int, Bool)].self,
                returning: [Bool].self
            ) { group in
                for (_, entries) in groups {
                    guard let first = entries.first,
                          let store = stores[first.route.shardID]
                    else { return Array(repeating: false, count: requests.count) }
                    group.addTask {
                        let eligibility = await store.atomicBatchEligibility(
                            requests: entries.map(\.request)
                        )
                        guard eligibility.count == entries.count else {
                            return entries.map { ($0.index, false) }
                        }
                        return zip(entries, eligibility).map { ($0.0.index, $0.1) }
                    }
                }
                var result = Array(repeating: false, count: requests.count)
                for await entries in group {
                    for (index, eligible) in entries { result[index] = eligible }
                }
                return result
            }
        } catch {
            // This classifier must not turn a route failure into a client
            // acknowledgement. The ordinary path will surface the same
            // durable error through its established retry boundary.
            return Array(repeating: false, count: requests.count)
        }
    }

    public func atomicBatchPartitions(
        requests: [V2RoomWriteRequest]
    ) async -> [V2AtomicRoomWriteBatchPartition?] {
        guard !requests.isEmpty else { return [] }
        do {
            let groups = try await groupedRequests(requests)
            return await withTaskGroup(
                of: [(Int, V2AtomicRoomWriteBatchPartition?)].self,
                returning: [V2AtomicRoomWriteBatchPartition?].self
            ) { group in
                for (_, entries) in groups {
                    guard let first = entries.first,
                          let store = stores[first.route.shardID]
                    else { return Array(repeating: nil, count: requests.count) }
                    group.addTask {
                        let partitions = await store.atomicBatchPartitions(
                            requests: entries.map(\.request)
                        )
                        guard partitions.count == entries.count else {
                            return entries.map { ($0.index, nil) }
                        }
                        return zip(entries, partitions).map { ($0.0.index, $0.1) }
                    }
                }
                var result = Array<V2AtomicRoomWriteBatchPartition?>(
                    repeating: nil, count: requests.count
                )
                for await entries in group {
                    for (index, partition) in entries { result[index] = partition }
                }
                return result
            }
        } catch {
            return Array(repeating: nil, count: requests.count)
        }
    }

    public func acceptAtomically(
        requests: [V2RoomWriteRequest]
    ) async throws -> [V2SendMessageOutcome] {
        guard !requests.isEmpty else { return [] }
        let groups = try await groupedRequests(requests)

        // Inputs in different owners are independent. Run those bounded
        // owner transactions concurrently, while each owner's PostgreSQL CTE
        // continues to serialize and order its own rooms.
        return try await withThrowingTaskGroup(
            of: [(Int, V2SendMessageOutcome)].self,
            returning: [V2SendMessageOutcome].self
        ) { group in
            for (_, entries) in groups {
                guard let first = entries.first,
                      let store = stores[first.route.shardID]
                else {
                    throw V2RoomShardStorageRegistryError.unknownShardID
                }
                group.addTask {
                    let shardRequests = entries.map(\.request)
                    let outcomes: [V2SendMessageOutcome]
                    if shardRequests.count == 1 {
                        let request = shardRequests[0]
                        outcomes = [try await store.acceptOwnerValidated(
                            request: request, ownerRoute: first.route
                        )]
                    } else {
                        outcomes = try await store.acceptAtomicallyOwnerValidated(
                            requests: entries.map { .init(request: $0.request, ownerRoute: $0.route) }
                        )
                    }
                    guard outcomes.count == entries.count else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    return zip(entries, outcomes).map { ($0.0.index, $0.1) }
                }
            }
            var ordered = Array<V2SendMessageOutcome?>(repeating: nil, count: requests.count)
            for try await outcomes in group {
                for (index, outcome) in outcomes { ordered[index] = outcome }
            }
            guard ordered.allSatisfy({ $0 != nil }) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return ordered.map { $0! }
        }
    }

    private func groupedRequests(
        _ requests: [V2RoomWriteRequest]
    ) async throws -> [String: [(index: Int, request: V2RoomWriteRequest, route: V2RoomShardRoute)]] {
        let routes = try await router.routes(for: requests.map { $0.command.roomID })
        var groups: [String: [(index: Int, request: V2RoomWriteRequest, route: V2RoomShardRoute)]] = [:]
        for (index, request) in requests.enumerated() {
            guard let route = routes[request.command.roomID],
                  stores[route.shardID] != nil,
                  let physicalKey = physicalStoreKeyByShard[route.shardID]
            else { throw V2RoomShardStorageRegistryError.unknownShardID }
            groups[physicalKey, default: []].append((index, request, route))
        }
        return groups
    }
}

/// Direct-room creation has no pre-existing room ID. It uses the control
/// directory's pair fence to select an owner once, persists that decision on
/// success, and delegates ordinary preference writes to the control store.
public struct V2RoutedDirectMessagingStore: V2DirectMessagingStore {
    private let router: any V2DirectRoomShardRouting
    private let ownerStores: [String: any V2DirectMessagingStore]
    private let controlStore: any V2DirectMessagingStore

    public init(
        router: any V2DirectRoomShardRouting,
        ownerStores: [String: any V2DirectMessagingStore],
        controlStore: any V2DirectMessagingStore
    ) throws {
        guard !ownerStores.isEmpty else { throw V2RoomShardStorageRegistryError.invalidLocation }
        self.router = router
        self.ownerStores = ownerStores
        self.controlStore = controlStore
    }

    public func open(
        command: V2OpenDirectRoomCommand,
        capacityProfile: V2CapacityProfile,
        roomShardID: String,
        roomID: RoomID,
        now: Date
    ) async throws -> V2OpenDirectRoomOutcome {
        try await router.withDirectPairRoute(
            actorUserID: command.actorUserID,
            targetUserID: command.targetUserID,
            proposedShardID: roomShardID
        ) { route in
            guard let store = ownerStores[route.shardID] else {
                throw V2RoomShardStorageRegistryError.unknownShardID
            }
            let outcome = try await store.open(
                command: command, capacityProfile: capacityProfile,
                roomShardID: route.shardID, roomID: roomID, now: now
            )
            let persistedRoomID: RoomID?
            switch outcome {
            case .opened(let room), .idempotent(let room): persistedRoomID = room.roomID
            case .idempotencyConflict, .unavailable: persistedRoomID = nil
            }
            return (outcome, persistedRoomID)
        }
    }

    public func setStrangerMessagePermission(
        command: V2SetStrangerMessagePermissionCommand, now: Date
    ) async throws -> V2SetStrangerMessagePermissionOutcome {
        try await controlStore.setStrangerMessagePermission(command: command, now: now)
    }

    public func setUserAddPermission(
        command: V2SetUserAddPermissionCommand, now: Date
    ) async throws -> V2SetUserAddPermissionOutcome {
        try await controlStore.setUserAddPermission(command: command, now: now)
    }
}

/// Room-log reads use the same owner directory as writes. Cache entries are
/// still validated by the delegated store against that owner's durable room
/// membership state before being returned.
public struct V2RoutedGroupEventLogStore: V2GroupEventLogStore {
    private let router: any V2RoomShardRouting
    private let stores: [String: any V2GroupEventLogStore]

    public init(
        router: any V2RoomShardRouting,
        stores: [String: any V2GroupEventLogStore]
    ) throws {
        guard !stores.isEmpty else { throw V2RoomShardStorageRegistryError.invalidLocation }
        self.router = router
        self.stores = stores
    }

    public func pull(
        roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int
    ) async throws -> V2GroupEventLogPage {
        try await store(for: roomID).pull(
            roomID: roomID, actorUserID: actorUserID,
            afterRoomSequence: afterRoomSequence, pageSize: pageSize
        )
    }

    public func subscribe(
        roomID: RoomID, actorUserID: UserID
    ) async throws -> V2GroupEventSubscription {
        try await store(for: roomID).subscribe(roomID: roomID, actorUserID: actorUserID)
    }

    private func store(for roomID: RoomID) async throws -> any V2GroupEventLogStore {
        let route = try await router.route(for: roomID)
        guard let store = stores[route.shardID] else {
            throw V2RoomShardStorageRegistryError.unknownShardID
        }
        return store
    }
}

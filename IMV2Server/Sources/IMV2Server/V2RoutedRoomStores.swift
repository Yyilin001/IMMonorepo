import Foundation
import IMV2Core

/// Routes existing room writes to the physical owner recorded by the control
/// plane. A command never tries a second owner after the selected store fails:
/// retry/idempotency remains the caller's responsibility and the room keeps a
/// single serial writer.
public struct V2RoutedRoomWriteStore: V2AtomicRoomWriteBatchStore {
    private let router: any V2RoomShardRouting
    private let stores: [String: any V2AtomicRoomWriteBatchStore]

    public init(
        router: any V2RoomShardRouting,
        stores: [String: any V2AtomicRoomWriteBatchStore]
    ) throws {
        guard !stores.isEmpty, stores.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw V2RoomShardStorageRegistryError.invalidLocation
        }
        self.router = router
        self.stores = stores
    }

    public func accept(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) async throws -> V2SendMessageOutcome {
        let store = try await store(for: command.roomID)
        return try await store.accept(
            command: command, capacityProfile: capacityProfile,
            identifiers: identifiers, now: now
        )
    }

    public func atomicBatchEligibility(
        requests: [V2RoomWriteRequest]
    ) async -> [Bool] {
        var result: [Bool] = []
        result.reserveCapacity(requests.count)
        for request in requests {
            do {
                let store = try await store(for: request.command.roomID)
                result.append(await store.atomicBatchEligibility(requests: [request])[0])
            } catch {
                // This classifier must not turn a route failure into a client
                // acknowledgement. The ordinary path will surface the same
                // durable error through its established retry boundary.
                result.append(false)
            }
        }
        return result
    }

    public func acceptAtomically(
        requests: [V2RoomWriteRequest]
    ) async throws -> [V2SendMessageOutcome] {
        guard !requests.isEmpty else { return [] }
        var groups: [String: [(index: Int, request: V2RoomWriteRequest)]] = [:]
        for (index, request) in requests.enumerated() {
            let route = try await router.route(for: request.command.roomID)
            guard stores[route.shardID] != nil else {
                throw V2RoomShardStorageRegistryError.unknownShardID
            }
            groups[route.shardID, default: []].append((index, request))
        }

        // Inputs in different owners are independent. Run those bounded
        // owner transactions concurrently, while each owner's PostgreSQL CTE
        // continues to serialize and order its own rooms.
        return try await withThrowingTaskGroup(
            of: [(Int, V2SendMessageOutcome)].self,
            returning: [V2SendMessageOutcome].self
        ) { group in
            for (shardID, entries) in groups {
                guard let store = stores[shardID] else {
                    throw V2RoomShardStorageRegistryError.unknownShardID
                }
                group.addTask {
                    let shardRequests = entries.map(\.request)
                    let outcomes: [V2SendMessageOutcome]
                    if shardRequests.count == 1 {
                        let request = shardRequests[0]
                        outcomes = [try await store.accept(
                            command: request.command, capacityProfile: request.capacityProfile,
                            identifiers: request.identifiers, now: request.now
                        )]
                    } else {
                        outcomes = try await store.acceptAtomically(requests: shardRequests)
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

    private func store(for roomID: RoomID) async throws -> any V2AtomicRoomWriteBatchStore {
        let route = try await router.route(for: roomID)
        guard let store = stores[route.shardID] else {
            throw V2RoomShardStorageRegistryError.unknownShardID
        }
        return store
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

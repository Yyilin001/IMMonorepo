import Foundation
import IMV2Core

/// Routes a source/target pair only to its persisted owner. Co-located logical
/// shards share the existing atomic source authorization and target acceptance.
/// Cross-store copies require an export/inbox protocol; they must never run the
/// local-source SQL in the target store or report an export as an accepted send.
public struct V2RoutedForwardMessagesService: V2ForwardMessagesHandling {
    private let router: any V2RoomShardRouting
    private let owners: [String: any V2OwnerValidatedForwardMessagesHandling]
    private let physicalKeys: [String: String]
    private let maximumTargetConcurrency: Int
    private let crossOwner: (any V2CrossOwnerForwarding)?

    public init(
        router: any V2RoomShardRouting,
        owners: [String: any V2OwnerValidatedForwardMessagesHandling],
        physicalStoreKeyByShard: [String: String]? = nil,
        maximumTargetConcurrency: Int = 4,
        crossOwner: (any V2CrossOwnerForwarding)? = nil
    ) throws {
        let keys = physicalStoreKeyByShard ?? Dictionary(uniqueKeysWithValues: owners.keys.map { ($0, $0) })
        guard !owners.isEmpty, maximumTargetConcurrency > 0,
              Set(keys.keys) == Set(owners.keys),
              keys.allSatisfy({ !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw V2RoomShardStorageRegistryError.invalidLocation }
        self.router = router
        self.owners = owners
        physicalKeys = keys
        self.maximumTargetConcurrency = maximumTargetConcurrency
        self.crossOwner = crossOwner
    }

    public func forward(actorUserID: UserID, command: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult] {
        let rooms = Array(Set(command.sources.map(\.roomID) + command.targetRoomIDs))
        let routes = try await resolve(rooms)
        // Configuration/route failures are retryable command failures. Never
        // turn a missing configured owner into a lookup on another database.
        for route in routes.values {
            guard owners[route.shardID] != nil, physicalKeys[route.shardID] != nil else {
                throw V2RoomShardStorageRegistryError.unknownShardID
            }
        }
        // Preserve the single source batch and bounded target lanes when all
        // requested rooms are colocated, after resolving every room's epoch.
        if routes.count == rooms.count,
           Set(routes.values.compactMap { physicalKeys[$0.shardID] }).count == 1,
           let target = command.targetRoomIDs.first, let route = routes[target],
           let owner = owners[route.shardID] {
            return try await owner.forwardOwnerValidated(actorUserID: actorUserID,
                command: command, ownerRoutes: routes)
        }
        let targetCount = command.targetRoomIDs.count
        var ordered = Array<V2ForwardMessageResult?>(repeating: nil, count: command.sources.count * targetCount)
        var pending = false, paused = false
        try await withThrowingTaskGroup(of: TargetResults.self) { group in
            var next = 0
            for _ in 0..<min(maximumTargetConcurrency, targetCount) {
                let index = next
                next += 1
                group.addTask { try await forwardTarget(actor: actorUserID, command: command, targetIndex: index, routes: routes) }
            }
            while let completed = try await group.next() {
                pending = pending || completed.pending
                paused = paused || completed.paused
                for (sourceIndex, result) in completed.results.enumerated() {
                    ordered[sourceIndex * targetCount + completed.index] = result
                }
                if next < targetCount {
                    let index = next
                    next += 1
                    group.addTask { try await forwardTarget(actor: actorUserID, command: command, targetIndex: index, routes: routes) }
                }
            }
        }
        // Finish enqueueing every pair before returning pending. Throwing from
        // the first pending target would cancel sibling targets before enqueue.
        if paused { throw V2ForwardPendingError.paused }
        if pending { throw V2ForwardPendingError.pending }
        guard ordered.allSatisfy({ $0 != nil }) else { throw V2RoomShardRouteError.corruptPersistenceState }
        return ordered.compactMap { $0 }
    }

    private func resolve(_ rooms: [RoomID]) async throws -> [RoomID: V2RoomShardRoute] {
        do {
            return try await router.routes(for: rooms)
        } catch V2RoomShardRouteError.roomNotFound {
            // A batch with one nonexistent room must not discard other pairs.
            // Fall back only to bounded directory point reads, never a scan of
            // owner databases. A directory outage still fails the whole call.
            var result: [RoomID: V2RoomShardRoute] = [:]
            for room in rooms {
                try Task.checkCancellation()
                do { result[room] = try await router.route(for: room) }
                catch V2RoomShardRouteError.roomNotFound { continue }
            }
            return result
        }
    }

    private func forwardTarget(actor: UserID, command: V2ForwardMessagesCommand, targetIndex: Int, routes: [RoomID: V2RoomShardRoute]) async throws -> TargetResults {
        let target = command.targetRoomIDs[targetIndex]
        guard let targetRoute = routes[target],
              let owner = owners[targetRoute.shardID],
              let targetKey = physicalKeys[targetRoute.shardID] else {
            return .init(index: targetIndex, results: try command.sources.map { try failure($0, target: target, code: "NOT_FOUND") })
        }
        var results: [V2ForwardMessageResult?] = []
        var pending = false, paused = false
        var index = 0
        while index < command.sources.count {
            try Task.checkCancellation()
            let source = command.sources[index]
            guard let sourceRoute = routes[source.roomID] else {
                results.append(try failure(source, target: target, code: "NOT_FOUND"))
                index += 1
                continue
            }
            guard physicalKeys[sourceRoute.shardID] == targetKey else {
                if let crossOwner {
                    switch try await crossOwner.forward(actor: actor, operation: command.operationID, source: source,
                        sourceRoute: sourceRoute, target: target, targetRoute: targetRoute) {
                    case .completed(let result):
                        guard result.sourceMessageID == source.messageID, result.targetRoomID == target
                        else { throw V2RoomShardRouteError.corruptPersistenceState }
                        results.append(result)
                    case .pending(let isPaused):
                        pending = true; paused = paused || isPaused; results.append(nil)
                    }
                } else {
                    results.append(try failure(source, target: target, code: "CROSS_OWNER_FORWARD_UNAVAILABLE"))
                }
                index += 1
                continue
            }
            let start = index
            repeat { index += 1 } while index < command.sources.count && routes[command.sources[index].roomID].map({ physicalKeys[$0.shardID] == targetKey }) == true
            let sources = Array(command.sources[start..<index])
            let part = try V2ForwardMessagesCommand(operationID: command.operationID, sources: sources, targetRoomIDs: [target])
            let accepted = try await owner.forwardOwnerValidated(actorUserID: actor, command: part, ownerRoutes: routes)
            guard accepted.count == sources.count,
                  Set(accepted.map(\.sourceMessageID)) == Set(sources.map(\.messageID)),
                  accepted.allSatisfy({ $0.targetRoomID == target }) else {
                throw V2RoomShardRouteError.corruptPersistenceState
            }
            let bySource = Dictionary(uniqueKeysWithValues: accepted.map { ($0.sourceMessageID, $0) })
            results += sources.compactMap { bySource[$0.messageID] }
        }
        return .init(index: targetIndex, results: results, pending: pending, paused: paused)
    }

    private func failure(_ source: V2ForwardMessageReference, target: RoomID, code: String) throws -> V2ForwardMessageResult {
        try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: code)
    }

    private struct TargetResults: Sendable {
        let index: Int
        let results: [V2ForwardMessageResult?]
        var pending: Bool = false
        var paused: Bool = false
    }
}

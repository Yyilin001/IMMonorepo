import Foundation
import IMV2ActorContracts
import IMV2Core

/// The composition root implements this port with R2's canonical reservation
/// coordinator, then invokes the pair domain executor with the two exact tokens.
public struct V2ActorForwardPairPort: Sendable {
    public let execute: @Sendable (V2ActorForwardPairWire, ContinuousClock.Instant) async throws -> V2ActorForwardMessageResultWire

    public init(execute: @escaping @Sendable (V2ActorForwardPairWire, ContinuousClock.Instant) async throws -> V2ActorForwardMessageResultWire) {
        self.execute = execute
    }
}

/// Coordinates up to 100x10 independent pairs. A pending cross-owner target
/// never cancels its siblings; no pair expands the reservation beyond two rooms.
public struct V2ActorForwardingCoordinator: V2ForwardMessagesHandling {
    private let router: any V2RoomShardRouting
    private let physicalKeys: [String: String]
    private let pair: V2ActorForwardPairPort
    private let crossOwner: any V2CrossOwnerForwarding
    private let maximumTargetConcurrency: Int
    private let deadline: @Sendable () -> ContinuousClock.Instant

    public init(router: any V2RoomShardRouting, physicalStoreKeyByShard: [String: String],
                pair: V2ActorForwardPairPort, crossOwner: any V2CrossOwnerForwarding,
                maximumTargetConcurrency: Int = 4,
                deadline: @escaping @Sendable () -> ContinuousClock.Instant) throws {
        guard !physicalStoreKeyByShard.isEmpty, (1...10).contains(maximumTargetConcurrency),
              physicalStoreKeyByShard.allSatisfy({ !$0.key.isEmpty && !$0.value.isEmpty }) else {
            throw V2RoomShardStorageRegistryError.invalidLocation
        }
        self.router = router; self.physicalKeys = physicalStoreKeyByShard
        self.pair = pair; self.crossOwner = crossOwner
        self.maximumTargetConcurrency = maximumTargetConcurrency
        self.deadline = deadline
    }

    public func forward(actorUserID: UserID,
                        command: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult] {
        let operationDeadline = deadline()
        guard ContinuousClock().now < operationDeadline else {
            throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
        }
        let targetCount = command.targetRoomIDs.count
        let routes = try await resolve(Array(Set(command.sources.map(\.roomID) + command.targetRoomIDs)))
        var ordered = Array<V2ForwardMessageResult?>(repeating: nil,
            count: command.sources.count * targetCount)
        var pending = false, paused = false
        try await withThrowingTaskGroup(of: TargetResults.self) { group in
            var next = 0
            for _ in 0..<min(maximumTargetConcurrency, targetCount) {
                let index = next; next += 1
                group.addTask { try await forwardTarget(actor: actorUserID,
                    operation: command.operationID, sources: command.sources,
                    target: command.targetRoomIDs[index], index: index, routes: routes,
                    deadline: operationDeadline) }
            }
            while let completed = try await group.next() {
                pending = pending || completed.pending
                paused = paused || completed.paused
                for (sourceIndex, value) in completed.results.enumerated() {
                    ordered[sourceIndex * targetCount + completed.index] = value
                }
                if next < targetCount {
                    let index = next; next += 1
                    group.addTask { try await forwardTarget(actor: actorUserID,
                        operation: command.operationID, sources: command.sources,
                        target: command.targetRoomIDs[index], index: index, routes: routes,
                        deadline: operationDeadline) }
                }
            }
        }
        if paused { throw V2ForwardPendingError.paused }
        if pending { throw V2ForwardPendingError.pending }
        guard ordered.allSatisfy({ $0 != nil }) else {
            throw V2RoomShardRouteError.corruptPersistenceState
        }
        return ordered.compactMap { $0 }
    }

    private func forwardTarget(actor: UserID, operation: MessageForwardOperationID,
                               sources: [V2ForwardMessageReference], target: RoomID,
                               index: Int, routes: [RoomID: V2RoomShardRoute],
                               deadline operationDeadline: ContinuousClock.Instant) async throws -> TargetResults {
        var values: [V2ForwardMessageResult?] = []
        var pending = false, paused = false
        for source in sources {
            try Task.checkCancellation()
            guard ContinuousClock().now < operationDeadline else {
                throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
            }
            guard let sourceRoute = routes[source.roomID], let targetRoute = routes[target] else {
                values.append(try failure(source, target: target, code: "NOT_FOUND"))
                continue
            }
            guard let sourceKey = physicalKeys[sourceRoute.shardID],
                  let targetKey = physicalKeys[targetRoute.shardID] else {
                throw V2RoomShardStorageRegistryError.unknownShardID
            }
            // R2 and the SQL scope require one exact owner shard identity.
            // Distinct logical owners sharing a database still use durable
            // export/inbox; a physical-key match alone grants no pair turn.
            if sourceKey == targetKey && sourceRoute.shardID == targetRoute.shardID {
                let wire = try await pair.execute(.init(actorUserID: actor,
                    operationID: operation, source: source, targetRoomID: target), operationDeadline)
                let result = try wire.toDomain()
                guard result.sourceMessageID == source.messageID,
                      result.targetRoomID == target else {
                    throw V2RoomShardRouteError.corruptPersistenceState
                }
                values.append(result)
            } else {
                switch try await crossOwner.forward(actor: actor, operation: operation,
                    source: source, sourceRoute: sourceRoute, target: target,
                    targetRoute: targetRoute, deadline: operationDeadline) {
                case .completed(let result):
                    guard result.sourceMessageID == source.messageID,
                          result.targetRoomID == target else {
                        throw V2RoomShardRouteError.corruptPersistenceState
                    }
                    values.append(result)
                case .pending(let isPaused):
                    values.append(nil)
                    pending = true; paused = paused || isPaused
                }
            }
        }
        return .init(index: index, results: values, pending: pending, paused: paused)
    }

    private func resolve(_ rooms: [RoomID]) async throws -> [RoomID: V2RoomShardRoute] {
        do { return try await router.routes(for: rooms) }
        catch V2RoomShardRouteError.roomNotFound {
            var result: [RoomID: V2RoomShardRoute] = [:]
            for room in rooms {
                try Task.checkCancellation()
                do { result[room] = try await router.route(for: room) }
                catch V2RoomShardRouteError.roomNotFound { continue }
            }
            return result
        }
    }

    private func failure(_ source: V2ForwardMessageReference,
                         target: RoomID, code: String) throws -> V2ForwardMessageResult {
        try .init(sourceMessageID: source.messageID, targetRoomID: target,
                  messageID: nil, roomSequence: nil, errorCode: code)
    }

    private struct TargetResults: Sendable {
        let index: Int
        let results: [V2ForwardMessageResult?]
        let pending: Bool
        let paused: Bool
    }
}

import Foundation
import IMV2Core

/// 只把源/目标房间对路由到其已持久化的归属。
///
/// 同库部署的逻辑分片复用既有的源端授权与目标接受原子路径；跨库复制必须走导出与收件箱协议，
/// 绝不能在目标存储上执行本地来源 SQL，也不能把一次导出当作已接受的发送上报。
public struct V2RoutedForwardMessagesService: V2ForwardMessagesHandling {
    private let router: any V2RoomShardRouting
    private let owners: [String: any V2OwnerValidatedForwardMessagesHandling]
    private let physicalKeys: [String: String]
    private let maximumTargetConcurrency: Int
    private let crossOwner: (any V2CrossOwnerForwarding)?

    /// 组合路由来源、各归属实现与物理存储映射。
    ///
    /// - Parameters:
    ///   - router: 房间归属路由来源。
    ///   - owners: 逻辑分片标识到转发实现的映射。
    ///   - physicalStoreKeyByShard: 逻辑分片到物理存储键的映射；为 `nil` 时按标识自身映射。
    ///   - maximumTargetConcurrency: 目标房间并发上限，需大于零。
    ///   - crossOwner: 跨库转发的可选实现；为 `nil` 时跨库转发返回不可用错误码。
    /// - Throws: 归属映射为空、并发非正、物理键与逻辑标识不匹配或含空白标识时抛出
    ///   ``V2RoomShardStorageRegistryError/invalidLocation``。
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

    /// 执行一次可能跨多个目标房间的转发。
    ///
    /// 先解析所有涉及房间的归属，任一归属未配置即整体失败，绝不回退到其他数据库查找。
    /// 所有房间同属一个物理存储时走单批原子路径以保留源批与目标通道语义；否则按目标房间
    /// 分批并发处理，源消息按物理存储连续性切分成子批。全部房间结果入队完成后才抛出
    /// 待处理错误，避免撤销尚未入队的兄弟目标。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起转发的用户。
    ///   - command: 转发命令。
    /// - Returns: 与源消息和目标房间笛卡尔积顺序对应的结果。
    /// - Throws: 归属未配置时抛出
    ///   ``V2RoomShardStorageRegistryError/unknownShardID``；存在暂停目标时抛出
    ///   ``V2ForwardPendingError/paused``；存在未完成目标时抛出
    ///   ``V2ForwardPendingError/pending``；结果缺失或归属返回不一致时抛出
    ///   ``V2RoomShardRouteError/corruptPersistenceState``。
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

    /// 解析批量房间的归属，容忍个别房间不存在。
    ///
    /// 批量查询遇到房间缺失时回退为逐个有界目录点查，绝不扫描归属数据库；
    /// 目录本身不可用时整次调用仍然失败。
    ///
    /// - Parameter rooms: 待解析的房间列表。
    /// - Returns: 房间到归属的映射；不存在的房间不会出现在结果中。
    /// - Throws: 目录查询失败时抛出。
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

    /// 处理一个目标房间下的全部源消息。
    ///
    /// 源消息按物理存储键分组：与目标同库的连续来源合并为一个子批交给归属原子处理，
    /// 跨库来源交给跨库转发实现，未配置时返回固定错误码。
    ///
    /// - Parameters:
    ///   - actor: 发起转发的用户。
    ///   - command: 转发命令。
    ///   - targetIndex: 目标房间在命令中的下标。
    ///   - routes: 本次解析出的房间归属。
    /// - Returns: 该目标房间下的全部结果及待处理状态。
    /// - Throws: 任务取消时抛出 `CancellationError`；归属返回值与请求不一致时抛出
    ///   ``V2RoomShardRouteError/corruptPersistenceState``。
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

    /// 构造一个带有稳定错误码的失败结果。
    ///
    /// - Parameters:
    ///   - source: 源消息引用。
    ///   - target: 目标房间。
    ///   - code: 稳定错误码。
    /// - Returns: 失败结果。
    /// - Throws: 结果构造失败时抛出。
    private func failure(_ source: V2ForwardMessageReference, target: RoomID, code: String) throws -> V2ForwardMessageResult {
        try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: code)
    }

    /// 单个目标房间的处理结果。
    private struct TargetResults: Sendable {
        /// 目标房间在命令中的下标。
        let index: Int
        /// 与源消息顺序对应的结果；未完成项为 `nil`。
        let results: [V2ForwardMessageResult?]
        /// 是否存在仍未完成的源消息。
        var pending: Bool = false
        /// 未完成项中是否存在已暂停的投递。
        var paused: Bool = false
    }
}

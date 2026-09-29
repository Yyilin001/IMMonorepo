import IMV2ServerContracts
import Foundation
import IMV2Core

/// 转发消息服务。
///
/// 多目标转发刻意被设计为一串相互独立的持久化「源消息-目标房间」对：
/// 某个目标不可用不会丢弃已经成功的目标；持久化的目标客户端消息标识使每个组合都能在
/// 操作记录与常规消息接受事务之间发生崩溃时安全重试。
public struct V2ForwardMessagesService: V2OwnerValidatedForwardMessagesHandling {
    private var ownerRoutes: [RoomID: V2RoomShardRoute]?
    private let persistence: any V2ForwardPersistence
    private let writeStore: any V2OwnerValidatedForwardMessageWriteStore
    private let capacityProfile: V2CapacityProfile
    private let limits: V2MessageCommandLimits
    private let acceptanceIDs: V2AcceptanceIDFactory
    private let maximumTargetConcurrency: Int
    private let now: @Sendable () -> Date

    /// 组合持久化端口、写存储与转发参数。
    ///
    /// - Parameters:
    ///   - persistence: 执行来源读取与操作记录的持久化端口。
    ///   - writeStore: 目标房间的写入存储。
    ///   - capacityProfile: 本次使用的容量档位。
    ///   - limits: 消息命令限制。
    ///   - acceptanceIDs: 接受标识生成器。
    ///   - maximumTargetConcurrency: 目标房间并发上限，需大于零，默认 4。
    ///   - now: 可注入的当前时刻读取函数。
    ///
    /// 并发上限非正时直接失败，避免出现无界并发。
    package init(persistence: any V2ForwardPersistence, writeStore: any V2OwnerValidatedForwardMessageWriteStore, capacityProfile: V2CapacityProfile, limits: V2MessageCommandLimits, acceptanceIDs: V2AcceptanceIDFactory = .init(), maximumTargetConcurrency: Int = 4, now: @escaping @Sendable () -> Date = Date.init) {
        precondition(maximumTargetConcurrency > 0)
        self.persistence = persistence; self.writeStore = writeStore; self.capacityProfile = capacityProfile; self.limits = limits; self.acceptanceIDs = acceptanceIDs; self.maximumTargetConcurrency = maximumTargetConcurrency; self.now = now
    }

    /// 按已校验的房间归属执行转发。
    ///
    /// 涉及的全部房间都必须出现在归属集合中，否则按归属变更处理；
    /// 归属集合会被裁剪为本次命令涉及的范围后再执行转发。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起转发的用户。
    ///   - command: 转发命令。
    ///   - ownerRoutes: 本次涉及房间的已选定归属。
    /// - Returns: 转发结果列表。
    /// - Throws: 任一房间缺少归属时抛出 ``V2RoomOwnerFenceError/ownerChanged``。
    public func forwardOwnerValidated(actorUserID: UserID, command: V2ForwardMessagesCommand,
        ownerRoutes: [RoomID: V2RoomShardRoute]) async throws -> [V2ForwardMessageResult] {
        let rooms = Set(command.sources.map(\.roomID) + command.targetRoomIDs)
        guard rooms.allSatisfy({ ownerRoutes[$0] != nil }) else { throw V2RoomOwnerFenceError.ownerChanged }
        var scoped = self
        scoped.ownerRoutes = ownerRoutes.filter { rooms.contains($0.key) }
        return try await scoped.forward(actorUserID: actorUserID, command: command)
    }

    /// 执行一次转发。
    ///
    /// 流程为：先读取既有操作结果以支持幂等重放，再读取源消息内容，
    /// 然后按目标房间并发处理并汇总结果。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起转发的用户。
    ///   - command: 转发命令。
    /// - Returns: 与源消息和目标房间组合对应的结果列表。
    /// - Throws: 源消息不可用、权限不足或持久化失败时抛出。
    public func forward(actorUserID: UserID, command: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult] {
        let priorResults = try await persistence.replayedResults(
            actor: actorUserID,
            operation: command.operationID,
            sources: command.sources,
            targets: command.targetRoomIDs, ownerRoutes: ownerRoutes
        )
        let sources = try await persistence.readSources(
            references: command.sources,
            actorUserID: actorUserID, ownerRoutes: ownerRoutes
        )
        let targetCount = command.targetRoomIDs.count
        var ordered = Array<V2ForwardMessageResult?>(
            repeating: nil,
            count: command.sourceMessageIDs.count * targetCount
        )

        try await withThrowingTaskGroup(
            of: ForwardTargetResults.self,
            returning: Void.self
        ) { group in
            var nextTargetIndex = 0
            let initialCount = min(maximumTargetConcurrency, targetCount)
            for _ in 0..<initialCount {
                let index = nextTargetIndex
                nextTargetIndex += 1
                let target = command.targetRoomIDs[index]
                group.addTask {
                    try await forward(
                        actorUserID: actorUserID,
                        operationID: command.operationID,
                        target: target,
                        targetIndex: index,
                        sources: sources,
                        priorResults: priorResults
                    )
                }
            }
            while let targetResults = try await group.next() {
                for (sourceIndex, result) in targetResults.results.enumerated() {
                    ordered[(sourceIndex * targetCount) + targetResults.targetIndex] = result
                }
                if nextTargetIndex < targetCount {
                    let index = nextTargetIndex
                    nextTargetIndex += 1
                    let target = command.targetRoomIDs[index]
                    group.addTask {
                        try await forward(
                            actorUserID: actorUserID,
                            operationID: command.operationID,
                            target: target,
                            targetIndex: index,
                            sources: sources,
                            priorResults: priorResults
                        )
                    }
                }
            }
        }
        guard ordered.allSatisfy({ $0 != nil }) else {
            throw V2ForwardStoreError.corrupt
        }
        return ordered.compactMap { $0 }
    }

    private func forward(
        actorUserID: UserID,
        operationID: MessageForwardOperationID,
        target: RoomID,
        targetIndex: Int,
        sources: [ForwardSource],
        priorResults: [ForwardPairKey: V2ForwardMessageResult]
    ) async throws -> ForwardTargetResults {
        var results: [V2ForwardMessageResult] = []
        results.reserveCapacity(sources.count)
        for source in sources {
            try Task.checkCancellation()
            if let replayed = priorResults[.init(source: source.messageID, target: target)] {
                results.append(replayed)
                continue
            }
            switch source.outcome {
            case .unavailable(let errorCode):
                results.append(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: errorCode))
            case .content(let content):
                do {
                    let clientID = try await persistence.clientMessageID(actor: actorUserID, operation: operationID, source: source.messageID, target: target, sourceRoomID: source.reference.roomID, sourceRevision: content.sourceRevision, ownerRoutes: ownerRoutes)
                    let request = try V2SendMessageCommand(roomID: target, senderUserID: actorUserID, clientMessageID: clientID, text: content.text, media: content.media, entities: content.entities, forwardedFrom: .init(messageID: source.messageID, senderUserID: content.senderUserID, sourceRevision: content.sourceRevision), limits: limits)
                    let acceptedAt = now()
                    guard v2PostgresTimestampCanEncode(acceptedAt) else { throw V2ForwardStoreError.corrupt }
                    let prepared = V2RoomWriteRequest(command: request, capacityProfile: capacityProfile,
                        identifiers: try acceptanceIDs.make(at: acceptedAt), now: acceptedAt)
                    let outcome: V2SendMessageOutcome
                    if let ownerRoutes {
                        guard let sourceRoute = ownerRoutes[source.reference.roomID], let targetRoute = ownerRoutes[target]
                        else { throw V2RoomOwnerFenceError.ownerChanged }
                        outcome = try await writeStore.acceptForwardOwnerValidated(request: prepared,
                            sourceRoomID: source.reference.roomID, sourceOwnerRoute: sourceRoute, targetOwnerRoute: targetRoute)
                    } else {
                        outcome = try await writeStore.accept(command: request, capacityProfile: capacityProfile,
                            identifiers: prepared.identifiers, now: acceptedAt)
                    }
                    switch outcome {
                    case .accepted, .idempotent:
                        guard let message = outcome.acceptanceReceipt else { throw V2ForwardStoreError.corrupt }
                        try await persistence.markResult(actor: actorUserID, operation: operationID, source: source.messageID, target: target, sourceRoomID: source.reference.roomID, message: message.messageID, ownerRoutes: ownerRoutes)
                        results.append(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: message.messageID, roomSequence: message.roomSequence, errorCode: nil))
                    case .idempotencyConflict: results.append(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: "IDEMPOTENCY_CONFLICT"))
                    case .denied: results.append(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: "DIRECT_MESSAGE_RESTRICTED"))
                    case .rateLimited: results.append(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: "RATE_LIMITED"))
                    case .unavailable: results.append(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: "UNAVAILABLE"))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    results.append(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: forwardErrorCode(error)))
                }
            }
        }
        return .init(targetIndex: targetIndex, results: results)
    }


}

private struct ForwardTargetResults: Sendable { let targetIndex: Int; let results: [V2ForwardMessageResult] }
private func forwardErrorCode(_ error: Error) -> String {
    switch error {
    case V2ForwardStoreError.sourceRevisionConflict: "IDEMPOTENCY_CONFLICT"
    case V2ForwardStoreError.notVisible: "NOT_FOUND"
    case V2RoomWriteStoreError.actorNotEligible: "FORBIDDEN"
    case V2RoomWriteStoreError.roomNotFound: "NOT_FOUND"
    case V2MediaStoreError.mediaUnavailable, V2MediaStoreError.mediaExpired,
         V2MediaStoreError.invalidStateTransition: "MEDIA_UNAVAILABLE"
    default: "UNAVAILABLE"
    }
}

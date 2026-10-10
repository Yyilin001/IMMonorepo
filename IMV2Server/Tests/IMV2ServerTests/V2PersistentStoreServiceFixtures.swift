// Test-only conveniences for exercising persistent domain stores.
import Foundation
import IMV2Core
import IMV2ActorContracts
@testable import IMV2ServerApplication
import IMV2ServerContracts

public struct V2MessageEditService: Sendable {
    private let store: any V2MessageEditStore
    private let capacityProfile: V2CapacityProfile
    private let identifiers: V2MessageEditIDFactory
    private let now: @Sendable () -> Date
    private let maximumTextUTF8Bytes: Int

    /// 创建编辑服务。
    ///
    /// - Parameters:
    ///   - store: 编辑持久化边界。
    ///   - capacityProfile: 本次部署使用的容量档位。
    ///   - maximumTextUTF8Bytes: 编辑后正文允许的最大 UTF-8 字节数。
    ///   - identifiers: 标识工厂，默认使用随机 UUID。
    ///   - now: 服务端时钟，默认取当前时间。
    public init(store: any V2MessageEditStore, capacityProfile: V2CapacityProfile, maximumTextUTF8Bytes: Int, identifiers: V2MessageEditIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.capacityProfile = capacityProfile; self.maximumTextUTF8Bytes = maximumTextUTF8Bytes
        self.identifiers = identifiers; self.now = now
    }

    /// 执行一次消息编辑。
    ///
    /// - Parameter request: 已认证的编辑请求。
    /// - Returns: 编辑处理结果。
    /// - Throws: 存储拒绝或持久化失败时抛出。
    public func edit(_ request: V2AuthenticatedMessageEdit) async throws -> V2MessageEditOutcome {
        let eventID = try identifiers.make()
        return try await store.edit(
            command: .init(roomID: request.roomID, actorUserID: request.actorUserID, operationID: request.operationID, messageID: request.messageID, expectedMessageRevision: request.expectedMessageRevision, text: request.text, maximumUTF8Bytes: maximumTextUTF8Bytes),
            capacityProfile: capacityProfile, eventID: eventID, now: now()
        )
    }
}

public struct V2MessageWithdrawalService: Sendable {
    private let store: any V2MessageWithdrawalStore
    private let capacityProfile: V2CapacityProfile
    private let identifiers: V2MessageWithdrawalIDFactory
    private let now: @Sendable () -> Date

    /// 组合撤回存储与运行参数。
    ///
    /// - Parameters:
    ///   - store: 实际执行撤回的存储实现。
    ///   - capacityProfile: 固定的容量档位。
    ///   - identifiers: 事件标识生成器。
    ///   - now: 可注入的当前时刻读取函数。
    public init(store: any V2MessageWithdrawalStore, capacityProfile: V2CapacityProfile, identifiers: V2MessageWithdrawalIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.capacityProfile = capacityProfile
        self.identifiers = identifiers
        self.now = now
    }

    /// 撤回一条已认证用户可见的消息。
    ///
    /// - Parameter request: 已认证的撤回请求。
    /// - Returns: 撤回结果；标识与授时由本方法补齐。
    /// - Throws: 标识生成失败，或存储判定无权限、修订冲突、持久化失败时抛出。
    public func withdraw(_ request: V2AuthenticatedMessageWithdrawal) async throws -> V2MessageWithdrawalOutcome {
        let eventID = try identifiers.make()
        return try await store.withdraw(
            command: .init(roomID: request.roomID, actorUserID: request.actorUserID, operationID: request.operationID, messageID: request.messageID, expectedMessageRevision: request.expectedMessageRevision),
            capacityProfile: capacityProfile,
            eventID: eventID,
            now: now()
        )
    }
}

public struct V2MessageReactionService: Sendable {
    private let store: any V2MessageReactionStore
    private let capacityProfile: V2CapacityProfile
    private let identifiers: V2MessageReactionIDFactory
    private let now: @Sendable () -> Date

    /// 创建表态服务。
    ///
    /// - Parameters:
    ///   - store: 表态持久化边界。
    ///   - capacityProfile: 本次部署使用的容量档位。
    ///   - identifiers: 标识工厂，默认使用随机 UUID。
    ///   - now: 服务端时钟，默认取当前时间。
    public init(store: any V2MessageReactionStore, capacityProfile: V2CapacityProfile, identifiers: V2MessageReactionIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.capacityProfile = capacityProfile; self.identifiers = identifiers; self.now = now
    }

    /// 执行一次消息表态变更。
    ///
    /// - Parameter request: 已认证的表态请求。
    /// - Returns: 表态处理结果。
    /// - Throws: 存储拒绝或持久化失败时抛出。
    public func change(_ request: V2AuthenticatedMessageReaction) async throws -> V2MessageReactionOutcome {
        let eventID = try identifiers.make()
        return try await store.change(command: .init(roomID: request.roomID, actorUserID: request.actorUserID, operationID: request.operationID, messageID: request.messageID, reaction: request.reaction, action: request.action), capacityProfile: capacityProfile, eventID: eventID, now: now())
    }
}

public struct V2GroupCapabilitiesService: Sendable {
    private let store: any V2GroupCapabilitiesStore
    private let capacityProfile: V2CapacityProfile
    private let identifiers: V2GroupCapabilitiesIDFactory
    private let now: @Sendable () -> Date
    /// 组合群能力存储与运行参数。
    ///
    /// - Parameters:
    ///   - store: 实际执行变更的存储实现。
    ///   - capacityProfile: 固定的容量档位，服务内不会逐次调整。
    ///   - identifiers: 事件标识生成器。
    ///   - now: 可注入的当前时刻读取函数。
    public init(store: any V2GroupCapabilitiesStore, capacityProfile: V2CapacityProfile, identifiers: V2GroupCapabilitiesIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) { self.store = store; self.capacityProfile = capacityProfile; self.identifiers = identifiers; self.now = now }

    /// 设置群置顶消息。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 置顶消息命令。
    /// - Returns: 变更结果；标识与授时由本方法补齐。
    /// - Throws: 标识生成失败，或存储判定无权限、状态冲突、持久化失败时抛出。
    public func setPinnedMessage(actorUserID: UserID, command: V2PinnedMessageCommand) async throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage> { let eventID = try identifiers.make(); return try await store.setPinnedMessage(actorUserID: actorUserID, command: command, capacityProfile: capacityProfile, eventID: eventID, now: now()) }

    /// 设置群公告。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 群公告命令。
    /// - Returns: 变更结果；标识与授时由本方法补齐。
    /// - Throws: 标识生成失败，或存储判定无权限、状态冲突、持久化失败时抛出。
    public func setAnnouncement(actorUserID: UserID, command: V2GroupAnnouncementCommand) async throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement> { let eventID = try identifiers.make(); return try await store.setAnnouncement(actorUserID: actorUserID, command: command, capacityProfile: capacityProfile, eventID: eventID, now: now()) }

    /// 设置角色权限。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 角色权限命令。
    /// - Returns: 变更结果；标识与授时由本方法补齐。
    /// - Throws: 标识生成失败，或存储判定无权限、修订冲突、持久化失败时抛出。
    public func setRolePermissions(actorUserID: UserID, command: V2GroupRolePermissionsCommand) async throws -> V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange> { let eventID = try identifiers.make(); return try await store.setRolePermissions(actorUserID: actorUserID, command: command, capacityProfile: capacityProfile, eventID: eventID, now: now()) }

    /// 调整成员角色。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 成员角色命令。
    /// - Returns: 变更结果；标识与授时由本方法补齐。
    /// - Throws: 标识生成失败，或存储判定目标非成员、无权限、持久化失败时抛出。
    public func changeMemberRole(actorUserID: UserID, command: V2GroupMemberRoleCommand) async throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange> { let eventID = try identifiers.make(); return try await store.changeMemberRole(actorUserID: actorUserID, command: command, capacityProfile: capacityProfile, eventID: eventID, now: now()) }
}

public struct V2CrossOwnerForwardService: V2CrossOwnerForwarding {
    private let sources: [String: V2ForwardSourceEndpoint]
    private let now: @Sendable () -> Date
    /// 组合各源归属的存储端点。
    ///
    /// - Parameters:
    ///   - sources: 源分片标识到存储端点的映射。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Throws: 映射为空或含纯空白分片标识时抛出
    ///   ``V2ForwardDeliveryError/invalidConfiguration``。
    public init(sources: [String: V2ForwardSourceEndpoint], now: @escaping @Sendable () -> Date = Date.init) throws {
        guard !sources.isEmpty, sources.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw V2ForwardDeliveryError.invalidConfiguration }
        self.sources = sources; self.now = now
    }

    /// 提交一次跨归属转发并返回当前可见状态。
    ///
    /// 源端准备阶段的领域错误会被映射为稳定的错误码结果，而不是抛给调用方；容量不足同样按
    /// 未完成返回。若持久化回执已经是终态则直接返回；否则查询投递任务是否已暂停。
    ///
    /// - Parameters:
    ///   - actor: 发起转发的用户。
    ///   - operation: 转发的幂等操作标识。
    ///   - source: 源消息引用。
    ///   - sourceRoute: 源房间的已选定归属。
    ///   - target: 目标房间。
    ///   - targetRoute: 目标房间的已选定归属。
    /// - Returns: 终态结果或仍在等待的状态。
    /// - Throws: 源分片未配置时抛出 ``V2RoomShardStorageRegistryError/unknownShardID``；
    ///   回执处于非法中间态时抛出 ``V2ForwardExportError/corruptPersistenceState``。
    public func forward(actor: UserID, operation: MessageForwardOperationID, source: V2ForwardMessageReference,
                        sourceRoute: V2RoomShardRoute, target: RoomID, targetRoute: V2RoomShardRoute) async throws -> V2CrossOwnerForwardOutcome {
        guard let endpoint = sources[sourceRoute.shardID] else { throw V2RoomShardStorageRegistryError.unknownShardID }
        func failure(_ code: String) throws -> V2CrossOwnerForwardOutcome {
            .completed(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: code))
        }
        func terminal(_ result: V2ForwardImportOutcome) throws -> V2CrossOwnerForwardOutcome {
            switch result {
            case .accepted(let id, let sequence):
                return .completed(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: id, roomSequence: sequence, errorCode: nil))
            case .rejected(let code): return try failure(code)
            case .pending: throw V2ForwardExportError.corruptPersistenceState
            }
        }
        let export: V2ForwardExport
        do {
            if let result = try await endpoint.receipts.terminalStatus(actor: actor, operation: operation, source: source, target: target) {
                return try terminal(result)
            }
            switch try await endpoint.exports.prepareForDelivery(actorUserID: actor, operationID: operation, source: source,
                sourceRoute: sourceRoute, targetRoomID: target, targetRoute: targetRoute, now: now()) {
            case .export(let prepared): export = prepared
            case .terminal(let result): return try terminal(result)
            }
        } catch V2ForwardExportError.sourceUnavailable { return try failure("NOT_FOUND")
        } catch V2ForwardExportError.sourceChanged { return try failure("SOURCE_CHANGED")
        } catch V2ForwardExportError.mediaUnavailable { return try failure("MEDIA_UNAVAILABLE")
        } catch V2ForwardExportError.idempotencyConflict { return try failure("IDEMPOTENCY_CONFLICT")
        } catch V2ForwardExportError.invalidRequest { return try failure("INVALID_ARGUMENT")
        } catch V2ForwardExportError.capacityExceeded { return .pending(paused: false) }
        if let result = try await endpoint.receipts.status(exportID: export.intent.exportID) {
            return try terminal(result)
        }
        return .pending(paused: try await endpoint.jobs.isPaused(exportID: export.intent.exportID))
    }
}

public struct V2ForwardImportEndpoint: V2ForwardExportDelivering {
    private let inbox: any V2ForwardTerminalReceiptReading
    private let write: any V2ForwardExportImporting
    private let media: (any V2ForwardMediaImportRunning)?
    private let profile: V2CapacityProfile
    private let limits: V2MessageCommandLimits
    private let now: @Sendable () -> Date

    /// 组合目标归属的收件箱、写存储与可选媒体导入工作器。
    ///
    /// - Parameters:
    ///   - inbox: 目标归属的持久化收件箱。
    ///   - write: 目标归属的房间写存储。
    ///   - media: 媒体导入工作器；为 `nil` 时媒体类转发无法完成。
    ///   - capacityProfile: 目标归属的容量档位。
    ///   - limits: 消息命令限制。
    ///   - now: 可注入的当前时刻读取函数。
    public init(inbox: any V2ForwardTerminalReceiptReading, write: any V2ForwardExportImporting,
                media: (any V2ForwardMediaImportRunning)? = nil, capacityProfile: V2CapacityProfile,
                limits: V2MessageCommandLimits, now: @escaping @Sendable () -> Date = Date.init) {
        self.inbox = inbox; self.write = write; self.media = media
        profile = capacityProfile; self.limits = limits; self.now = now
    }

    /// 投递一次转发导出，必要时先完成媒体导入再重试接受。
    ///
    /// 接受结果仍为待处理时返回 `nil`；只有收件箱中存在与本次导出完全一致的终态回执时
    /// 才返回回执，回执不匹配视为投递失败。
    ///
    /// - Parameter export: 本次投递的转发导出。
    /// - Returns: 终态回执；导出尚未进入终态时返回 `nil`。
    /// - Throws: 任务已取消时抛出 `CancellationError`；未配置媒体工作器时抛出
    ///   ``V2ForwardDeliveryError/targetUnavailable``；媒体导入被暂停时抛出
    ///   ``V2ForwardDeliveryError/mediaPaused``；回执与导出不一致时抛出
    ///   ``V2ForwardDeliveryError/receiptMismatch``。
    public func deliver(_ export: V2ForwardExport) async throws -> V2ForwardTerminalReceipt? {
        try Task.checkCancellation()
        var outcome = try await accept(export)
        if outcome == .pending(.media) {
            guard let media else { throw V2ForwardDeliveryError.targetUnavailable }
            switch try await media.runOnce(exportID: export.intent.exportID) {
            case .ready, .rejected: outcome = try await accept(export)
            case .paused: throw V2ForwardDeliveryError.mediaPaused
            case .idle, .retryScheduled, .superseded: return nil
            }
        }
        if case .pending = outcome { return nil }
        guard let receipt = try await inbox.terminalReceipt(exportID: export.intent.exportID), receipt.matches(export)
        else { throw V2ForwardDeliveryError.receiptMismatch }
        return receipt
    }

    /// 以同一授时与标识工厂执行一次转发接受。
    ///
    /// - Parameter export: 本次接受的转发导出。
    /// - Returns: 目标归属给出的导入结果。
    /// - Throws: 任务已取消或写存储拒绝时抛出。
    private func accept(_ export: V2ForwardExport) async throws -> V2ForwardImportOutcome {
        try Task.checkCancellation()
        let time = now()
        return try await write.importForwardExport(export, capacityProfile: profile, limits: limits,
                                                   identifiers: V2AcceptanceIDFactory().make(at: time), now: time)
    }
}

public struct V2ResourceMigrationService: Sendable {
    let store: any V2ResourceMigrationPort
    let registry: V2ResourceStorageRegistry
    let maximumBytes: Int64
    let allocate: @Sendable (V2StorageBinding) throws -> V2StoredObjectReference
    public init(store: any V2ResourceMigrationPort, registry: V2ResourceStorageRegistry, maximumBytes: Int64,
                allocate: @escaping @Sendable (V2StorageBinding) throws -> V2StoredObjectReference) throws {
        guard maximumBytes > 0 else { throw V2ResourceProviderError.configurationInvalid }
        self.store=store; self.registry=registry; self.maximumBytes=maximumBytes; self.allocate=allocate
    }
    public func prepare(_ request: V2ResourceMigrationRequest) async throws -> V2ResourceMigrationStatus {
        _ = try registry.storage(for: request.targetBinding)
        return try await store.prepare(request, maximumBytes: maximumBytes, allocate: { source in
            _ = try registry.storage(for: source.reference.binding)
            return try allocate(request.targetBinding)
        })
    }
    public func resume(_ operationID: UUID) async throws -> V2ResourceMigrationStatus {
        guard let claim = try await store.claim(operationID) else { return try await store.status(operationID) }
        do {
            try Task.checkCancellation()
            let expected = claim.status.destination
            let destination = try registry.storage(for: expected.reference.binding)
            let facts: V2StoredObjectFacts
            do {
                facts = try await destination.inspect(expected.reference)
            } catch V2ResourceProviderError.notFound {
                let input = claim.status.source
                let source = try registry.storage(for: input.reference.binding)
                guard try await source.inspect(input.reference) == input else { throw V2ResourceProviderError.integrityMismatch }
                facts = try await destination.write(expected.reference, byteCount: expected.byteCount, sha256: expected.sha256,
                                                     bytes: source.read(input.reference))
            }
            guard facts == expected else { throw V2ResourceProviderError.integrityMismatch }
            try Task.checkCancellation()
            try await store.publish(claim, observed: facts)
        } catch {
            // Unknown writes keep their identity and both holds. A failed bookkeeping
            // attempt is recovered after the existing claim expires.
            try? await store.retry(claim)
            throw error
        }
        return try await store.status(operationID)
    }
    /// One bounded maintenance pass. Per-operation failures remain retryable and
    /// are returned to the owner for metrics/logging; they do not erase the job.
    public func recover(limit: Int = 16) async throws -> (switched: [UUID], retrying: [UUID]) {
        let operations = try await store.recoverable(limit: limit)
        var switched: [UUID] = [], retrying: [UUID] = []
        for operation in operations {
            try Task.checkCancellation()
            do { _ = try await resume(operation); switched.append(operation) }
            catch is CancellationError { throw CancellationError() }
            catch { retrying.append(operation) }
        }
        return (switched, retrying)
    }
}

public struct V2ForwardSourceEndpoint: Sendable {
    /// 源端转发导出存储。
    let exports: any V2ForwardExportPreparing
    /// 源端回执查询存储。
    let receipts: any V2ForwardReceiptReading
    /// 源端投递任务存储。
    let jobs: any V2ForwardDeliveryStatusReading

    /// 组合源归属的三类存储。
    ///
    /// - Parameters:
    ///   - exports: 转发导出存储。
    ///   - receipts: 回执查询存储。
    ///   - jobs: 投递任务存储。
    public init(exports: any V2ForwardExportPreparing, receipts: any V2ForwardReceiptReading, jobs: any V2ForwardDeliveryStatusReading) {
        self.exports = exports; self.receipts = receipts; self.jobs = jobs
    }
}

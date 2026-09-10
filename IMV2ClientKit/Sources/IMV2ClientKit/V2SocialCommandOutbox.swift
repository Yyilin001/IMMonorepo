import Foundation
import IMV2Core

/// 待处理社交命令的种类。
public enum V2PendingSocialCommandKind: String, Equatable, Sendable { case relationship, userBlock, strangerMessagePreference, userAddPreference, readReceiptPreference }

/// 客户端的待处理社交命令。
///
/// 每一条都只允许携带与其种类匹配的字段组合，构造时会逐项校验，避免出现语义含混的命令。
public struct V2PendingSocialCommand: Equatable, Sendable {
    /// 命令状态。
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    public let operationID: String
    public let kind: V2PendingSocialCommandKind
    public let targetUserID: UserID?
    public let relationshipAction: V2RelationshipAction?
    public let blockAction: V2UserBlockAction?
    public let strangerPermission: V2StrangerMessagePermission?
    public let userAddPermission: V2UserAddPermission?
    public let allowsDirectReadReceipts: Bool?
    public let allowsGroupReadReceipts: Bool?
    public let state: State
    public let attemptCount: Int
    public let nextAttemptAt: Date
    public let terminalCode: String?

    /// 构造并校验命令。
    ///
    /// 关系与拉黑命令必须携带目标用户与对应动作；三项目标无关的偏好命令不得携带目标用户；
    /// 回执偏好必须同时给出私聊与群聊两个开关。已拒绝状态必须带终态错误码，
    /// 其余状态不得携带错误码。
    ///
    /// - Parameters:
    ///   - operationID: 幂等操作标识，需为合法 UUID 字符串。
    ///   - kind: 命令种类。
    ///   - targetUserID: 目标用户。
    ///   - relationshipAction: 关系动作。
    ///   - blockAction: 拉黑动作。
    ///   - strangerPermission: 陌生人消息权限。
    ///   - userAddPermission: 被添加好友权限。
    ///   - allowsDirectReadReceipts: 是否允许私聊回执。
    ///   - allowsGroupReadReceipts: 是否允许群回执。
    ///   - state: 命令状态。
    ///   - attemptCount: 已尝试次数，需非负。
    ///   - nextAttemptAt: 下次尝试时刻。
    ///   - terminalCode: 终态错误码。
    /// - Throws: 标识非法、尝试次数为负或字段组合与种类不符时抛出
    ///   ``V2ClientCommandError/commandConflict``。
    public init(operationID: String, kind: V2PendingSocialCommandKind, targetUserID: UserID?, relationshipAction: V2RelationshipAction?, blockAction: V2UserBlockAction?, strangerPermission: V2StrangerMessagePermission?, userAddPermission: V2UserAddPermission? = nil, allowsDirectReadReceipts: Bool? = nil, allowsGroupReadReceipts: Bool? = nil, state: State, attemptCount: Int, nextAttemptAt: Date, terminalCode: String?) throws {
        let hasValidPayload: Bool
        switch kind {
        case .relationship: hasValidPayload = targetUserID != nil && relationshipAction != nil && blockAction == nil && strangerPermission == nil && userAddPermission == nil && allowsDirectReadReceipts == nil && allowsGroupReadReceipts == nil
        case .userBlock: hasValidPayload = targetUserID != nil && relationshipAction == nil && blockAction != nil && strangerPermission == nil && userAddPermission == nil && allowsDirectReadReceipts == nil && allowsGroupReadReceipts == nil
        case .strangerMessagePreference: hasValidPayload = targetUserID == nil && relationshipAction == nil && blockAction == nil && strangerPermission != nil && userAddPermission == nil && allowsDirectReadReceipts == nil && allowsGroupReadReceipts == nil
        case .userAddPreference: hasValidPayload = targetUserID == nil && relationshipAction == nil && blockAction == nil && strangerPermission == nil && userAddPermission != nil && allowsDirectReadReceipts == nil && allowsGroupReadReceipts == nil
        case .readReceiptPreference: hasValidPayload = targetUserID == nil && relationshipAction == nil && blockAction == nil && strangerPermission == nil && userAddPermission == nil && allowsDirectReadReceipts != nil && allowsGroupReadReceipts != nil
        }
        let hasValidTerminalState = state == .rejected ? terminalCode != nil : terminalCode == nil
        guard UUID(uuidString: operationID) != nil, attemptCount >= 0, hasValidPayload, hasValidTerminalState
        else { throw V2ClientCommandError.commandConflict }
        self.operationID = operationID; self.kind = kind; self.targetUserID = targetUserID; self.relationshipAction = relationshipAction; self.blockAction = blockAction; self.strangerPermission = strangerPermission; self.userAddPermission = userAddPermission; self.allowsDirectReadReceipts = allowsDirectReadReceipts; self.allowsGroupReadReceipts = allowsGroupReadReceipts; self.state = state; self.attemptCount = attemptCount; self.nextAttemptAt = nextAttemptAt; self.terminalCode = terminalCode
    }
}

/// 本地社交命令发件箱存储能力。
public protocol V2LocalSocialCommandStore: Sendable {
    /// 直接入队一条社交命令。
    ///
    /// - Parameter command: 待入队命令。
    /// - Throws: 持久化失败时抛出。
    func enqueue(_ command: V2PendingSocialCommand) async throws

    /// 入队命令；等价的全局偏好或关系意图在待处理期间保留同一操作标识。
    ///
    /// 即使应用重启，同一次意图仍沿用原标识。
    ///
    /// - Parameter command: 待入队命令。
    /// - Returns: 实际入队或复用的条目。
    /// - Throws: 持久化失败时抛出。
    func enqueueOrReusePendingSocialCommand(_ command: V2PendingSocialCommand) async throws -> V2PendingSocialCommand

    /// 取出下一条已到发送时间的命令。
    ///
    /// - Parameter now: 当前时刻。
    /// - Returns: 待发送命令；没有可发送项时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func nextReadySocialCommand(now: Date) async throws -> V2PendingSocialCommand?

    /// 标记社交命令已被确认。
    ///
    /// - Parameter operationID: 操作标识。
    /// - Throws: 持久化失败时抛出。
    func markSocialCommandAcknowledged(operationID: String) async throws

    /// 安排社交命令稍后重试。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - nextAttemptAt: 下次尝试时刻。
    /// - Throws: 持久化失败时抛出。
    func scheduleSocialCommandRetry(operationID: String, nextAttemptAt: Date) async throws

    /// 以终态错误码拒绝社交命令。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - code: 服务端返回的稳定错误码。
    /// - Throws: 持久化失败时抛出。
    func rejectSocialCommand(operationID: String, code: String) async throws
}

/// 单次社交命令刷新的结果。
public enum V2SocialCommandFlushResult: Equatable, Sendable { case idle, acknowledged(String), retryScheduled(String), rejected(String, code: String) }

/// 全局社交命令的持久化重试边界。
///
/// 服务端响应只证明命令已被接受；本地读模型的事实来源仍是独立投递的同步投影。
public actor V2SocialCommandOutboxEngine {
    private let flushFlight = V2CommandFlushFlight<V2SocialCommandFlushResult>()

    private let store: any V2LocalSocialCommandStore
    private let socialTransport: any V2ClientSocialRelationshipTransport
    private let directTransport: any V2ClientDirectMessagingTransport
    private let readReceiptTransport: (any V2ClientReadReceiptTransport)?
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private let retryDelay: TimeInterval

    /// 组合存储与各传输实现。
    ///
    /// - Parameters:
    ///   - store: 本地发件箱存储。
    ///   - socialTransport: 关系与拉黑传输实现。
    ///   - directTransport: 私聊偏好传输实现。
    ///   - readReceiptTransport: 回执偏好传输实现；未提供时该类命令会判定为意外响应。
    ///   - makeUUID: 操作标识生成方式。
    ///   - now: 可注入的当前时刻读取函数。
    ///   - retryDelay: 默认重试延迟秒数，需大于零，默认 1 秒。
    public init(store: any V2LocalSocialCommandStore, socialTransport: any V2ClientSocialRelationshipTransport, directTransport: any V2ClientDirectMessagingTransport, readReceiptTransport: (any V2ClientReadReceiptTransport)? = nil, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) {
        precondition(retryDelay > 0); self.store = store; self.socialTransport = socialTransport; self.directTransport = directTransport; self.readReceiptTransport = readReceiptTransport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay
    }

    /// 入队一次好友关系变更。
    ///
    /// - Parameters:
    ///   - targetUserID: 目标用户。
    ///   - action: 关系动作。
    /// - Returns: 入队或复用后的条目。
    /// - Throws: 命令构造失败或持久化失败时抛出。
    @discardableResult public func enqueueRelationship(targetUserID: UserID, action: V2RelationshipAction) async throws -> V2PendingSocialCommand { try await enqueue(kind: .relationship, target: targetUserID, relationship: action, block: nil, permission: nil) }

    /// 入队一次用户拉黑变更。
    ///
    /// - Parameters:
    ///   - targetUserID: 目标用户。
    ///   - action: 拉黑动作。
    /// - Returns: 入队或复用后的条目。
    /// - Throws: 命令构造失败或持久化失败时抛出。
    @discardableResult public func enqueueUserBlock(targetUserID: UserID, action: V2UserBlockAction) async throws -> V2PendingSocialCommand { try await enqueue(kind: .userBlock, target: targetUserID, relationship: nil, block: action, permission: nil) }

    /// 入队一次陌生人消息偏好变更。
    ///
    /// - Parameter permission: 目标权限。
    /// - Returns: 入队或复用后的条目。
    /// - Throws: 命令构造失败或持久化失败时抛出。
    @discardableResult public func enqueueStrangerMessagePermission(_ permission: V2StrangerMessagePermission) async throws -> V2PendingSocialCommand { try await enqueue(kind: .strangerMessagePreference, target: nil, relationship: nil, block: nil, permission: permission) }

    /// 入队一次被添加好友偏好变更。
    ///
    /// - Parameter permission: 目标权限。
    /// - Returns: 入队或复用后的条目。
    /// - Throws: 命令构造失败或持久化失败时抛出。
    @discardableResult public func enqueueUserAddPermission(_ permission: V2UserAddPermission) async throws -> V2PendingSocialCommand { try await enqueue(kind: .userAddPreference, target: nil, relationship: nil, block: nil, permission: nil, userAddPermission: permission) }

    /// 入队一次已读回执偏好变更。
    ///
    /// - Parameters:
    ///   - allowsDirect: 是否允许私聊回执。
    ///   - allowsGroup: 是否允许群回执。
    /// - Returns: 入队或复用后的条目。
    /// - Throws: 命令构造失败或持久化失败时抛出。
    @discardableResult public func enqueueReadReceiptPreferences(allowsDirect: Bool, allowsGroup: Bool) async throws -> V2PendingSocialCommand { try await enqueue(kind: .readReceiptPreference, target: nil, relationship: nil, block: nil, permission: nil, allowsDirect: allowsDirect, allowsGroup: allowsGroup) }

    private func enqueue(kind: V2PendingSocialCommandKind, target: UserID?, relationship: V2RelationshipAction?, block: V2UserBlockAction?, permission: V2StrangerMessagePermission?, userAddPermission: V2UserAddPermission? = nil, allowsDirect: Bool? = nil, allowsGroup: Bool? = nil) async throws -> V2PendingSocialCommand {
        let command = try V2PendingSocialCommand(operationID: makeUUID().uuidString, kind: kind, targetUserID: target, relationshipAction: relationship, blockAction: block, strangerPermission: permission, userAddPermission: userAddPermission, allowsDirectReadReceipts: allowsDirect, allowsGroupReadReceipts: allowsGroup, state: .pending, attemptCount: 0, nextAttemptAt: now(), terminalCode: nil)
        return try await store.enqueueOrReusePendingSocialCommand(command)
    }

    /// 只尝试推进某一次显式界面操作所对应的命令。
    ///
    /// 更早排队的社交命令仍会排在其前面；此时返回 `nil`，让调用方报告「仍在排队」，
    /// 而不是把更早那次的结果错误归因给当前操作。
    ///
    /// - Parameter operationID: 目标操作标识。
    /// - Returns: 该操作对应的刷新结果；尚未轮到它时返回 `nil`。
    /// - Throws: 任务取消时抛出 `CancellationError`；存储失败时抛出。
    public func flushIfReady(operationID: String) async throws -> V2SocialCommandFlushResult? {
        let result = try await flushFlight.run {
            guard let command = try await self.store.nextReadySocialCommand(now: self.now()),
                  command.operationID == operationID else { return .idle }
            return try await self.flush(command)
        }
        switch result {
        case .idle: return nil
        case .acknowledged(let id), .retryScheduled(let id), .rejected(let id, _):
            return id == operationID ? result : nil
        }
    }

    /// 执行一次刷新，推进至多一条命令。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；存储失败时抛出。
    public func flushOnce() async throws -> V2SocialCommandFlushResult {
        try await flushFlight.run { try await self.flushNextReadyCommand() }
    }

    /// 取出并推进下一条已就绪命令。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；存储失败时抛出。
    private func flushNextReadyCommand() async throws -> V2SocialCommandFlushResult {
        guard let command = try await store.nextReadySocialCommand(now: now()) else { return .idle }
        return try await flush(command)
    }

    /// 按命令种类选择传输并按其结果更新本地状态。
    ///
    /// - Parameter command: 待推进的命令。
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；未配置回执传输时抛出
    ///   ``V2RealtimeTransportError/unexpectedResponse``；重试时刻不可用或存储失败时抛出。
    private func flush(_ command: V2PendingSocialCommand) async throws -> V2SocialCommandFlushResult {
        do {
            switch command.kind {
            case .relationship: _ = try await socialTransport.changeRelationship(operationID: try .init(command.operationID), targetUserID: command.targetUserID!, action: command.relationshipAction!)
            case .userBlock: _ = try await socialTransport.changeUserBlock(operationID: try .init(command.operationID), targetUserID: command.targetUserID!, action: command.blockAction!)
            case .strangerMessagePreference: _ = try await directTransport.setStrangerMessagePermission(operationID: try .init(command.operationID), permission: command.strangerPermission!)
            case .userAddPreference: _ = try await directTransport.setUserAddPermission(operationID: try .init(command.operationID), permission: command.userAddPermission!)
            case .readReceiptPreference:
                guard let readReceiptTransport else { throw V2RealtimeTransportError.unexpectedResponse }
                _ = try await readReceiptTransport.setReadReceiptPreferences(operationID: try .init(command.operationID), allowsDirectReadReceipts: command.allowsDirectReadReceipts!, allowsGroupReadReceipts: command.allowsGroupReadReceipts!)
            }
            try Task.checkCancellation()
            try await store.markSocialCommandAcknowledged(operationID: command.operationID)
            return .acknowledged(command.operationID)
        } catch is CancellationError { throw CancellationError() }
        catch let error as V2RealtimeTransportError {
            if case .server(let code, let retryable, _, _) = error, !retryable {
                try await store.rejectSocialCommand(operationID: command.operationID, code: code); return .rejected(command.operationID, code: code)
            }
            let delay: TimeInterval = { if case .server(_, _, let retryAfter, _) = error { return TimeInterval(max(retryAfter, 1)) }; return retryDelay }()
            try await store.scheduleSocialCommandRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: delay)); return .retryScheduled(command.operationID)
        } catch {
            try await store.scheduleSocialCommandRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay)); return .retryScheduled(command.operationID)
        }
    }
}

extension V2SocialCommandOutboxEngine: V2CommandFlushControlling {
    /// 暂停命令刷新。
    public func suspendCommandFlushing() async { await flushFlight.suspend() }

    /// 恢复命令刷新。
    public func resumeCommandFlushing() async { await flushFlight.resume() }
}

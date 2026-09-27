import Foundation
import IMV2Core

/// 设备本地保存的发送命令及其尝试状态。
///
/// 客户端消息标识和内容在重试间保持稳定。服务器接受结果与本地命令关联，便于在增量同步到达前校正乐观消息。
/// 此值的初始化方法仅保存字段，不验证状态组合或输入内容。
public struct V2PendingMessageCommand: Equatable, Sendable {
    /// 命令持久化阶段：等待发送、服务器已接受或终止拒绝。
    public enum State: String, Equatable, Sendable { case pending, accepted, rejected }
    /// 待发送的目标房间。
    public let roomID: RoomID
    /// 新入队时确定、重试间保持不变的客户端消息标识。
    public let clientMessageID: ClientMessageID
    /// 原始消息文本。
    public let text: String
    /// 有序媒体引用。
    public let media: [V2MediaReference]
    /// 提及目标。
    public let mentions: [V2MentionTarget]
    /// 富文本实体。
    public let entities: [V2MessageEntity]
    /// 可选回复引用。
    public let replyTo: V2MessageReplyReference?
    /// 本地命令阶段。
    public let state: State
    /// 持久化的尝试计数，由存储状态迁移维护。
    public let attemptCount: Int
    /// 允许再次选择该待处理命令的最早时间。
    public let nextAttemptAt: Date
    /// 服务器接受后返回的正式身份，未接受时为空。
    public let acceptedMessageID: MessageID?
    /// 与正式消息身份一起保存的房间位置，用于及时校正乐观消息，无需等待后续同步批次。
    public let acceptedRoomSequence: UInt64?
    /// 终止拒绝原因，非拒绝状态通常为空。
    public let terminalCode: String?

    /// 保存命令快照；本初始化方法不验证字段或状态组合。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - clientMessageID: 稳定的客户端操作身份。
    ///   - text: 消息文本。
    ///   - media: 媒体引用。
    ///   - mentions: 提及目标。
    ///   - entities: 富文本实体。
    ///   - replyTo: 回复引用。
    ///   - state: 持久化阶段。
    ///   - attemptCount: 尝试计数。
    ///   - nextAttemptAt: 重试时间。
    ///   - acceptedMessageID: 可选正式消息身份。
    ///   - acceptedRoomSequence: 可选正式房间位置。
    ///   - terminalCode: 可选终止代码。
    ///
    /// 新命令应通过发件箱入队入口完成内容校验，恢复数据的一致性由存储实现负责。
    public init(roomID: RoomID, clientMessageID: ClientMessageID, text: String, media: [V2MediaReference] = [], mentions: [V2MentionTarget] = [], entities: [V2MessageEntity] = [], replyTo: V2MessageReplyReference? = nil, state: State, attemptCount: Int, nextAttemptAt: Date, acceptedMessageID: MessageID?, acceptedRoomSequence: UInt64?, terminalCode: String?) {
        self.roomID = roomID
        self.clientMessageID = clientMessageID
        self.text = text
        self.media = media
        self.mentions = mentions
        self.entities = entities
        self.replyTo = replyTo
        self.state = state
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.acceptedMessageID = acceptedMessageID
        self.acceptedRoomSequence = acceptedRoomSequence
        self.terminalCode = terminalCode
    }
}

/// 本地发送命令的内容或状态合同错误。
public enum V2ClientCommandError: Error, Equatable, Sendable {
    /// 内容不满足入队条件，包括无文本且无媒体、媒体或提及超量及重复。
    case invalidText
    /// 相同客户端命令标识对应的内容冲突。
    case commandConflict
    /// 请求修改的命令不存在或已不处于待处理状态，具体由存储操作决定。
    case commandNotPending
}

/// 设备本地持久化发件箱的存储边界。
///
/// 命令应跨断线和同步快照恢复保留，客户端消息标识作为每次重试的稳定操作身份。
/// 实现负责原子状态迁移和避免把终态误改回待发送状态。
public protocol V2LocalCommandStore: Sendable {
    /// 持久化待发送命令。
    ///
    /// - Parameter command: 稳定身份和内容已确定的命令。
    /// - Throws: 命令内容冲突或存储错误。
    ///
    /// 成功返回应意味着命令能够在重连或进程重启后恢复。
    func enqueue(_ command: V2PendingMessageCommand) async throws
    /// 选择当前已到期的待发送命令。
    ///
    /// - Parameter now: 用于比较重试时间的当前日期。
    /// - Returns: 可处理命令，没有到期工作时返回 `nil`。
    /// - Throws: 状态读取或存储错误。
    ///
    /// 读取本身不能代替覆盖发送与完成落盘的并发控制；队列引擎使用共享刷新任务保护这段流程。
    func nextReadyMessage(now: Date) async throws -> V2PendingMessageCommand?
    /// 保存服务器接受结果并结束本地待发送状态。
    ///
    /// - Parameters:
    ///   - clientMessageID: 被接受的本地命令。
    ///   - messageID: 服务器返回的正式消息身份。
    ///   - roomSequence: 服务器接受事务确定的房间位置。
    /// - Throws: 状态、结果冲突或存储错误。
    ///
    /// 消息身份与房间位置应一起保存，不能仅以网络请求完成作为接受结果。
    func markMessageAccepted(clientMessageID: ClientMessageID, messageID: MessageID, roomSequence: UInt64) async throws
    /// 为待处理命令保存下一次可尝试时间。
    ///
    /// - Parameters:
    ///   - clientMessageID: 需要重试的稳定命令身份。
    ///   - nextAttemptAt: 已验证的下一次重试日期。
    /// - Throws: 命令状态或存储错误。
    ///
    /// 重试不能重新生成客户端消息标识或修改原始内容。
    func scheduleMessageRetry(clientMessageID: ClientMessageID, nextAttemptAt: Date) async throws
    /// 把命令记录为终止拒绝，供界面展示和显式重发处理。
    ///
    /// - Parameters:
    ///   - clientMessageID: 被拒绝的命令。
    ///   - code: 服务端或业务定义的终止代码。
    /// - Throws: 命令状态或存储错误。
    func rejectMessage(clientMessageID: ClientMessageID, code: String) async throws
}

/// 一次发件箱刷新的持久化处理结果，非空结果对应实际选择的命令。
public enum V2CommandFlushResult: Equatable, Sendable {
    /// 没有当前到期的待发送命令。
    case idle
    /// 该命令的服务器接受结果已保存到本地存储。
    case accepted(ClientMessageID)
    /// 该命令的下次重试时间已保存，尚不能视为服务器接受。
    case retryScheduled(ClientMessageID)
    /// 该命令已记录终止拒绝和原因。
    case rejected(ClientMessageID, code: String)
}

/// 实时运行时在认证重连后重放持久化命令所需的最小能力。
///
/// 接口便于注入测试实现，避免运行时和界面依赖具体发件箱 actor。
public protocol V2ClientCommandFlushing: Sendable {
    /// 处理一条到期命令并返回其结果；传播取消或无法完成处理的错误，调用方按实际命令身份关联界面。
    func flushOnce() async throws -> V2CommandFlushResult
}

/// 持久化发送命令并单飞处理到期重试的队列引擎。
///
/// 客户端命令 ID 在重试中保持不变。flush 返回的身份属于实际处理的队列项，
/// 调用方必须与当前用户操作比较，不能把旧命令结果归到新发送上。
public actor V2CommandOutboxEngine {
    /// 覆盖命令选择、传输和结果落盘的共享刷新任务，避免挂起点重入后重复发送同一队列项。
    private let flushFlight = V2CommandFlushFlight<V2CommandFlushResult>()

    /// 持久化命令及其终态和重试时间的存储。
    private let store: any V2LocalCommandStore
    /// 已认证的消息发送传输依赖。
    private let transport: any V2ClientMessageTransport
    /// 仅在新命令入队时生成客户端身份，重试复用已保存身份。
    private let makeUUID: @Sendable () -> UUID
    /// 入队、选择到期工作和安排重试使用的可注入时间来源。
    private let now: @Sendable () -> Date
    /// 非服务端指定重试错误的默认等待秒数。
    private let retryDelay: TimeInterval
    private let recovery: V2MessageOperationRecoveryController?

    /// 配置持久化发件箱与发送依赖。
    ///
    /// - Parameters:
    ///   - store: 本地命令存储。
    ///   - transport: 消息发送传输。
    ///   - makeUUID: 新命令身份来源，默认生成 UUID。
    ///   - now: 可注入时间来源。
    ///   - retryDelay: 默认重试秒数，必须大于零；实际重试日期的可表示性在安排时检查。
    ///
    /// 不在初始化时发送或入队。非正重试延迟触发前置条件失败。
    public init(store: any V2LocalCommandStore, transport: any V2ClientMessageTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1, recovery: V2MessageOperationRecoveryController? = nil) {
        precondition(retryDelay > 0)
        self.store = store
        self.transport = transport
        self.makeUUID = makeUUID
        self.now = now
        self.retryDelay = retryDelay
        self.recovery = recovery
    }

    @discardableResult
    /// 验证基本内容并持久化一条新的待发送命令。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - text: 原始文本，不执行去除首尾空白。
    ///   - media: 不超量且不重复的媒体引用。
    ///   - mentions: 不超量且不重复的提及目标。
    ///   - entities: 需符合富文本范围约束的实体。
    ///   - replyTo: 可选回复引用，最终有效性由服务端检查。
    /// - Returns: 已入队命令，初始尝试数为零，下次尝试时间为当前时间。
    /// - Throws: 基本内容、富文本实体、身份生成或存储错误。
    ///
    /// 此方法只入队，不自动刷新；成功入队不等于服务器已接受。
    public func enqueueMessage(roomID: RoomID, text: String, media: [V2MediaReference] = [], mentions: [V2MentionTarget] = [], entities: [V2MessageEntity] = [], replyTo: V2MessageReplyReference? = nil) async throws -> V2PendingMessageCommand {
        guard !text.isEmpty || !media.isEmpty,
              media.count <= V2MessageCommandLimits.maxMediaAttachments,
              Set(media).count == media.count,
              mentions.count <= V2MessageCommandLimits.maxMentions,
              Set(mentions).count == mentions.count
        else { throw V2ClientCommandError.invalidText }
        try V2RichMessageContent.validate(text: text, entities: entities)
        let command = try V2PendingMessageCommand(roomID: roomID, clientMessageID: .init(makeUUID().uuidString), text: text, media: media, mentions: mentions, entities: entities, replyTo: replyTo, state: .pending, attemptCount: 0, nextAttemptAt: now(), acceptedMessageID: nil, acceptedRoomSequence: nil, terminalCode: nil)
        try await store.enqueue(command)
        return command
    }

    /// 单飞处理下一条到期发送命令，并持久化终态或下次尝试时间。
    ///
    /// 普通可重试故障安排重试；RATE_LIMITED 在此业务中作为终止拒绝，要求用户显式重发。
    ///
    /// - Returns: 空闲、已接受、已拒绝或已安排重试，非空结果携带对应命令 ID。
    /// - Throws: 取消或无法持久化结果等错误；取消不应伪装成发送成功。
    public func flushOnce() async throws -> V2CommandFlushResult {
        try await flushFlight.run { try await self.flushNextReadyCommand() }
    }

    /// 在共享刷新任务内发送一条到期命令，并记录结果。
    ///
    /// 明确的 RATE_LIMITED 即使允许以后重试也记录为终止拒绝，要求用户显式再次发送。
    /// 其他可重试服务端错误使用至少一秒的服务端延迟；其他传输或一般错误使用默认延迟。
    /// 发送返回后先检查任务取消，再保存正式身份和房间序列。
    ///
    /// 取消直接传播，不在此安排重试；选择命令失败也直接传播。保存接受结果时的一般错误位于同一 catch 范围内，
    /// 也会尝试安排重试，因此网络接受成功与本地终态保存失败不能混为同一种结果，后续重放依赖服务端幂等。
    private func flushNextReadyCommand() async throws -> V2CommandFlushResult {
        if let result = try await recovery?.flushOnce(now: now()) { return result }
        guard let command = try await store.nextReadyMessage(now: now()) else { return .idle }
        do {
            let accepted = try await transport.sendMessage(roomID: command.roomID, clientMessageID: command.clientMessageID, text: command.text, media: command.media, mentions: command.mentions, entities: command.entities, replyTo: command.replyTo)
            try Task.checkCancellation()
            try await store.markMessageAccepted(clientMessageID: command.clientMessageID, messageID: accepted.messageID, roomSequence: accepted.roomSequence)
            return .accepted(command.clientMessageID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as V2RealtimeTransportError {
            switch error {
            case .server(let code, let retryable, let retryAfter, _):
                if code == "MEDIA_UNAVAILABLE", let recovery {
                    try await recovery.requireRecovery(command, now: now())
                    return .retryScheduled(command.clientMessageID)
                }
                // A rate-limit response is a conclusive rejection of this
                // particular send attempt. Although the server permits a
                // later request, silently replaying chat content after the
                // cooldown would surprise the sender. Keep the draft in the
                // UI and require an explicit subsequent send instead.
                if code == "RATE_LIMITED" {
                    try await store.rejectMessage(clientMessageID: command.clientMessageID, code: code)
                    return .rejected(command.clientMessageID, code: code)
                }
                if retryable {
                    try await store.scheduleMessageRetry(clientMessageID: command.clientMessageID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: TimeInterval(max(retryAfter, 1))))
                    return .retryScheduled(command.clientMessageID)
                }
                try await store.rejectMessage(clientMessageID: command.clientMessageID, code: code)
                return .rejected(command.clientMessageID, code: code)
            default:
                try await store.scheduleMessageRetry(clientMessageID: command.clientMessageID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay))
                return .retryScheduled(command.clientMessageID)
            }
        } catch {
            try await store.scheduleMessageRetry(clientMessageID: command.clientMessageID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay))
            return .retryScheduled(command.clientMessageID)
        }
    }
}

extension V2CommandOutboxEngine: V2ClientCommandFlushing {}

extension V2CommandOutboxEngine: V2CommandFlushControlling {
    /// 暂停新的刷新并请求取消当前共享任务；返回时不保证任务已完全退出。
    public func suspendCommandFlushing() async { await flushFlight.suspend() }
    /// 等待上一轮共享任务结束后恢复刷新，避免旧连接任务与新连接重复处理同一命令。
    public func resumeCommandFlushing() async { await flushFlight.resume() }
}

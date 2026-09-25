import Foundation
import IMV2ActorContracts
import IMV2Core

/// 发送取得房间轮次后只准备一次。宿主批处理器可合并这些值，
/// 同时保留令牌、生成的 ID 和服务端时刻。
public struct V2PreparedActorSend: Sendable {
    public let token: V2RoomActivationToken
    public let request: V2RoomWriteRequest
}

/// 具体的 D1 实现。房间运行时负责串行化和生命周期；
/// 每个存储都独立使用此精确令牌为 SQL 设置围栏。
public struct V2RoomMessagingExecutor: Sendable {
    public let token: V2RoomActivationToken
    private let writes: PostgresV2RoomWriteStore
    private let edits: V2MessageEditService
    private let withdrawals: V2MessageWithdrawalService
    private let reactions: V2MessageReactionService
    private let capacityProfile: V2CapacityProfile
    private let limits: V2MessageCommandLimits
    private let identifiers: V2AcceptanceIDFactory
    private let maximumEditBytes: Int
    private let now: @Sendable () -> Date

    public init(
        token: V2RoomActivationToken,
        writes: PostgresV2RoomWriteStore,
        edits: PostgresV2MessageEditStore,
        withdrawals: PostgresV2MessageWithdrawalStore,
        reactions: PostgresV2MessageReactionStore,
        capacityProfile: V2CapacityProfile,
        limits: V2MessageCommandLimits,
        maximumEditBytes: Int,
        identifiers: V2AcceptanceIDFactory = .init(),
        editIdentifiers: V2MessageEditIDFactory = .init(),
        withdrawalIdentifiers: V2MessageWithdrawalIDFactory = .init(),
        reactionIdentifiers: V2MessageReactionIDFactory = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard maximumEditBytes > 0 else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        let scope = try V2RoomActivationWriteScope(tokens: [token])
        self.token = token
        self.writes = writes.usingActivationScope(scope)
        self.edits = .init(store: edits.usingActivationScope(scope), capacityProfile: capacityProfile,
            maximumTextUTF8Bytes: maximumEditBytes, identifiers: editIdentifiers, now: now)
        self.withdrawals = .init(store: withdrawals.usingActivationScope(scope), capacityProfile: capacityProfile,
            identifiers: withdrawalIdentifiers, now: now)
        self.reactions = .init(store: reactions.usingActivationScope(scope), capacityProfile: capacityProfile,
            identifiers: reactionIdentifiers, now: now)
        self.capacityProfile = capacityProfile
        self.limits = limits
        self.identifiers = identifiers
        self.maximumEditBytes = maximumEditBytes
        self.now = now
    }

    public func prepareSend(_ value: V2ActorSendMessageWire) throws -> V2PreparedActorSend {
        guard value.roomID == token.roomID else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        let authenticated = try value.toAuthenticated(limits: limits)
        let command = try V2SendMessageCommand(roomID: authenticated.roomID,
            senderUserID: authenticated.actorUserID, clientMessageID: authenticated.clientMessageID,
            text: authenticated.text, media: authenticated.media, mentions: authenticated.mentions,
            entities: authenticated.entities, replyTo: authenticated.replyTo, limits: limits)
        let acceptedAt = now()
        return .init(token: token, request: .init(command: command, capacityProfile: capacityProfile,
            identifiers: try identifiers.make(at: acceptedAt), now: acceptedAt))
    }

    public func execute(_ command: V2RoomMessagingCommand) async throws -> V2RoomMessagingResult {
        guard command.roomID == token.roomID else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        do {
            switch command {
            case .send(let value):
                return try await executePreparedSend(prepareSend(value))
            case .edit(let value):
                return .edit(.init(try await edits.edit(value.toAuthenticated(maximumTextUTF8Bytes: maximumEditBytes))))
            case .withdraw(let value):
                return .withdraw(.init(try await withdrawals.withdraw(value.toAuthenticated())))
            case .reaction(let value):
                return .reaction(.init(try await reactions.change(value.toAuthenticated())))
            }
        } catch {
            if let failure = V2ActorMessagingErrorWire(domainError: error) { return .failure(failure) }
            // 提交结果不明、权限过期和驱动故障都不是业务结果。
            // 外围轮次必须保留相关证据。
            throw error
        }
    }

    public func executePreparedSend(_ value: V2PreparedActorSend) async throws -> V2RoomMessagingResult {
        guard value.token == token, value.request.command.roomID == token.roomID else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        let request = value.request
        do {
            return .send(.init(try await writes.accept(command: request.command,
                capacityProfile: request.capacityProfile, identifiers: request.identifiers, now: request.now)))
        } catch {
            if let failure = V2ActorMessagingErrorWire(domainError: error) { return .failure(failure) }
            throw error
        }
    }

    /// 外围房间通道已准入并排序所有发送请求。
    /// 宿主批处理器将此轮次与同一物理分片上的其他房间合并前，
    /// 准备阶段会固定生成的 ID 和服务端时刻。
    public func executeGrantedSendTurn(
        _ sends: [V2ActorSendMessageWire],
        batchDeadline: ContinuousClock.Instant,
        callDeadline: ContinuousClock.Instant = .now + .seconds(10),
        using adapter: V2ActorGrantedSendBatchAdapter
    ) async throws -> [V2RoomMessagingResult] {
        guard !sends.isEmpty else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        var prepared: [V2PreparedActorSend] = []
        var preparedIndices: [Int] = []
        var results = Array<V2RoomMessagingResult?>(repeating: nil, count: sends.count)
        for (index, send) in sends.enumerated() {
            do {
                prepared.append(try prepareSend(send))
                preparedIndices.append(index)
            } catch {
                guard let failure = V2ActorMessagingErrorWire(domainError: error) else { throw error }
                results[index] = .failure(failure)
            }
        }
        if !prepared.isEmpty {
            let accepted = try await adapter.execute(prepared,
                batchDeadline: batchDeadline, callDeadline: callDeadline)
            guard accepted.count == preparedIndices.count else { throw V2RoomCallFailure.outcomeUnknown }
            for (index, result) in zip(preparedIndices, accepted) {
                results[index] = result
            }
        }
        return try results.map { result in
            guard let result else { throw V2RoomCallFailure.outcomeUnknown }
            return result
        }
    }
}

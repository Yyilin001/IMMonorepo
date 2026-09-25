import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core

/// 传输边界保留客户端操作身份。接受 ID、服务端时刻、容量策略
/// 和所有 SQL 均由房间执行器负责。
public struct V2RoomRefMessagingClient: Sendable {
    typealias Invoke = @Sendable (V2RoomRequest, UserID, ContinuousClock.Instant) async throws -> V2RoomResponse
    private let invoke: Invoke
    private let callTimeout: V2ActorMilliseconds

    public init(directory: V2RoomDirectory, callTimeout: V2ActorMilliseconds) {
        self.init(callTimeout: callTimeout) { request, user, deadline in
            try await directory.room(request.roomID).call(request, principal: .user(user), deadline: deadline)
        }
    }

    init(callTimeout: V2ActorMilliseconds, invoke: @escaping Invoke) {
        self.callTimeout = callTimeout
        self.invoke = invoke
    }

    // 数据库准入属于物理宿主，不属于等待中的网关。
    public var managesForegroundWriteAdmission: Bool { true }
    // 网关可以发布提交后的前台提示。即使提示或响应丢失，
    // 持久化发件箱仍是权威依据。
    public var publishesCommittedGroupEvents: Bool { false }

    public func send(_ request: V2AuthenticatedSendMessage) async throws -> V2SendMessageOutcome {
        let response = try await call(.send(.init(request)), actor: request.actorUserID)
        guard case .send(let value) = response else { throw V2RoomCallFailure.outcomeUnknown }
        return try value.toDomain()
    }

    public func edit(_ request: V2AuthenticatedMessageEdit) async throws -> V2MessageEditOutcome {
        let response = try await call(.edit(.init(request)), actor: request.actorUserID)
        guard case .edit(let value) = response else { throw V2RoomCallFailure.outcomeUnknown }
        return try value.toDomain()
    }

    public func withdraw(_ request: V2AuthenticatedMessageWithdrawal) async throws -> V2MessageWithdrawalOutcome {
        let response = try await call(.withdraw(.init(request)), actor: request.actorUserID)
        guard case .withdraw(let value) = response else { throw V2RoomCallFailure.outcomeUnknown }
        return try value.toDomain()
    }

    public func change(_ request: V2AuthenticatedMessageReaction) async throws -> V2MessageReactionOutcome {
        let response = try await call(.reaction(.init(request)), actor: request.actorUserID)
        guard case .reaction(let value) = response else { throw V2RoomCallFailure.outcomeUnknown }
        return try value.toDomain()
    }

    private func call(_ command: V2RoomMessagingCommand, actor: UserID) async throws -> V2RoomMessagingResult {
        guard !Task.isCancelled else { throw V2RoomCallFailure.notAccepted(.cancelled) }
        let response = try await invoke(.messaging(command), actor, .now + callTimeout.duration)
        guard case .messaging(let result) = response else { throw V2RoomCallFailure.outcomeUnknown }
        if case .failure(let failure) = result { throw failure.domainError() }
        return result
    }
}

extension V2RoomRefMessagingClient: V2GatewaySendMessageHandling,
    V2GatewayMessageEditHandling, V2GatewayMessageWithdrawalHandling, V2GatewayMessageReactionHandling {}

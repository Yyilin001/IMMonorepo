import IMV2ServerApplication
import IMV2ServerContracts
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



    public func reactionOperation(_ command:V2MessageReactionOperationCommand) async throws -> V2MessageReactionRecoveryResult {
        try await reactionOperationCall(.reactionOperation(command),identity:command.identity,fingerprint:command.fingerprint)
    }
    public func recoverReaction(_ request:V2MessageReactionRecoveryRequest) async throws -> V2MessageReactionRecoveryResult {
        try await reactionOperationCall(.recoverReaction(request),identity:request.identity,fingerprint:request.fingerprint)
    }
    public func reactionSnapshot(roomID:RoomID,actorUserID:UserID,messageID:MessageID,reaction:String) async throws -> V2MessageReactionSnapshot {
        guard case .reactionSnapshot(let result)=try await call(.reactionSnapshot(.init(roomID:roomID,actorUserID:actorUserID,messageID:messageID,reaction:reaction)),actor:actorUserID),
              result.roomID==roomID,result.actorUserID==actorUserID,result.messageID==messageID else { throw V2RoomCallFailure.outcomeUnknown }
        return result
    }
    private func reactionOperationCall(_ command:V2RoomMessagingCommand,identity:V2OperationIdentity,fingerprint:V2OperationFingerprint) async throws -> V2MessageReactionRecoveryResult {
        guard case .reactionOperation(let result)=try await call(command,actor:identity.accountID) else { throw V2RoomCallFailure.outcomeUnknown }
        if case .receipt(let receipt)=result, !receipt.validates(identity:identity,fingerprint:fingerprint) { throw V2RoomCallFailure.outcomeUnknown }
        if case .deferred(let hint)=result, !hint.validates(identity:identity,fingerprint:fingerprint) { throw V2RoomCallFailure.outcomeUnknown }
        return result
    }
    public func sendOperation(_ command:V2MessageSendOperationCommand) async throws -> V2MessageSendOperationRecoveryResult {
        try await sendOperationCall(.sendOperation(command),identity:command.identity,fingerprint:command.fingerprint)
    }
    public func recoverSendOperation(_ request:V2MessageSendOperationRecoveryRequest) async throws -> V2MessageSendOperationRecoveryResult {
        try await sendOperationCall(.recoverSendOperation(request),identity:request.identity,fingerprint:request.fingerprint)
    }
    private func sendOperationCall(_ command:V2RoomMessagingCommand,identity:V2OperationIdentity,fingerprint:V2OperationFingerprint) async throws -> V2MessageSendOperationRecoveryResult {
        guard case .sendOperation(let result)=try await call(command,actor:identity.accountID) else { throw V2RoomCallFailure.outcomeUnknown }
        if case .receipt(let receipt)=result,!receipt.validates(identity:identity,fingerprint:fingerprint) { throw V2RoomCallFailure.outcomeUnknown }
        if case .deferred(let hint)=result,!hint.validates(identity:identity,fingerprint:fingerprint) { throw V2RoomCallFailure.outcomeUnknown }
        return result
    }

    public func editOperation(_ command:V2MessageEditOperationCommand) async throws -> V2MessageMutationRecoveryResult {
        try await mutationCall(.editOperation(command),identity:command.identity,fingerprint:command.fingerprint)
    }
    public func withdrawOperation(_ command:V2MessageWithdrawalOperationCommand) async throws -> V2MessageMutationRecoveryResult {
        try await mutationCall(.withdrawOperation(command),identity:command.identity,fingerprint:command.fingerprint)
    }
    public func recoverMutation(_ request:V2MessageMutationRecoveryRequest) async throws -> V2MessageMutationRecoveryResult {
        try await mutationCall(.recoverMutation(request),identity:request.identity,fingerprint:request.fingerprint)
    }
    private func mutationCall(_ command:V2RoomMessagingCommand,identity:V2OperationIdentity,fingerprint:V2OperationFingerprint) async throws -> V2MessageMutationRecoveryResult {
        guard case .mutation(let result)=try await call(command,actor:identity.accountID) else { throw V2RoomCallFailure.outcomeUnknown }
        if case .receipt(let receipt)=result, !receipt.validates(identity:identity,fingerprint:fingerprint) { throw V2RoomCallFailure.outcomeUnknown }
        if case .deferred(let hint)=result,!hint.validates(identity:identity,fingerprint:fingerprint) { throw V2RoomCallFailure.outcomeUnknown }
        return result
    }

    private func call(_ command: V2RoomMessagingCommand, actor: UserID) async throws -> V2RoomMessagingResult {
        try Task.checkCancellation()
        let response: V2RoomResponse
        do {
            response = try await invoke(.messaging(command), actor, .now + callTimeout.duration)
        } catch let failure as V2RoomCallFailure {
            if case .notAccepted(.cancelled) = failure { throw CancellationError() }
            throw failure
        }
        guard case .messaging(let result) = response else { throw V2RoomCallFailure.outcomeUnknown }
        if case .failure(let failure) = result { throw failure.domainError() }
        return result
    }
}

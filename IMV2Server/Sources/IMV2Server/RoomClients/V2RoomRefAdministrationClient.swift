import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core

/// 在解析前设定唯一的总截止时间，并原样传递给激活、传输和房间执行轮次。
/// 运行时重试保留原操作 ID；客户端绝不创建事件 ID 或时间戳。
struct V2RoomRefUserCaller: Sendable {
    let invoke: @Sendable (V2RoomRequest, UserID, ContinuousClock.Instant) async throws -> V2RoomResponse
    let timeout: Duration

    init(directory: V2RoomDirectory, timeout: Duration) {
        precondition(timeout > .zero)
        self.timeout = timeout
        self.invoke = { request, actor, deadline in
            try await directory.room(request.roomID).call(request, principal: .user(actor), deadline: deadline)
        }
    }

    init(timeout: Duration,
         invoke: @escaping @Sendable (V2RoomRequest, UserID, ContinuousClock.Instant) async throws -> V2RoomResponse) {
        precondition(timeout > .zero)
        self.timeout = timeout
        self.invoke = invoke
    }

    func call(_ request: V2RoomRequest, actor: UserID,
              deadline: ContinuousClock.Instant? = nil) async throws -> V2RoomResponse {
        guard request.actorUserID == actor else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        try Task.checkCancellation()
        let end = deadline ?? ContinuousClock.now.advanced(by: timeout)
        guard end > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        do {
            return try await invoke(request, actor, end)
        } catch let failure as V2RoomCallFailure {
            if case .notAccepted(.cancelled) = failure { throw CancellationError() }
            throw failure
        }
    }
}

public struct V2RoomRefAdministrationClient: Sendable,
    V2GatewayConversationCapabilitiesHandling {
    let caller: V2RoomRefUserCaller

    public init(directory: V2RoomDirectory, callTimeout: Duration = .seconds(10)) {
        self.caller = .init(directory: directory, timeout: callTimeout)
    }

    init(caller: V2RoomRefUserCaller) { self.caller = caller }

    public func admitMemberAdministration(_ intent:V2MemberAdministrationIntent) async throws -> V2MemberAdministrationAdmissionResult {
        guard case .memberAdministrationAdmission(let result)=try await command(.memberAdministrationAdmission(intent),actor:intent.actorUserID) else { throw V2RoomCallFailure.outcomeUnknown }
        if case .admitted(let context)=result { guard context.validates(intent:intent) else { throw V2RoomCallFailure.outcomeUnknown } }
        return result
    }
    public func submitMemberAdministration(_ input:V2MemberAdministrationCommand) async throws -> V2MemberAdministrationRecoveryResult {
        guard case .memberAdministrationRecovery(let result)=try await command(.memberAdministrationSubmit(input),actor:input.intent.actorUserID) else { throw V2RoomCallFailure.outcomeUnknown }
        if case .receipt(let receipt)=result { guard receipt.validates(command:input) else { throw V2RoomCallFailure.outcomeUnknown } }
        return result
    }
    public func recoverMemberAdministration(_ input:V2MemberAdministrationRecoveryRequest) async throws -> V2MemberAdministrationRecoveryResult {
        guard case .memberAdministrationRecovery(let result)=try await command(.memberAdministrationRecovery(input),actor:input.identity.accountID) else { throw V2RoomCallFailure.outcomeUnknown }
        if case .receipt(let receipt)=result { guard receipt.identity==input.identity,receipt.fingerprint==input.fingerprint else { throw V2RoomCallFailure.outcomeUnknown } }
        if case .deferred(let hint)=result { guard hint.identity==input.identity,hint.fingerprint==input.fingerprint else { throw V2RoomCallFailure.outcomeUnknown } }
        return result
    }

    public func setConversationState(actorUserID:UserID,command:V2ConversationStateCommand) async throws -> V2PersonalPreferenceReceipt {
        guard case .personalPreference(let receipt)=try await self.command(.conversationState(.init(actorUserID:actorUserID,command:command)),actor:actorUserID),
              receipt.identity == (try command.identity(actorUserID:actorUserID)),receipt.fingerprint == (try command.fingerprint(actorUserID:actorUserID)) else { throw V2RoomCallFailure.outcomeUnknown };return receipt
    }
    public func setMessageFavorite(actorUserID:UserID,command:V2MessageFavoriteCommand) async throws -> V2PersonalPreferenceReceipt {
        guard case .personalPreference(let receipt)=try await self.command(.messageFavorite(.init(actorUserID:actorUserID,command:command)),actor:actorUserID),
              receipt.identity == (try command.identity(actorUserID:actorUserID)),receipt.fingerprint == (try command.fingerprint(actorUserID:actorUserID)) else { throw V2RoomCallFailure.outcomeUnknown };return receipt
    }
    public func recoverPersonalPreference(actorUserID:UserID,request:V2PersonalPreferenceRecoveryRequest) async throws -> V2PersonalPreferenceRecoveryResult {
        guard actorUserID==request.identity.accountID else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        guard case .personalPreferenceRecovery(let result)=try await command(.personalPreferenceRecovery(.init(request:request)),actor:actorUserID) else { throw V2RoomCallFailure.outcomeUnknown }
        if case .receipt(let receipt)=result { guard receipt.identity==request.identity,receipt.fingerprint==request.fingerprint else { throw V2RoomCallFailure.outcomeUnknown } }
        guard request.action != .closeIfAbsent || result != .unresolved else { throw V2RoomCallFailure.outcomeUnknown };return result
    }

    public func recoverGroupAvatar(actorUserID: UserID, request: V2GroupAvatarRecoveryRequest,
                                    deadline: ContinuousClock.Instant? = nil) async throws -> V2GroupAvatarRecoveryResult {
        guard case .groupAvatarRecovery(let result) = try await command(
            .groupAvatarRecovery(.init(actorUserID: actorUserID, request: request)), actor: actorUserID, deadline: deadline)
        else { throw V2RoomCallFailure.outcomeUnknown }
        if case .committed(let change) = result {
            guard change.state.roomID == request.command.roomID, change.state.mediaID == request.command.mutation.mediaID,
                  change.state.revision == request.command.expectedRevision + 1 else { throw V2RoomCallFailure.outcomeUnknown }
        }
        guard request.action != .closeIfAbsent || result != .unresolved else { throw V2RoomCallFailure.outcomeUnknown }
        return result
    }

    public func setGroupAvatar(actorUserID: UserID, command: V2GroupAvatarCommand,
                               deadline: ContinuousClock.Instant? = nil) async throws -> V2GroupCapabilitiesOutcome<V2GroupAvatarChange> {
        guard case .groupAvatar(let value) = try await self.command(.groupAvatar(.init(actorUserID: actorUserID, command: command)), actor: actorUserID, deadline: deadline)
        else { throw V2RoomCallFailure.outcomeUnknown }
        switch value {
        case .applied(let change), .idempotent(let change):
            guard change.state.roomID == command.roomID, change.state.mediaID == command.mutation.mediaID,
                  change.state.revision == command.expectedRevision + 1 else { throw V2RoomCallFailure.outcomeUnknown }
        default: break
        }
        return try value.domain()
    }

    func command(_ value: V2RoomAdministrationCommand, actor: UserID,
                         deadline: ContinuousClock.Instant? = nil) async throws -> V2RoomAdministrationResult {
        guard case .administration(let result) = try await caller.call(.administration(value), actor: actor, deadline: deadline) else {
            throw V2RoomCallFailure.outcomeUnknown
        }
        if case .personalPreferenceFingerprintConflict = result { throw V2ConversationCapabilitiesStoreError.operationPayloadMismatch }
        if case .failure(let failure) = result { throw try failure.domainError() }
        return result
    }
}

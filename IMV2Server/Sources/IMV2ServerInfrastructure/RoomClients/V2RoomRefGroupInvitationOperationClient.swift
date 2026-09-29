import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

extension V2RoomRefAdministrationClient {
    public func admitGroupInvitation(_ intent: V2GroupInvitationOperationIntent,deadline:ContinuousClock.Instant? = nil) async throws -> V2GroupInvitationAdmissionResult {
        guard case .groupInvitationAdmission(let value) = try await command(.groupInvitationAdmit(intent),actor:intent.identity.accountID,deadline:deadline) else { throw V2RoomCallFailure.outcomeUnknown }
        if case .admitted(let context) = value { guard context.validates(intent:intent) else { throw V2RoomCallFailure.outcomeUnknown } }
        if case .terminal(let receipt) = value { guard receipt.validates(intent:intent) else { throw V2RoomCallFailure.outcomeUnknown } }
        return value
    }
    public func submitGroupInvitation(_ request: V2GroupInvitationExecutionRequest,deadline:ContinuousClock.Instant? = nil) async throws -> V2GroupInvitationOperationRecoveryResult {
        guard case .groupInvitationRecovery(let value) = try await command(.groupInvitationSubmit(request),actor:request.command.identity.accountID,deadline:deadline) else { throw V2RoomCallFailure.outcomeUnknown }
        try validateInvitationResult(value,intent:request.command.intent)
        return value
    }
    public func recoverGroupInvitation(_ request: V2GroupInvitationRecoveryRequest,deadline:ContinuousClock.Instant? = nil) async throws -> V2GroupInvitationOperationRecoveryResult {
        guard case .groupInvitationRecovery(let value) = try await command(.groupInvitationRecover(request),actor:request.intent.identity.accountID,deadline:deadline) else { throw V2RoomCallFailure.outcomeUnknown }
        try validateInvitationResult(value,intent:request.intent)
        return value
    }
    public func groupInvitationBaseline(_ request: V2GroupInvitationOperationBaselineQuery,deadline:ContinuousClock.Instant? = nil) async throws -> V2GroupInvitationOperationBaseline {
        guard case .administration(let result) = try await caller.call(.administrationQuery(.groupInvitationBaseline(request)),actor:request.actorUserID,deadline:deadline) else { throw V2RoomCallFailure.outcomeUnknown }
        if case .failure(let failure) = result { throw try failure.domainError() }
        guard case .groupInvitationBaseline(let value) = result,value.roomID == request.roomID else { throw V2RoomCallFailure.outcomeUnknown }
        return value
    }
}

private func validateInvitationResult(_ value: V2GroupInvitationOperationRecoveryResult,intent:V2GroupInvitationOperationIntent) throws {
    if case .receipt(let receipt) = value { guard receipt.validates(intent:intent) else { throw V2RoomCallFailure.outcomeUnknown } }
    if case .deferred(let hint) = value { guard hint.identity == intent.identity,hint.fingerprint == (try intent.fingerprint) else { throw V2RoomCallFailure.outcomeUnknown } }
}

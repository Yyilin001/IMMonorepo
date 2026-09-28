import Foundation
import IMV2ActorContracts
import IMV2Core

extension V2RoomRefAdministrationClient {
    public func admitGroupCapability(_ intent:V2GroupCapabilityIntent) async throws -> V2GroupCapabilityAdmissionResult {
        guard case .groupCapabilityAdmission(let value)=try await command(.groupCapabilityAdmit(intent),actor:intent.identity.accountID) else { throw V2RoomCallFailure.outcomeUnknown }
        if case .admitted(let admission)=value { guard admission.validates(intent:intent) else { throw V2RoomCallFailure.outcomeUnknown } }
        return value
    }
    public func submitGroupCapability(_ input:V2GroupCapabilityCommand) async throws -> V2GroupCapabilityRecoveryResult {
        guard case .groupCapabilityRecovery(let value)=try await command(.groupCapabilitySubmit(input),actor:input.identity.accountID) else { throw V2RoomCallFailure.outcomeUnknown }
        if case .receipt(let receipt)=value { guard receipt.validates(command:input) else { throw V2RoomCallFailure.outcomeUnknown } }
        if case .deferred(let hint)=value { guard hint.identity==input.identity,hint.fingerprint==(try input.fingerprint) else { throw V2RoomCallFailure.outcomeUnknown } }
        return value
    }
    public func recoverGroupCapability(_ input:V2GroupCapabilityRecoveryRequest) async throws -> V2GroupCapabilityRecoveryResult {
        guard case .groupCapabilityRecovery(let value)=try await command(.groupCapabilityRecover(input),actor:input.identity.accountID) else { throw V2RoomCallFailure.outcomeUnknown }
        if case .receipt(let receipt)=value { guard receipt.identity==input.identity,receipt.fingerprint==input.fingerprint else { throw V2RoomCallFailure.outcomeUnknown } }
        if case .deferred(let hint)=value { guard hint.identity==input.identity,hint.fingerprint==input.fingerprint else { throw V2RoomCallFailure.outcomeUnknown } }
        return value
    }
    public func pinnedBaseline(actorUserID:UserID,roomID:RoomID,messageID:MessageID) async throws -> V2PinnedMessageBaseline {
        let input=V2PinnedMessageBaselineQuery(roomID:roomID,actorUserID:actorUserID,messageID:messageID)
        guard case .administration(let result)=try await caller.call(.administrationQuery(.pinnedBaseline(input)),actor:actorUserID) else { throw V2RoomCallFailure.outcomeUnknown }
        if case .failure(let failure)=result { throw try failure.domainError() }
        guard case .pinnedBaseline(let value)=result,value.roomID==roomID,value.messageID==messageID else { throw V2RoomCallFailure.outcomeUnknown }
        return value
    }
}

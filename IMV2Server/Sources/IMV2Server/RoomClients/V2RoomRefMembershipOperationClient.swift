import Foundation
import IMV2Core
import IMV2ActorContracts

extension V2RoomRefAdministrationClient {
    public func admitMembershipOperation(_ intent:V2MembershipIntent) async throws -> V2MembershipAdmissionResult {
        guard case .membershipAdmission(let result)=try await command(.membershipAdmission(intent),actor:intent.actorUserID) else { throw V2RoomCallFailure.outcomeUnknown }
        if case .admitted(let context)=result { guard context.validates(intent:intent) else { throw V2RoomCallFailure.outcomeUnknown } }
        return result
    }
    public func submitMembershipOperation(_ input:V2MembershipOperationCommand) async throws -> V2MembershipRecoveryResult {
        guard case .membershipRecovery(let result)=try await command(.membershipSubmit(input),actor:input.intent.actorUserID) else { throw V2RoomCallFailure.outcomeUnknown }
        if case .receipt(let receipt)=result { guard receipt.validates(command:input) else { throw V2RoomCallFailure.outcomeUnknown } }
        if case .deferred(let hint)=result { guard hint.identity == (try input.identity),hint.fingerprint == (try input.fingerprint) else { throw V2RoomCallFailure.outcomeUnknown } }
        return result
    }
    public func recoverMembershipOperation(_ input:V2MembershipRecoveryRequest) async throws -> V2MembershipRecoveryResult {
        guard case .membershipRecovery(let result)=try await command(.membershipRecovery(input),actor:input.identity.accountID) else { throw V2RoomCallFailure.outcomeUnknown }
        if case .receipt(let receipt)=result { guard receipt.identity==input.identity,receipt.fingerprint==input.fingerprint else { throw V2RoomCallFailure.outcomeUnknown } }
        if case .deferred(let hint)=result { guard hint.identity==input.identity,hint.fingerprint==input.fingerprint else { throw V2RoomCallFailure.outcomeUnknown } }
        return result
    }

}

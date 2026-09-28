import Foundation
import IMV2ActorContracts
import IMV2Core

extension V2RoomRefAdministrationClient {
    public func messageModerationBaseline(_ query:V2MessageModerationBaselineQuery) async throws -> V2MessageModerationBaseline {
        guard case .administration(let result)=try await caller.call(.administrationQuery(.messageModerationBaseline(query)),actor:query.actorUserID),
              case .messageModerationBaseline(let baseline)=result,baseline.roomID==query.roomID,baseline.messageID==query.messageID else {throw V2RoomCallFailure.outcomeUnknown}
        return baseline
    }
    public func admitMessageModeration(_ intent:V2MessageModerationIntent) async throws -> V2MessageModerationAdmissionResult {
        guard case .messageModerationAdmission(let result)=try await command(.messageModerationAdmission(intent),actor:intent.actorUserID) else {throw V2RoomCallFailure.outcomeUnknown}
        switch result {
        case .admitted(let context):guard context.validates(intent:intent) else {throw V2RoomCallFailure.outcomeUnknown}
        case .terminal(let receipt):guard receipt.validates(intent:intent) else {throw V2RoomCallFailure.outcomeUnknown}
        default:break
        }
        return result
    }
    public func submitMessageModeration(_ input:V2MessageModerationCommand) async throws -> V2MessageModerationRecoveryResult {
        guard case .messageModerationRecovery(let result)=try await command(.messageModerationSubmit(input),actor:input.intent.actorUserID) else {throw V2RoomCallFailure.outcomeUnknown}
        return try verified(result,intent:input.intent)
    }
    public func recoverMessageModeration(_ input:V2MessageModerationRecoveryRequest) async throws -> V2MessageModerationRecoveryResult {
        guard case .messageModerationRecovery(let result)=try await command(.messageModerationRecovery(input),actor:input.intent.actorUserID) else {throw V2RoomCallFailure.outcomeUnknown}
        return try verified(result,intent:input.intent)
    }
    private func verified(_ result:V2MessageModerationRecoveryResult,intent:V2MessageModerationIntent) throws -> V2MessageModerationRecoveryResult {
        if case .receipt(let receipt)=result {guard receipt.validates(intent:intent) else {throw V2RoomCallFailure.outcomeUnknown}}
        if case .deferred(let hint)=result {guard hint.identity==(try intent.identity),hint.fingerprint==(try intent.fingerprint) else {throw V2RoomCallFailure.outcomeUnknown}}
        return result
    }
}

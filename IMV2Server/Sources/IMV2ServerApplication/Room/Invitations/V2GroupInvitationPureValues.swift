import Foundation
import IMV2ActorContracts
import IMV2Core
import IMV2ServerContracts

/// 来自不可变所有者回执的权威观测。请求结果可推进到终态；
/// 准入拒绝结果永不改变。
package struct V2GroupJoinOwnerSubmission: Sendable {
    package let outcome: V2GroupJoinQuotaOutcome
    package let targetRequestID: UUID?
    package let wasInserted: Bool

    package init(outcome: V2GroupJoinQuotaOutcome, targetRequestID: UUID?, wasInserted: Bool) {
        self.outcome = outcome
        self.targetRequestID = targetRequestID
        self.wasInserted = wasInserted
    }
}

package func v2GroupInvitationCreationRequest(
    _ command: V2GroupInvitationOperationCommand,
    issuer: V2GroupInviteSecretIssuer,
    policy: V2GroupInvitationPolicy,
    now: Date
) throws -> V2GroupInviteCreatePersistenceRequest {
    guard case .create(let lifetime, let uses, _) = command.intent.action else {
        throw V2GroupInvitationServiceError.invalidRequest
    }
    let operation = try GroupInviteOperationID(command.identity.operation.rawOperationID)
    let secret = try issuer.secret(actorUserID: command.identity.accountID, operationID: operation)
    let digest = issuer.digest(secret)
    let bytes = Array(digest.prefix(16))
    let id = UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
    let (duration, durationOverflow) = lifetime.multipliedReportingOverflow(by: 1_000)
    let (expiry, expiryOverflow) = command.admission.issuedAtMilliseconds.addingReportingOverflow(duration)
    guard !durationOverflow, !expiryOverflow else {
        throw V2GroupInvitationServiceError.corruptPersistenceState
    }
    let timestamps = try V2GroupInviteCreationTimestamps(
        createdAt: V2PersistenceTimestamp(unixMilliseconds: command.admission.issuedAtMilliseconds),
        expiresAt: V2PersistenceTimestamp(unixMilliseconds: expiry)
    )
    return V2GroupInviteCreatePersistenceRequest(
        inviteID: .init(uuid: id), roomID: command.intent.roomID,
        actorUserID: command.identity.accountID, operationID: operation,
        tokenDigest: digest, requestedLifetimeSeconds: Int(lifetime),
        expiresAt: timestamps.expiresAt.date,
        maximumApprovedUses: uses,
        maximumActiveInvitesPerRoom: policy.maximumActiveInvitesPerRoom,
        createdAt: timestamps.createdAt.date, evaluatedAt: now
    ).preservingTimestamps(timestamps)
}

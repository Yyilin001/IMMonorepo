import Foundation
import IMV2Core

/// Durable command identity. A replay compares the stored command before any
/// new directory or quota work; completion only marks an uncreated directory.
package protocol V2GroupInvitationCommandJournal: Sendable {
    func save(_ command: V2GroupInvitationOperationCommand) async throws
    func load(actor: UUID, operation: UUID) async throws -> V2GroupInvitationOperationCommand?
    func finishUncreatedDirectory(_ command: V2GroupInvitationOperationCommand, now: Date) async throws
}

/// The quota authority owns the applicant lock, held generation and terminal
/// decision. A lease timeout alone never releases a reserved slot.
package protocol V2GroupJoinQuotaAuthority: Sendable {
    func reserve(_ request: V2GroupJoinSubmissionPersistenceRequest, roomID: RoomID,
                 inviteID: GroupInviteID, now: Date) async throws -> V2GroupJoinQuotaReservation
    @discardableResult
    func resolve(_ intent: V2GroupJoinQuotaIntent, outcome: V2GroupJoinQuotaOutcome,
                 targetRequestID: UUID?, now: Date) async throws -> Bool
    func releaseVerifiedDecision(_ receipt: V2GroupInvitationOperationReceipt,
                                 intent: V2GroupInvitationOperationIntent, now: Date) async throws
}

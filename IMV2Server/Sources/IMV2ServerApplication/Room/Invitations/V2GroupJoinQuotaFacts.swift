import Foundation
import IMV2Core

package enum V2GroupJoinQuotaReservation: Equatable, Sendable {
    case reserved(V2GroupJoinQuotaIntent)
    case limited
}

package enum V2GroupJoinQuotaPhase: String, Codable, Sendable {
    case held, tracking, denied, terminal
}

package enum V2GroupJoinQuotaOutcome: String, Codable, Sendable {
    case pending, approved, rejected, cancelled
    case alreadyMember = "already_member"
    case unavailable, rateLimited = "rate_limited", permissionDenied = "permission_denied"

    package var phase: V2GroupJoinQuotaPhase {
        switch self {
        case .pending: .tracking
        case .approved, .rejected, .cancelled, .alreadyMember: .terminal
        case .unavailable, .rateLimited, .permissionDenied: .denied
        }
    }
    package var requiresRequest: Bool {
        switch self {
        case .pending, .approved, .rejected, .cancelled: true
        case .alreadyMember, .unavailable, .rateLimited, .permissionDenied: false
        }
    }
}

package struct V2GroupJoinQuotaIntent: Decodable, Equatable, Sendable {
    package let applicantUserID, operationID, requestID, roomID, inviteID: UUID
    package let tokenDigest: Data
    package let note: String?
    package let maximumPendingPerInvite: Int
    package let generation: Int64
    package let phase: V2GroupJoinQuotaPhase
    package let outcome: V2GroupJoinQuotaOutcome?
    package let targetRequestID: UUID?
    package let createdAt, attemptCreatedAt, updatedAt, nextCheckAt: Date
    package let leaseToken: UUID?
    package let leaseUntil: Date?
    package let attemptCount: Int64

    enum CodingKeys: String, CodingKey {
        case nextCheckAt = "next_check_at", leaseToken = "lease_token", leaseUntil = "lease_until", attemptCount = "attempt_count"
        case applicantUserID = "applicant_user_id", operationID = "operation_id", requestID = "request_id"
        case roomID = "room_id", inviteID = "invite_id", tokenDigest = "token_digest", note
        case maximumPendingPerInvite = "maximum_pending_per_invite", generation, phase, outcome
        case targetRequestID = "target_request_id", createdAt = "created_at", attemptCreatedAt = "attempt_created_at", updatedAt = "updated_at"
    }
}

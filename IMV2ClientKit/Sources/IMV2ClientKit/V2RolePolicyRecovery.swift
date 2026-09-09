import Foundation
import IMV2Core

/// Issued only by the local store after capturing its account, membership and
/// sync-generation fences. This token identifies local intent; it is not
/// proof of server authorization or of a completed network read.
public struct V2RolePolicyRecoveryRequest: Equatable, Sendable {
    public let roomID: RoomID
    let requestID: UUID
    let installationBinding: String
    let userID: UserID
    let membershipRevision: Int64
    let membershipSourceEventID: String
    let generation: Int64
    let attemptCount: Int
}

public enum V2RolePolicyRecoveryError: Error, Equatable, Sendable {
    case accountUnavailable
    case roomUnauthorized
    case invalidLimit
    case invalidBaseline
    case invalidDate
}

public enum V2RolePolicyRecoveryDisposition: Sendable {
    case retry(at: Date)
    case pause
    case unauthorized
}

public enum V2ClientRolePolicyRecoveryState: Equatable, Sendable {
    case unavailable
    case waitingForSynchronization
    case needed
    case pending(nextAttemptAt: Date)
    case paused
    case ready
}

/// The visible policies and recovery state come from one SQLite snapshot.
public struct V2ClientGroupRolePolicyState: Equatable, Sendable {
    public let policies: [V2ClientGroupRolePolicy]
    public let recovery: V2ClientRolePolicyRecoveryState

    public init(policies: [V2ClientGroupRolePolicy], recovery: V2ClientRolePolicyRecoveryState) {
        self.policies = policies
        self.recovery = recovery
    }
}

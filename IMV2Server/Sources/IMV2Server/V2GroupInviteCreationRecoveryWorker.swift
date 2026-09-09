import Foundation

public struct V2GroupInviteCreationRecoveryClaim: Sendable {
    public let intent: V2GroupInviteCreationIntent
    public let claimToken: UUID
    public let attemptCount: Int
}

public enum V2GroupInviteCreationRecoveryFailure: String, Sendable {
    case dependencyUnavailable = "dependency_unavailable"
    case ownerChanged = "owner_changed"
    case rateLimited = "rate_limited"
    case permissionDenied = "permission_denied"
    case creationExpired = "creation_expired"
    case conflictingEvidence = "conflicting_evidence"
}

public protocol V2GroupInviteCreationRecoveryStoring: Sendable {
    func claim(limit: Int, now: Date, lease: TimeInterval, maximumActiveInvitesPerRoom: Int) async throws -> [V2GroupInviteCreationRecoveryClaim]
    /// Only the live claim can defer/pause. Foreground finalize may have already
    /// completed the job atomically with directory publication.
    func fail(_ claim: V2GroupInviteCreationRecoveryClaim, reason: V2GroupInviteCreationRecoveryFailure, retryAt: Date?, now: Date) async throws -> Bool
}

public protocol V2GroupInviteCreationResuming: Sendable {
    func resumeCreation(_ intent: V2GroupInviteCreationIntent, now: Date) async throws
}

public struct V2GroupInviteCreationRecoveryReport: Equatable, Sendable {
    public var attempted = 0
    public var completed = 0
    public var deferred = 0
    public var paused = 0
    public var lostClaim = 0
}

/// Claims one job at a time so a slow owner does not exhaust the leases of
/// unrelated jobs waiting in a local batch. Multiple account processes safely
/// share the queue. No plaintext invite secret is needed by recovery.
public struct V2GroupInviteCreationRecoveryWorker: Sendable {
    private let jobs: any V2GroupInviteCreationRecoveryStoring
    private let invitations: any V2GroupInviteCreationResuming
    private let policy: V2GroupInvitationPolicy
    private let now: @Sendable () -> Date

    public init(jobs: any V2GroupInviteCreationRecoveryStoring, invitations: any V2GroupInviteCreationResuming, policy: V2GroupInvitationPolicy = .standard, now: @escaping @Sendable () -> Date = Date.init) {
        self.jobs = jobs; self.invitations = invitations; self.policy = policy; self.now = now
    }

    public func runOnce(limit: Int = 8) async throws -> V2GroupInviteCreationRecoveryReport {
        guard (1...100).contains(limit) else { throw V2GroupInviteDirectoryError.invalidRequest }
        var report = V2GroupInviteCreationRecoveryReport()
        for _ in 0..<limit {
            try Task.checkCancellation()
            guard let claim = try await jobs.claim(limit: 1, now: now(), lease: 60, maximumActiveInvitesPerRoom: policy.maximumActiveInvitesPerRoom).first else { break }
            report.attempted += 1
            let resumedAt = now()
            // Validate the attempt clock before business-error classification.
            // Preparing the resumed intent needs a representable recovery date.
            guard v2PostgresFutureTimestamp(now: resumedAt, interval: 30) != nil else {
                throw V2GroupInviteDirectoryError.invalidRequest
            }
            do {
                try Task.checkCancellation()
                try await invitations.resumeCreation(claim.intent, now: resumedAt)
                report.completed += 1
            } catch is CancellationError {
                // An interrupted/uncertain owner call retains the lease; the
                // next process will retry the exact durable creation operation.
                throw CancellationError()
            } catch {
                let reason = classify(error)
                let current = now()
                guard v2PostgresTimestampCanEncode(current) else { throw V2GroupInviteDirectoryError.invalidRequest }
                let shouldPause = reason == .permissionDenied || reason == .creationExpired || reason == .conflictingEvidence
                // Transient dependencies recover automatically, however long
                // they were unavailable. Saturated attempts cannot overflow.
                let delay = min(900.0, 15.0 * pow(2.0, Double(min(max(1, claim.attemptCount), 7) - 1)))
                let retryAt: Date?
                if shouldPause { retryAt = nil }
                else {
                    guard let deadline = v2PostgresFutureTimestamp(now: current, interval: delay) else {
                        throw V2GroupInviteDirectoryError.invalidRequest
                    }
                    retryAt = deadline
                }
                let recorded = try await jobs.fail(claim, reason: reason, retryAt: retryAt, now: current)
                if !recorded { report.lostClaim += 1 }
                else if shouldPause { report.paused += 1 }
                else { report.deferred += 1 }
            }
        }
        return report
    }

    private func classify(_ error: any Error) -> V2GroupInviteCreationRecoveryFailure {
        if let error = error as? V2GroupInvitationServiceError {
            switch error {
            case .permissionDenied: return .permissionDenied
            case .creationExpired: return .creationExpired
            case .ownerChanged: return .ownerChanged
            case .rateLimited: return .rateLimited
            case .invalidRequest, .conflict, .corruptPersistenceState: return .conflictingEvidence
            case .invalidConfiguration, .roomNotFound, .inviteNotFound, .requestNotFound: return .dependencyUnavailable
            }
        }
        if error is V2GroupInviteDirectoryError { return .conflictingEvidence }
        return .dependencyUnavailable
    }
}

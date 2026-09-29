@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Synchronization
import Testing

@Suite("V2 invite creation recovery worker")
struct V2GroupInviteCreationRecoveryWorkerTests {
    @Test("Retry delay clamps attempts before arithmetic", arguments: [Int.min, -1, 0, 1, 2, 7, 1000, Int.max])
    func retryAttemptBounds(attempt: Int) async throws {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let jobs = InviteRecoveryClockJobs(attempt: attempt)
        let resumer = InviteRecoveryClockResumer()
        let worker = V2GroupInviteCreationRecoveryWorker(jobs: jobs, invitations: resumer, now: { base })
        let report = try await worker.runOnce(limit: 1)
        #expect(report.attempted == 1 && report.deferred == 1 && report.paused == 0)
        let failure = try #require(await jobs.failure)
        let expectedDelay: Double = attempt <= 1 ? 15 : attempt == 2 ? 30 : 900
        #expect(failure.retryAt == base.addingTimeInterval(expectedDelay))
        #expect(failure.now == base && failure.reason == .dependencyUnavailable)
    }

    @Test("Invalid attempt clocks never become permanent business failures", arguments: ["resume", "retry", "pause"])
    func invalidAttemptClocks(phase: String) async throws {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        var dates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
        if phase != "pause" { dates.append(Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)) }
        for bad in dates {
            let jobs = InviteRecoveryClockJobs(attempt: 1)
            let resumer = InviteRecoveryClockResumer(shouldPause: phase == "pause")
            let clock = InviteRecoveryTestClock(phase == "resume" ? [base, bad] : [base, base, bad])
            let worker = V2GroupInviteCreationRecoveryWorker(jobs: jobs, invitations: resumer, now: { clock.now() })
            await #expect(throws: V2GroupInviteDirectoryError.invalidRequest) { _ = try await worker.runOnce(limit: 1) }
            #expect(await jobs.failure == nil)
            #expect(await resumer.calls == (phase == "resume" ? 0 : 1))
        }
    }
}

private actor InviteRecoveryClockJobs: V2GroupInviteCreationRecoveryStoring {
    struct Failure: Sendable {
        let reason: V2GroupInviteCreationRecoveryFailure
        let retryAt: Date?
        let now: Date
    }
    private let attempt: Int
    private(set) var failure: Failure?
    init(attempt: Int) { self.attempt = attempt }
    func claim(limit: Int, now: Date, lease: TimeInterval, maximumActiveInvitesPerRoom: Int) async throws -> [V2GroupInviteCreationRecoveryClaim] {
        let request = V2GroupInviteCreatePersistenceRequest(inviteID: .init(uuid: UUID()), roomID: .init(uuid: UUID()), actorUserID: .init(uuid: UUID()), operationID: .init(uuid: UUID()), tokenDigest: Data(repeating: 0x45, count: 32), requestedLifetimeSeconds: 3600, expiresAt: now.addingTimeInterval(3600), maximumApprovedUses: 5, maximumActiveInvitesPerRoom: maximumActiveInvitesPerRoom, createdAt: now)
        return [.init(intent: .init(request: request, isReady: false), claimToken: UUID(), attemptCount: attempt)]
    }
    func fail(_ claim: V2GroupInviteCreationRecoveryClaim, reason: V2GroupInviteCreationRecoveryFailure, retryAt: Date?, now: Date) async throws -> Bool {
        failure = .init(reason: reason, retryAt: retryAt, now: now)
        return true
    }
}

private actor InviteRecoveryClockResumer: V2GroupInviteCreationResuming {
    private let shouldPause: Bool
    private(set) var calls = 0
    init(shouldPause: Bool = false) { self.shouldPause = shouldPause }
    func resumeCreation(_ intent: V2GroupInviteCreationIntent, now: Date) async throws {
        calls += 1
        if shouldPause { throw V2GroupInvitationServiceError.permissionDenied }
        throw InviteRecoveryClockFailure.unavailable
    }
}
private enum InviteRecoveryClockFailure: Error { case unavailable }

private final class InviteRecoveryTestClock: Sendable {
    private let state: Mutex<([Date], Int)>
    init(_ dates: [Date]) { state = .init((dates, 0)) }
    func now() -> Date {
        state.withLock { state in
            let date = state.0[min(state.1, state.0.count - 1)]
            state.1 += 1
            return date
        }
    }
}

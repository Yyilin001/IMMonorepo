import IMV2ServerApplication
import IMV2ServerContracts
import Synchronization

/// Per actual owner transaction. No SQL identity or row payload crosses this trace.
enum V2OwnerAdmissionHandoffObservation {
    @TaskLocal static var current: V2OwnerAdmissionHandoffTrace?
}

final class V2OwnerAdmissionHandoffTrace: Sendable {
    private struct Candidate: Sendable {
        let path: V2SendOperationAdmissionPath
        let resultReadyAt: ContinuousClock.Instant
        let validatedAt: ContinuousClock.Instant
    }
    private struct State: Sendable {
        var resultReadyAt: ContinuousClock.Instant?
        var candidate: Candidate?
        var dispatched = false
    }
    private let state = Mutex(State())

    func beginQuota() {
        state.withLock { state in
            state.resultReadyAt = nil
            state.candidate = nil
        }
    }

    // Called on the SQL future's event loop before its mapped future settles.
    func resultReady() {
        let now = ContinuousClock().now
        state.withLock { state in
            state.resultReadyAt = now
            state.candidate = nil
        }
    }

    // Called only after the awaited rows decode and pass every quota guard.
    func validated(path: V2SendOperationAdmissionPath) {
        let now = ContinuousClock().now
        state.withLock { state in
            guard let ready = state.resultReadyAt, !state.dispatched else { return }
            state.candidate = Candidate(path: path, resultReadyAt: ready, validatedAt: now)
        }
    }

    /// COMMIT API dispatch, not a socket-write or successful-COMMIT timestamp.
    func willDispatchCommit(metrics: V2SendOperationBatchMetrics) {
        let now = ContinuousClock().now
        let candidate = state.withLock { state -> Candidate? in
            guard !state.dispatched, let candidate = state.candidate else { return nil }
            state.dispatched = true
            return candidate
        }
        guard let candidate else { return }
        metrics.recordOwnerAdmissionHandoff(path: candidate.path,
            resultReadyToValidated: candidate.resultReadyAt.duration(to: candidate.validatedAt),
            validatedToCommitDispatch: candidate.validatedAt.duration(to: now))
    }
}

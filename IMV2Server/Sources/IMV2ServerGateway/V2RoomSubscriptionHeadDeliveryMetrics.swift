import Synchronization

/// Process-local counters and stage durations: no connection, room, user or fence labels.
/// Socket stages include every scoped notification (Ready/control as well as H).
public final class V2RoomSubscriptionHeadDeliveryMetrics: Sendable {
    public enum Stage: String, CaseIterable, Sendable {
        case headOffered, headOfferRefused, headRetained
        case headPermitExpiredWithUnsentHead
        case headEnqueueRefused, headEnqueueAccepted
        case headAlreadySubmitted, headRecoveringRefused, headReadyRefused
        case socketClosed, socketNotWritable, socketResponseBusy
        case socketPermitRejected, socketEnqueued, socketWriteFailed
        case progressNoInterest, progressNoRoom, progressAuthorityNotReady
        case progressSessionUnavailable, progressNoMember, progressSocketNotReady, progressReady
        case acquisitionQueued, acquisitionAdmitted
        case acquisitionDeadlineExpired, acquisitionInvalidGrant, acquisitionSuperseded
        case acquisitionSessionNotReady, acquisitionRouteInvalid, acquisitionSubscribeReplyInvalid
        case acquisitionResetFenceInvalid, acquisitionResetReplyInvalid, acquisitionGrantFenceInvalid
        case acquisitionInstallRefused, acquisitionActivateReplyInvalid, acquisitionUnsubscribeReplyInvalid
        // One detailed counter per refused installation, in addition to the
        // coordinator's aggregate acquisitionInstallRefused counter.
        case installInvalidFence, installHostMismatch, installInvalidService
        case installSessionMissing, installSessionReplaced, installSessionServiceMismatch
        case installSessionNotReady, installCatalogClosed
        case installHistoryCapacity, installResetRequired, installRoomCapacity
        case installStateClosed, installRetiredFence, installServiceMismatch
        case installPreviousSessionRetired, installDifferentSession
        case installFenceNotNewer, installActivationNotNewer, installReservationRejected
        case acquisitionRemoteUnavailable, acquisitionRemoteOverloaded, acquisitionRemoteStale
        case acquisitionRemoteUnauthorized, acquisitionRemoteInvalidRequest
        case acquisitionCallDeadlineExceeded, acquisitionCallOverloaded, acquisitionCallCapacityExhausted, acquisitionCallUnavailable
        case acquisitionCallInvalidRequest, acquisitionCallStale, acquisitionCallOutcomeUnknown, acquisitionOtherFailure
    }
    public struct Snapshot: Sendable {
        public let counters: [Stage: UInt64]
        public let phases: [Kind: [Phase: PhaseSnapshot]]
        public subscript(_ stage: Stage) -> UInt64 { counters[stage, default: 0] }
    }
    public enum Kind: String, CaseIterable, Sendable { case foreground, repair }
    public enum Phase: String, CaseIterable, Sendable {
        case queue, taskStart, slot, resolve, subscribe, reset, install, activate
    }
    public enum Outcome: String, CaseIterable, Sendable {
        case success, deadline, unavailable, outcomeUnknown, refused, cancelled, superseded, invalid, other
    }
    public struct PhaseSnapshot: Sendable {
        public fileprivate(set) var active: UInt64 = 0
        public fileprivate(set) var completed: UInt64 = 0
        public fileprivate(set) var seconds: Double = 0
        public fileprivate(set) var maximumSeconds: Double = 0
        public fileprivate(set) var outcomes: [Outcome: UInt64] = [:]
    }
    public struct Measurement: Sendable {
        fileprivate let kind: Kind
        fileprivate let phase: Phase
        fileprivate let started: ContinuousClock.Instant
    }
    public static let shared = V2RoomSubscriptionHeadDeliveryMetrics()
    private let counters = Mutex<[Stage: UInt64]>([:])
    private let phases = Mutex<[Kind: [Phase: PhaseSnapshot]]>([:])
    public init() {}
    public func record(_ stage: Stage) {
        counters.withLock { value in
            let old = value[stage, default: 0]
            value[stage] = old == .max ? .max : old + 1
        }
    }
    public func begin(_ phase: Phase, kind: Kind = .foreground, at instant: ContinuousClock.Instant) -> Measurement {
        phases.withLock { $0[kind, default: [:]][phase, default: .init()].active += 1 }
        return .init(kind: kind, phase: phase, started: instant)
    }
    public func finish(_ measurement: Measurement, at instant: ContinuousClock.Instant, outcome: Outcome) {
        let duration = measurement.started.duration(to: instant).components
        let seconds = max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
        phases.withLock {
            var phase = $0[measurement.kind]?[measurement.phase] ?? .init()
            precondition(phase.active > 0)
            phase.active -= 1
            phase.completed += 1
            phase.seconds += seconds
            phase.maximumSeconds = max(phase.maximumSeconds, seconds)
            phase.outcomes[outcome, default: 0] += 1
            $0[measurement.kind, default: [:]][measurement.phase] = phase
        }
    }
    public func snapshot() -> Snapshot {
        let counters = counters.withLock { $0 }
        return phases.withLock { .init(counters: counters, phases: $0) }
    }
}

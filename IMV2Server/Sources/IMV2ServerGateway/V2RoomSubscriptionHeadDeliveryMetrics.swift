import Synchronization

/// Process-local counters only: no connection, room, user or fence labels.
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
        case acquisitionRemoteUnavailable, acquisitionRemoteOverloaded, acquisitionRemoteStale
        case acquisitionRemoteUnauthorized, acquisitionRemoteInvalidRequest
        case acquisitionCallDeadlineExceeded, acquisitionCallOverloaded, acquisitionCallUnavailable
        case acquisitionCallInvalidRequest, acquisitionCallStale, acquisitionCallOutcomeUnknown, acquisitionOtherFailure
    }
    public struct Snapshot: Sendable {
        public let counters: [Stage: UInt64]
        public subscript(_ stage: Stage) -> UInt64 { counters[stage, default: 0] }
    }
    public static let shared = V2RoomSubscriptionHeadDeliveryMetrics()
    private let counters = Mutex<[Stage: UInt64]>([:])
    public init() {}
    public func record(_ stage: Stage) {
        counters.withLock { value in
            let old = value[stage, default: 0]
            value[stage] = old == .max ? .max : old + 1
        }
    }
    public func snapshot() -> Snapshot { counters.withLock { .init(counters: $0) } }
}

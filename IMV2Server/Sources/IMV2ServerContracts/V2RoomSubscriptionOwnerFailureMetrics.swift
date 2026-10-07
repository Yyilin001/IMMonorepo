import Synchronization

/// Fixed reasons before distinct Owner failures map to wire overload.
/// Contains no room, user, connection, or request identity.
public final class V2RoomSubscriptionOwnerFailureMetrics: Sendable {
    public enum Reason: String, CaseIterable, Sendable {
        case busy, catchUpRequired, overloaded, pumpBindRefused
    }
    public static let shared = V2RoomSubscriptionOwnerFailureMetrics()
    private let counters = Mutex<[Reason: UInt64]>([:])
    public init() {}
    public func record(_ reason: Reason) {
        counters.withLock { value in
            let old = value[reason, default: 0]
            value[reason] = old == .max ? .max : old + 1
        }
    }
    public func snapshot() -> [Reason: UInt64] { counters.withLock { $0 } }
}

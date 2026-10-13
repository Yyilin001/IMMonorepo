import Foundation
import Synchronization
import IMV2ActorContracts

/// Shared by room and socket projections. Expiry closes this generation and
/// cannot be undone by a late heartbeat. A new open requires a new generation.
public final class V2RoomDeliverySessionGate: Sendable {
    public static let heartbeatTimeout: Duration = .seconds(10)
    public let session: V2RoomDeliverySession
    public let serviceID: String
    private struct State: Sendable {
        var deadline: ContinuousClock.Instant
        var sequence: UInt64
        var retired = false
    }
    private let state: Mutex<State>
    public init(session: V2RoomDeliverySession, serviceID: String,
                openedAt: ContinuousClock.Instant, sequence: UInt64) {
        self.session = session; self.serviceID = serviceID
        state = .init(.init(deadline: openedAt + Self.heartbeatTimeout, sequence: sequence))
    }
    public func isReady(at now: ContinuousClock.Instant) -> Bool {
        state.withLock { value in
            if now >= value.deadline { value.retired = true }
            return !value.retired
        }
    }
    public func heartbeat(sequence: UInt64, at now: ContinuousClock.Instant) -> Bool {
        state.withLock { value in
            guard !value.retired, now < value.deadline else { value.retired = true; return false }
            guard sequence > value.sequence else { return true }
            value.sequence = sequence; value.deadline = now + Self.heartbeatTimeout
            return true
        }
    }
    public func retire() { state.withLock { $0.retired = true } }
}

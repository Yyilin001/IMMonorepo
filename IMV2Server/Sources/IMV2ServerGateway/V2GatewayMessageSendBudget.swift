import IMV2ServerApplication
import IMV2ServerContracts
import Synchronization
/// Bounds payload bytes and retained request lifetimes across all connections.
/// Small wire payloads still own async contexts, RPC state and response writes.
/// The connection owner enforces its own request-count and byte limits first.
public final class V2GatewayMessageSendBudget: Sendable {
    private let maximumBytes: Int
    private let maximumRequests: Int
    private struct State: Sendable {
        var reservedBytes = 0
        var inFlightRequests = 0
        var peakInFlightRequests = 0
        var peakReservedBytes = 0
        var rejections: [V2GatewayMessageSendRejectionReason: UInt64] = [:]
    }
    // Admission and release are bounded counter operations. They must not
    // queue network reads or completed ACKs behind a process-wide Actor.
    private let state = Mutex(State())

    public init(maximumBytes: Int, maximumRequests: Int = 1_024) {
        precondition(maximumBytes > 0 && maximumRequests > 0)
        self.maximumBytes = maximumBytes
        self.maximumRequests = maximumRequests
    }

    func reserve(_ bytes: Int) -> Bool {
        state.withLock { value in
            guard value.inFlightRequests < maximumRequests else {
                value.rejections[.processCount, default: 0] &+= 1
                return false
            }
            guard bytes > 0, bytes <= maximumBytes - value.reservedBytes else {
                value.rejections[.processBytes, default: 0] &+= 1
                return false
            }
            value.reservedBytes += bytes
            value.inFlightRequests += 1
            value.peakInFlightRequests = max(value.peakInFlightRequests, value.inFlightRequests)
            value.peakReservedBytes = max(value.peakReservedBytes, value.reservedBytes)
            return true
        }
    }

    func release(_ bytes: Int) {
        state.withLock { value in
            precondition(bytes > 0 && value.reservedBytes >= bytes)
            precondition(value.inFlightRequests > 0)
            value.reservedBytes -= bytes
            value.inFlightRequests -= 1
        }
    }

    func recordRejection(_ reason: V2GatewayMessageSendRejectionReason) {
        state.withLock { $0.rejections[reason, default: 0] &+= 1 }
    }

    public func metricsSnapshot() -> V2GatewayMessageSendMetricsSnapshot {
        state.withLock {
            .init(inFlightRequests: $0.inFlightRequests, reservedBytes: $0.reservedBytes,
                  peakInFlightRequests: $0.peakInFlightRequests, peakReservedBytes: $0.peakReservedBytes,
                  rejections: $0.rejections, maximumInFlightRequests: maximumRequests)
        }
    }

    func inFlightBytes() -> Int { state.withLock { $0.reservedBytes } }
}

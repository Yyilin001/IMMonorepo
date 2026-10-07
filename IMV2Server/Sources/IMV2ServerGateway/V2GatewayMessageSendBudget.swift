import IMV2ServerApplication
import IMV2ServerContracts
/// Bounds memory held by message-send requests across all gateway connections.
/// The connection owner enforces its own request-count and byte limits first.
public actor V2GatewayMessageSendBudget {
    private let maximumBytes: Int
    private var reservedBytes = 0
    private var inFlightRequests = 0
    private var peakInFlightRequests = 0
    private var peakReservedBytes = 0
    private var rejections: [V2GatewayMessageSendRejectionReason: UInt64] = [:]

    public init(maximumBytes: Int) {
        precondition(maximumBytes > 0)
        self.maximumBytes = maximumBytes
    }

    func reserve(_ bytes: Int) -> Bool {
        guard bytes > 0, bytes <= maximumBytes - reservedBytes else {
            recordRejection(.processBytes)
            return false
        }
        reservedBytes += bytes
        inFlightRequests += 1
        peakInFlightRequests = max(peakInFlightRequests, inFlightRequests)
        peakReservedBytes = max(peakReservedBytes, reservedBytes)
        return true
    }

    func release(_ bytes: Int) {
        precondition(bytes > 0 && reservedBytes >= bytes)
        precondition(inFlightRequests > 0)
        reservedBytes -= bytes
        inFlightRequests -= 1
    }

    func recordRejection(_ reason: V2GatewayMessageSendRejectionReason) {
        rejections[reason, default: 0] &+= 1
    }

    public func metricsSnapshot() -> V2GatewayMessageSendMetricsSnapshot {
        .init(inFlightRequests: inFlightRequests, reservedBytes: reservedBytes,
              peakInFlightRequests: peakInFlightRequests, peakReservedBytes: peakReservedBytes,
              rejections: rejections)
    }

    func inFlightBytes() -> Int { reservedBytes }
}

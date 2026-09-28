/// Bounds memory held by message-send requests across all gateway connections.
/// The connection owner enforces its own request-count and byte limits first.
public actor V2GatewayMessageSendBudget {
    private let maximumBytes: Int
    private var reservedBytes = 0

    public init(maximumBytes: Int) {
        precondition(maximumBytes > 0)
        self.maximumBytes = maximumBytes
    }

    func reserve(_ bytes: Int) -> Bool {
        guard bytes > 0, bytes <= maximumBytes - reservedBytes else { return false }
        reservedBytes += bytes
        return true
    }

    func release(_ bytes: Int) {
        precondition(bytes > 0 && reservedBytes >= bytes)
        reservedBytes -= bytes
    }

    func inFlightBytes() -> Int { reservedBytes }
}

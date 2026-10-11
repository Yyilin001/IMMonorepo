/// Bounds retained room work. Execution concurrency comes from the physical pool.
public struct V2SendOperationSchedulingConfiguration: Equatable, Sendable {
    public let maximumPendingRequests: Int

    public init(maximumPendingRequests: Int = 1_024) {
        precondition(maximumPendingRequests > 0)
        self.maximumPendingRequests = maximumPendingRequests
    }
}

/// Bounds retained room work. Execution concurrency comes from the physical pool;
/// a plain Database without pool metadata uses the explicit fallback capacity.
public struct V2SendOperationSchedulingConfiguration: Equatable, Sendable {
    public let maximumPendingRequests: Int
    public let fallbackConnectionCapacity: Int

    public init(maximumPendingRequests: Int = 1_024, fallbackConnectionCapacity: Int = 1) {
        precondition(maximumPendingRequests > 0 && fallbackConnectionCapacity > 0)
        self.maximumPendingRequests = maximumPendingRequests
        self.fallbackConnectionCapacity = fallbackConnectionCapacity
    }
}

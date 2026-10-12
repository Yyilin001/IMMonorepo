/// Bounds retained room work. Execution concurrency comes from the physical pool.
public struct V2SendOperationSchedulingConfiguration: Equatable, Sendable {
    public let maximumPendingRequests: Int
    public let pipelineDepth: Int

    public init(maximumPendingRequests: Int = 1_024, pipelineDepth: Int = 1) {
        precondition(maximumPendingRequests > 0)
        precondition((1...2).contains(pipelineDepth))
        self.maximumPendingRequests = maximumPendingRequests
        self.pipelineDepth = pipelineDepth
    }
}

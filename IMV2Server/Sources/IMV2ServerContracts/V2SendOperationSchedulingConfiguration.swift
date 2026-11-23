/// Bounds retained room work. Execution concurrency comes from the physical pool.
public struct V2SendOperationSchedulingConfiguration: Equatable, Sendable {
    public let maximumPendingRequests: Int
    public let pipelineDepth: Int

    public let maximumCrossRoomMessages: Int
    public static let supportedCrossRoomMessageLimit = 1...16
    public static let maximumCrossRoomBytes = 64 * 1024

    public init(maximumPendingRequests: Int = 1_024, pipelineDepth: Int = 1, maximumCrossRoomMessages: Int = 1) {
        precondition(Self.supportedCrossRoomMessageLimit.contains(maximumCrossRoomMessages))
        self.maximumCrossRoomMessages = maximumCrossRoomMessages
        precondition(maximumPendingRequests > 0)
        precondition((1...2).contains(pipelineDepth))
        self.maximumPendingRequests = maximumPendingRequests
        self.pipelineDepth = pipelineDepth
    }
}

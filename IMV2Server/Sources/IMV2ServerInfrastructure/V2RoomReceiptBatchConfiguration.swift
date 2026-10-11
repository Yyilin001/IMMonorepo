import Foundation

/// 攒批配置。
public struct V2RoomReceiptBatchConfiguration: Equatable, Sendable {
    /// 单批最大请求数。
    public let maximumBatchSize: Int
    /// 攒批最长等待时长。
    public let maximumDelay: Duration
    /// 同时在途的最大批次数。
    public let maximumInFlightBatches: Int
    /// 待处理请求上限。
    public let maximumPendingRequests: Int

    /// 校验并保存配置。
    ///
    /// - Parameters:
    ///   - maximumBatchSize: 单批请求数，需落在 `2...128`。
    ///   - maximumDelay: 攒批等待时长，需大于零且不超过 25 毫秒。
    ///   - maximumInFlightBatches: 在途批次数上限，需落在 `1...128`。
    ///   - maximumPendingRequests: 待处理请求上限，需不小于单批上限。
    ///
    /// 参数越界时直接失败，避免出现无界驻留或超过延迟预算的攒批。
    public init(
        maximumBatchSize: Int,
        maximumDelay: Duration,
        maximumInFlightBatches: Int,
        maximumPendingRequests: Int
    ) {
        precondition((2 ... 128).contains(maximumBatchSize))
        precondition(maximumDelay > .zero && maximumDelay <= .milliseconds(25))
        precondition((1 ... 128).contains(maximumInFlightBatches))
        precondition(maximumPendingRequests >= maximumBatchSize)
        self.maximumBatchSize = maximumBatchSize
        self.maximumDelay = maximumDelay
        self.maximumInFlightBatches = maximumInFlightBatches
        self.maximumPendingRequests = maximumPendingRequests
    }
}

import IMV2ServerApplication
import IMV2ServerContracts

public extension V2RoomServerOwnerResources {
    /// 提供每个所有者的回执指标，同时不暴露准入批处理器。
    var receiptBatchMetrics: any V2ReadReceiptBatchMetricsReading { receiptBatcher }
}

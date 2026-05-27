import Foundation

extension ConversationRuntimeController {
    // 运行时收敛顺序固定为：实时 timeline -> summary changes -> timeline/since 补洞。
    // 不允许在这里重新引入“写后 summary 立即一致”的客户端假设。
    enum HistoryConfig {
        static let latestHistoryLimit = 100
        static let gapSyncLimit = 100
        static let gapSyncMaxIterations = 10
        static let queuedFlushLimit = 20
        static let readReportDebounceNanoseconds: UInt64 = 250_000_000
        static let summaryRefreshDebounceNanoseconds: UInt64 = 400_000_000
        static let minimumSummaryRefreshInterval: TimeInterval = 5
        static let summaryPageLimit = 100
        static let reconnectInitialDelayNanoseconds: UInt64 = 1_000_000_000
        static let reconnectMaxDelayNanoseconds: UInt64 = 30_000_000_000
    }

    enum ConversationGapSyncResult {
        case completed
        case incomplete
        case failed
    }

    enum QueuedTextMessageFlushBatchResult {
        case drained
        case hasMore
        case failed
    }

    enum HistoryMergeMode {
        case replace
        case prepend
    }
}

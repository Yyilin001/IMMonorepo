import Foundation

extension ConversationRuntimeController {
    // 运行时收敛顺序固定为：实时 timeline -> summary changes -> timeline/since 补洞。
    // 不允许在这里重新引入“写后 summary 立即一致”的客户端假设。
    enum HistoryConfig {
        static let latestHistoryLimit = 100
        static let gapSyncLimit = 100
        static let gapSyncMaxIterations = 10
        static let selectedConversationHintCatchUpInitialJitterNanoseconds: UInt64 = 750_000_000
        static let selectedConversationHintCatchUpMinIntervalNanoseconds: UInt64 = 750_000_000
        static let selectedConversationHintCatchUpMicroBatchNanoseconds: UInt64 = 150_000_000
        static let queuedFlushLimit = 20
        static let readReportDebounceNanoseconds: UInt64 = 250_000_000
        static let summaryRefreshDebounceNanoseconds: UInt64 = 400_000_000
        static let minimumSummaryRefreshInterval: TimeInterval = 5
        static let summaryPageLimit = 100
        static let reconnectInitialDelayNanoseconds: UInt64 = 1_000_000_000
        static let reconnectMaxDelayNanoseconds: UInt64 = 30_000_000_000
        static let clientHealthReportMinimumInterval: TimeInterval = 60
        static let timelineCatchUpHealthReportMinimumInterval: TimeInterval = 5
        static let timelineCatchUpSlowReportThresholdMilliseconds = 2_000
    }

    struct TimelineCatchUpConfiguration: Equatable, Sendable {
        private static let minimumDelayNanoseconds: UInt64 = 10_000_000

        var selectedHintInitialJitterNanoseconds: UInt64
        var selectedHintMinimumIntervalNanoseconds: UInt64
        var selectedHintMicroBatchNanoseconds: UInt64

        init(
            selectedHintInitialJitterNanoseconds: UInt64,
            selectedHintMinimumIntervalNanoseconds: UInt64,
            selectedHintMicroBatchNanoseconds: UInt64
        ) {
            self.selectedHintInitialJitterNanoseconds = selectedHintInitialJitterNanoseconds
            self.selectedHintMinimumIntervalNanoseconds = max(
                selectedHintMinimumIntervalNanoseconds,
                Self.minimumDelayNanoseconds
            )
            self.selectedHintMicroBatchNanoseconds = max(
                selectedHintMicroBatchNanoseconds,
                Self.minimumDelayNanoseconds
            )
        }

        static let production = TimelineCatchUpConfiguration(
            selectedHintInitialJitterNanoseconds: HistoryConfig.selectedConversationHintCatchUpInitialJitterNanoseconds,
            selectedHintMinimumIntervalNanoseconds: HistoryConfig.selectedConversationHintCatchUpMinIntervalNanoseconds,
            selectedHintMicroBatchNanoseconds: HistoryConfig.selectedConversationHintCatchUpMicroBatchNanoseconds
        )
    }

    enum ConversationGapSyncResult {
        case completed
        case incomplete
        case deferred
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

    struct ConversationSummaryRefreshRequest {
        var force: Bool
        var bypassMinimumInterval: Bool
        var debounceNanoseconds: UInt64

        mutating func merge(_ other: ConversationSummaryRefreshRequest) {
            force = force || other.force
            bypassMinimumInterval = bypassMinimumInterval || other.bypassMinimumInterval
            debounceNanoseconds = min(debounceNanoseconds, other.debounceNanoseconds)
        }
    }

    struct ForegroundSyncIntervals {
        private static let minimumIntervalNanoseconds: UInt64 = 10_000_000

        var selectedConversationCatchUpNanoseconds: UInt64
        var conversationSummaryRefreshNanoseconds: UInt64

        init(
            selectedConversationCatchUpNanoseconds: UInt64,
            conversationSummaryRefreshNanoseconds: UInt64
        ) {
            self.selectedConversationCatchUpNanoseconds = max(
                selectedConversationCatchUpNanoseconds,
                Self.minimumIntervalNanoseconds
            )
            self.conversationSummaryRefreshNanoseconds = max(
                conversationSummaryRefreshNanoseconds,
                Self.minimumIntervalNanoseconds
            )
        }

        static let production = ForegroundSyncIntervals(
            selectedConversationCatchUpNanoseconds: 5_000_000_000,
            conversationSummaryRefreshNanoseconds: 15_000_000_000
        )
    }
}

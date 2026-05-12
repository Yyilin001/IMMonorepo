import Fluent
import Vapor

struct InlineOutboxProjectionRuntime {
    let app: Application

    func flushIfAllowed() async throws {
        try await app.processInlineOutboxProjectionIfAllowed()
    }
}

struct ConversationOutboxConfiguration: Sendable {
    let batchSize: Int
    let pollIntervalNanoseconds: UInt64
    let maxRetries: Int
    let claimTimeoutNanoseconds: UInt64
    let logsProcessingFailures: Bool
    let maxConcurrentConversations: Int

    init(
        batchSize: Int,
        pollIntervalNanoseconds: UInt64,
        maxRetries: Int,
        claimTimeoutNanoseconds: UInt64 = 60_000_000_000,
        logsProcessingFailures: Bool = true,
        maxConcurrentConversations: Int = 4
    ) {
        self.batchSize = batchSize
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.maxRetries = maxRetries
        self.claimTimeoutNanoseconds = claimTimeoutNanoseconds
        self.logsProcessingFailures = logsProcessingFailures
        self.maxConcurrentConversations = max(1, maxConcurrentConversations)
    }

    var claimTimeoutSeconds: Int {
        max(1, Int(claimTimeoutNanoseconds / 1_000_000_000))
    }

    static func load(from environment: Environment) -> ConversationOutboxConfiguration {
        let batchSize = max(1, Environment.get("IM_OUTBOX_BATCH_SIZE").flatMap(Int.init(_:)) ?? 200)
        let pollIntervalMillis = max(50, Environment.get("IM_OUTBOX_POLL_INTERVAL_MS").flatMap(Int.init(_:)) ?? 500)
        let maxRetries = max(1, Environment.get("IM_OUTBOX_MAX_RETRIES").flatMap(Int.init(_:)) ?? 5)
        let claimTimeoutMillis = max(1_000, Environment.get("IM_OUTBOX_CLAIM_TIMEOUT_MS").flatMap(Int.init(_:)) ?? 60_000)
        let maxConcurrentConversations = max(1, Environment.get("IM_OUTBOX_MAX_CONCURRENCY").flatMap(Int.init(_:)) ?? 4)
        return ConversationOutboxConfiguration(
            batchSize: batchSize,
            pollIntervalNanoseconds: UInt64(pollIntervalMillis) * 1_000_000,
            maxRetries: maxRetries,
            claimTimeoutNanoseconds: UInt64(claimTimeoutMillis) * 1_000_000,
            logsProcessingFailures: true,
            maxConcurrentConversations: maxConcurrentConversations
        )
    }
}

actor OutboxMetrics {
    struct Snapshot: Sendable {
        var processedEvents: Int = 0
        var failedEvents: Int = 0
        var backlogCount: Int = 0
        var oldestPendingAgeMillis: Int = 0
        var lastProcessedEventType: String?
        var lastFailedEventType: String?
    }

    private var snapshot = Snapshot()

    func recordProcessedEvent(eventType: String, durationMillis: Int) {
        snapshot.processedEvents += 1
        snapshot.lastProcessedEventType = eventType
        _ = durationMillis
    }

    func recordFailedEvent(eventType: String, durationMillis: Int) {
        snapshot.failedEvents += 1
        snapshot.lastFailedEventType = eventType
        _ = durationMillis
    }

    func recordBacklog(pendingCount: Int, oldestPendingAgeMillis: Int) {
        snapshot.backlogCount = pendingCount
        snapshot.oldestPendingAgeMillis = oldestPendingAgeMillis
    }

    func currentSnapshot() -> Snapshot {
        snapshot
    }
}

enum ConversationProjectionMode: String, Sendable {
    case synchronous
    case asynchronous
}

private struct ConversationProjectionModeStorageKey: StorageKey {
    typealias Value = ConversationProjectionMode
}

private struct ConversationOutboxConfigurationStorageKey: StorageKey {
    typealias Value = ConversationOutboxConfiguration
}

private struct OutboxMetricsStorageKey: StorageKey {
    typealias Value = OutboxMetrics
}

extension Application {
    var conversationProjectionMode: ConversationProjectionMode {
        get {
            if let mode = storage[ConversationProjectionModeStorageKey.self] {
                return mode
            }
            let mode: ConversationProjectionMode = environment == .testing ? .synchronous : .asynchronous
            storage[ConversationProjectionModeStorageKey.self] = mode
            return mode
        }
        set {
            storage[ConversationProjectionModeStorageKey.self] = newValue
        }
    }

    var conversationOutboxConfiguration: ConversationOutboxConfiguration {
        get {
            if let configuration = storage[ConversationOutboxConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = ConversationOutboxConfiguration.load(from: environment)
            storage[ConversationOutboxConfigurationStorageKey.self] = configuration
            return configuration
        }
        set {
            storage[ConversationOutboxConfigurationStorageKey.self] = newValue
        }
    }

    var outboxMetrics: OutboxMetrics {
        get {
            if let metrics = storage[OutboxMetricsStorageKey.self] {
                return metrics
            }
            let metrics = OutboxMetrics()
            storage[OutboxMetricsStorageKey.self] = metrics
            return metrics
        }
        set {
            storage[OutboxMetricsStorageKey.self] = newValue
        }
    }

    func processConversationOutboxIfNeeded() async throws {
        guard conversationProjectionMode == .synchronous else {
            return
        }

        for shard in conversationShardRouter.allCommandDatabases() {
            _ = try await ConversationOutboxService(db: shard.database).processPendingBatch(
                app: self,
                configuration: conversationOutboxConfiguration
            )
        }
    }

    func processInlineOutboxProjectionIfAllowed() async throws {
        guard try InlineOutboxProjectionPolicy.allowsInlineProjection(app: self) else {
            return
        }

        try await processConversationOutboxIfNeeded()
    }
}

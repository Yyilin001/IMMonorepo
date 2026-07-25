import Fluent
import SQLKit
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
    let idlePollMinimumIntervalNanoseconds: UInt64
    let activeIdleWindowNanoseconds: UInt64
    let notificationsEnabled: Bool
    let notificationChannel: String
    let maxRetries: Int
    let claimTimeoutNanoseconds: UInt64
    let logsProcessingFailures: Bool
    let maxConcurrentConversations: Int

    init(
        batchSize: Int,
        pollIntervalNanoseconds: UInt64,
        idlePollMinimumIntervalNanoseconds: UInt64? = nil,
        activeIdleWindowNanoseconds: UInt64 = 5_000_000_000,
        notificationsEnabled: Bool = false,
        notificationChannel: String = ConversationOutboxNotification.defaultChannel,
        maxRetries: Int,
        claimTimeoutNanoseconds: UInt64 = 60_000_000_000,
        logsProcessingFailures: Bool = true,
        maxConcurrentConversations: Int = 4
    ) {
        self.batchSize = batchSize
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.idlePollMinimumIntervalNanoseconds = min(
            idlePollMinimumIntervalNanoseconds ?? pollIntervalNanoseconds,
            pollIntervalNanoseconds
        )
        self.activeIdleWindowNanoseconds = activeIdleWindowNanoseconds
        self.notificationsEnabled = notificationsEnabled
        self.notificationChannel = notificationChannel
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
        let pollIntervalMillis = max(50, Environment.get("IM_OUTBOX_POLL_INTERVAL_MS").flatMap(Int.init(_:)) ?? 50)
        let idlePollMinimumIntervalMillis = min(
            pollIntervalMillis,
            max(10, Environment.get("IM_OUTBOX_IDLE_POLL_MIN_INTERVAL_MS").flatMap(Int.init(_:)) ?? 50)
        )
        let activeIdleWindowMillis = max(
            0,
            Environment.get("IM_OUTBOX_ACTIVE_IDLE_WINDOW_MS").flatMap(Int.init(_:)) ?? 5_000
        )
        let notificationsEnabled = parseBooleanEnvironment("IM_OUTBOX_NOTIFY_ENABLED", defaultValue: false)
        let notificationChannel = ConversationOutboxNotification.channel()
        let maxRetries = max(1, Environment.get("IM_OUTBOX_MAX_RETRIES").flatMap(Int.init(_:)) ?? 5)
        let claimTimeoutMillis = max(1_000, Environment.get("IM_OUTBOX_CLAIM_TIMEOUT_MS").flatMap(Int.init(_:)) ?? 60_000)
        let maxConcurrentConversations = max(1, Environment.get("IM_OUTBOX_MAX_CONCURRENCY").flatMap(Int.init(_:)) ?? 4)
        return ConversationOutboxConfiguration(
            batchSize: batchSize,
            pollIntervalNanoseconds: UInt64(pollIntervalMillis) * 1_000_000,
            idlePollMinimumIntervalNanoseconds: UInt64(idlePollMinimumIntervalMillis) * 1_000_000,
            activeIdleWindowNanoseconds: UInt64(activeIdleWindowMillis) * 1_000_000,
            notificationsEnabled: notificationsEnabled,
            notificationChannel: notificationChannel,
            maxRetries: maxRetries,
            claimTimeoutNanoseconds: UInt64(claimTimeoutMillis) * 1_000_000,
            logsProcessingFailures: true,
            maxConcurrentConversations: maxConcurrentConversations
        )
    }
}

enum ConversationOutboxNotification {
    static let defaultChannel = "im_conversation_outbox"

    static func channel() -> String {
        let rawValue = Environment.get("IM_OUTBOX_NOTIFY_CHANNEL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawValue, !rawValue.isEmpty else {
            return defaultChannel
        }
        return rawValue
    }

    static func notifyPendingEvents(on database: any Database) async {
        guard parseBooleanEnvironment("IM_OUTBOX_NOTIFY_ENABLED", defaultValue: false),
              let sql = database as? any SQLDatabase,
              sql.dialect.name == "postgresql"
        else {
            return
        }
        try? await sql.raw(
            "SELECT pg_notify(\(bind: channel()), \(bind: "pending"))"
        ).run()
    }
}

actor ConversationOutboxWakeSignal {
    private var pendingNotification = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func notify() {
        guard !waiters.isEmpty else {
            pendingNotification = true
            return
        }
        let continuations = waiters.values
        waiters.removeAll(keepingCapacity: true)
        pendingNotification = false
        for continuation in continuations {
            continuation.resume()
        }
    }

    func wait(timeoutNanoseconds: UInt64) async {
        guard !pendingNotification else {
            pendingNotification = false
            return
        }
        let id = UUID()
        await withCheckedContinuation { continuation in
            waiters[id] = continuation
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                self.resumeWaiter(id)
            }
        }
    }

    private func resumeWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
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

private struct ConversationOutboxWakeSignalStorageKey: StorageKey {
    typealias Value = ConversationOutboxWakeSignal
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

    var conversationOutboxWakeSignal: ConversationOutboxWakeSignal {
        if let signal = storage[ConversationOutboxWakeSignalStorageKey.self] {
            return signal
        }
        let signal = ConversationOutboxWakeSignal()
        storage[ConversationOutboxWakeSignalStorageKey.self] = signal
        return signal
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

        // Contact events are stored in the shared control-plane database, not
        // in the Cell-local conversation shard selected by `imWriteDB`.
        _ = try await ContactOutboxService(db: db).processPendingBatch(
            app: self,
            configuration: conversationOutboxConfiguration
        )
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

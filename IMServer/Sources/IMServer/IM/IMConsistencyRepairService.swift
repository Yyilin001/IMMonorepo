import NIOConcurrencyHelpers
import Vapor

struct IMConsistencyRepairConfiguration: Sendable {
    let isEnabled: Bool
    let intervalNanoseconds: UInt64
    let batchSize: Int

    static func load(from environment: Environment) -> IMConsistencyRepairConfiguration {
        let enabled = parseBooleanEnvironment("IM_CONSISTENCY_REPAIR_ENABLED", defaultValue: false)
        let intervalMillis = max(1_000, Environment.get("IM_CONSISTENCY_REPAIR_INTERVAL_MS").flatMap(Int.init(_:)) ?? 30_000)
        let batchSize = max(1, Environment.get("IM_CONSISTENCY_REPAIR_BATCH_SIZE").flatMap(Int.init(_:)) ?? 200)
        return IMConsistencyRepairConfiguration(
            isEnabled: enabled,
            intervalNanoseconds: UInt64(intervalMillis) * 1_000_000,
            batchSize: batchSize
        )
    }
}

final class IMConsistencyRepairLifecycle: LifecycleHandler, @unchecked Sendable {
    private let taskLock = NIOLock()
    private var task: Task<Void, Never>?

    func didBootAsync(_ application: Application) async throws {
        let configuration = application.consistencyRepairConfiguration
        guard configuration.isEnabled else {
            return
        }

        taskLock.withLock {
            task = Task {
                while !Task.isCancelled {
                    do {
                        try await IMConsistencyRepairService(app: application)
                            .runOnce(limit: configuration.batchSize)
                        try await Task.sleep(nanoseconds: configuration.intervalNanoseconds)
                    } catch {
                        application.logger.warning(
                            "IM consistency repair iteration failed",
                            metadata: ["error": .string(String(describing: error))]
                        )
                        try? await Task.sleep(nanoseconds: configuration.intervalNanoseconds)
                    }
                }
            }
        }
    }

    func shutdownAsync(_ application: Application) async {
        let task = taskLock.withLock { () -> Task<Void, Never>? in
            defer { self.task = nil }
            return self.task
        }
        task?.cancel()
    }
}

struct IMConsistencyRepairService {
    let app: Application

    func runOnce(limit: Int) async throws {
        for shard in app.conversationShardRouter.allCommandDatabases() {
            _ = try await ConversationOutboxService(db: shard.database)
                .requeueFailedEvents(maxRetryCount: app.conversationOutboxConfiguration.maxRetries)
        }

        guard app.eventStreamConfiguration.driver == .kafka else {
            return
        }

        let replay = ConversationReplayService(app: app)
        _ = try await replay.requeueFailedEvents(limit: limit)
        _ = try await replay.replayPendingEvents(limit: limit)
    }
}

private struct IMConsistencyRepairConfigurationStorageKey: StorageKey {
    typealias Value = IMConsistencyRepairConfiguration
}

extension Application {
    var consistencyRepairConfiguration: IMConsistencyRepairConfiguration {
        get {
            if let configuration = storage[IMConsistencyRepairConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMConsistencyRepairConfiguration.load(from: environment)
            storage[IMConsistencyRepairConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMConsistencyRepairConfigurationStorageKey.self] = newValue }
    }
}

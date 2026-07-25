import ConsoleKit
@preconcurrency import Dispatch
import Foundation
import FluentPostgresDriver
import Vapor

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct IMOutboxRelayCommand: AsyncCommand {
    struct Signature: CommandSignature {
        init() {}
    }

    var help: String {
        "Run the IM outbox relay without starting HTTP or TCP listeners."
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let configuration = app.conversationOutboxConfiguration

        app.logger.notice(
            "IM outbox relay started",
            metadata: [
                "node_id": .string(app.imNodeID),
                "role": .string(app.imRuntimeRole.rawValue),
                "event_stream_driver": .string(app.eventStreamConfiguration.driver.rawValue)
            ]
        )

        let notificationListener = startConversationOutboxNotificationListener(
            app: app,
            configuration: configuration
        )
        let task = Task {
            let relay = ConversationOutboxRelay(app: app)
            var idleSleepNanoseconds = configuration.idlePollMinimumIntervalNanoseconds
            var activeUntilNanoseconds: UInt64 = 0
            while !Task.isCancelled {
                do {
                    let relayedCount = try await relay.relayPendingEvents(limit: configuration.batchSize)
                    if relayedCount == 0 {
                        let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
                        let isRecentlyActive = nowNanoseconds < activeUntilNanoseconds
                        let sleepNanoseconds = isRecentlyActive
                            ? configuration.idlePollMinimumIntervalNanoseconds
                            : idleSleepNanoseconds
                        await app.conversationOutboxWakeSignal.wait(timeoutNanoseconds: sleepNanoseconds)
                        if isRecentlyActive {
                            idleSleepNanoseconds = configuration.idlePollMinimumIntervalNanoseconds
                        } else {
                            let (nextIdleSleepNanoseconds, overflowed) = idleSleepNanoseconds.multipliedReportingOverflow(by: 2)
                            idleSleepNanoseconds = min(
                                overflowed ? UInt64.max : nextIdleSleepNanoseconds,
                                configuration.pollIntervalNanoseconds
                            )
                        }
                    } else {
                        let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
                        let (activeUntil, overflowed) = nowNanoseconds.addingReportingOverflow(
                            configuration.activeIdleWindowNanoseconds
                        )
                        activeUntilNanoseconds = overflowed ? UInt64.max : activeUntil
                        idleSleepNanoseconds = configuration.idlePollMinimumIntervalNanoseconds
                    }
                } catch {
                    app.logger.warning(
                        "Conversation outbox relay iteration failed",
                        metadata: ["error": .string(String(describing: error))]
                    )
                    try? await Task.sleep(nanoseconds: configuration.pollIntervalNanoseconds)
                    idleSleepNanoseconds = configuration.idlePollMinimumIntervalNanoseconds
                }
            }
        }

        await waitForShutdownSignal(queueLabel: "imserver.outbox-relay.signal")
        task.cancel()
        await notificationListener?.shutdown()
        _ = await task.result

        app.logger.notice(
            "IM outbox relay stopping",
            metadata: [
                "node_id": .string(app.imNodeID),
                "role": .string(app.imRuntimeRole.rawValue)
            ]
        )
        await app.shutdownConversationEventStreamProducerIfConfigured()
        exit(EXIT_SUCCESS)
    }
}

private func startConversationOutboxNotificationListener(
    app: Application,
    configuration: ConversationOutboxConfiguration
) -> ConversationOutboxNotificationListenerHandle? {
    guard configuration.notificationsEnabled else {
        return nil
    }
    let connectionConfiguration = makeConversationOutboxNotificationConnectionConfiguration(app: app)
    let channel = configuration.notificationChannel
    let connectionBox = ConversationOutboxNotificationConnectionBox()
    let task = Task {
        defer {
            connectionBox.close()
        }
        while !Task.isCancelled {
            let connection: PostgresConnection
            do {
                await app.conversationOutboxWakeSignal.notify()
                app.logger.notice(
                    "Conversation outbox notification listener starting.",
                    metadata: ["channel": .string(channel)]
                )
                connection = try await PostgresConnection.connect(
                    on: app.eventLoopGroup.next(),
                    configuration: connectionConfiguration,
                    id: 9_001,
                    logger: app.logger
                )
                connectionBox.set(connection)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                app.logger.warning(
                    "Conversation outbox notification listener failed to connect; falling back to poll until reconnect.",
                    metadata: [
                        "channel": .string(channel),
                        "error": .string(String(describing: error))
                    ]
                )
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }

            do {
                defer {
                    connectionBox.close()
                }
                try await withTaskCancellationHandler {
                    try await connection.listen(on: channel) { notifications in
                        for try await _ in notifications {
                            guard !Task.isCancelled else {
                                return
                            }
                            await app.conversationOutboxWakeSignal.notify()
                        }
                    }
                } onCancel: {
                    connectionBox.close()
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                app.logger.warning(
                    "Conversation outbox notification listener failed; falling back to poll until reconnect.",
                    metadata: [
                        "channel": .string(channel),
                        "error": .string(String(describing: error))
                    ]
                )
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    return ConversationOutboxNotificationListenerHandle(task: task, connectionBox: connectionBox)
}

private struct ConversationOutboxNotificationListenerHandle: Sendable {
    let task: Task<Void, Never>
    let connectionBox: ConversationOutboxNotificationConnectionBox

    func shutdown() async {
        task.cancel()
        await connectionBox.closeAndWait()
    }
}

private final class ConversationOutboxNotificationConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: PostgresConnection?

    func set(_ connection: PostgresConnection) {
        let previous = lock.withLock { () -> PostgresConnection? in
            let previous = self.connection
            self.connection = connection
            return previous
        }
        previous?.close().whenComplete { _ in }
    }

    func close() {
        let connection = lock.withLock { () -> PostgresConnection? in
            let connection = self.connection
            self.connection = nil
            return connection
        }
        connection?.close().whenComplete { _ in }
    }

    func closeAndWait() async {
        let connection = lock.withLock { () -> PostgresConnection? in
            let connection = self.connection
            self.connection = nil
            return connection
        }
        guard let connection else {
            return
        }
        try? await connection.close().get()
    }
}

private func makeConversationOutboxNotificationConnectionConfiguration(
    app: Application
) -> PostgresConnection.Configuration {
    let isProduction = app.environment == .production
    let defaultUsername = isProduction ? "vapor" : NSUserName()
    let defaultPassword = isProduction ? "vapor_password" : ""
    let host = Environment.get("IM_OUTBOX_NOTIFY_DATABASE_HOST")
        ?? Environment.get("DATABASE_CONVERSATION_SHARD_0_HOST")
        ?? Environment.get("DATABASE_PRIMARY_HOST")
        ?? Environment.get("DATABASE_HOST")
        ?? (isProduction ? "db" : "127.0.0.1")
    let port = Environment.get("IM_OUTBOX_NOTIFY_DATABASE_PORT").flatMap(Int.init(_:))
        ?? Environment.get("DATABASE_CONVERSATION_SHARD_0_PORT").flatMap(Int.init(_:))
        ?? Environment.get("DATABASE_PRIMARY_PORT").flatMap(Int.init(_:))
        ?? Environment.get("DATABASE_PORT").flatMap(Int.init(_:))
        ?? 5432
    let username = Environment.get("IM_OUTBOX_NOTIFY_DATABASE_USERNAME")
        ?? Environment.get("DATABASE_CONVERSATION_SHARD_0_USERNAME")
        ?? Environment.get("DATABASE_PRIMARY_USERNAME")
        ?? Environment.get("DATABASE_USERNAME")
        ?? defaultUsername
    let password = Environment.get("IM_OUTBOX_NOTIFY_DATABASE_PASSWORD")
        ?? Environment.get("DATABASE_CONVERSATION_SHARD_0_PASSWORD")
        ?? Environment.get("DATABASE_PRIMARY_PASSWORD")
        ?? Environment.get("DATABASE_PASSWORD")
        ?? defaultPassword
    let database = Environment.get("IM_OUTBOX_NOTIFY_DATABASE_NAME")
        ?? Environment.get("DATABASE_CONVERSATION_SHARD_0_NAME")
        ?? Environment.get("DATABASE_PRIMARY_NAME")
        ?? Environment.get("DATABASE_NAME")
        ?? "vapor_auth"

    return PostgresConnection.Configuration(
        host: host,
        port: port,
        username: username,
        password: password,
        database: database,
        tls: .disable
    )
}

struct IMStreamConsumerCommand: AsyncCommand {
    struct Signature: CommandSignature {
        init() {}
    }

    var help: String {
        "Run Kafka-backed IM stream consumers without starting HTTP or TCP listeners."
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let consumerConfiguration = app.streamConsumerConfiguration

        app.logger.notice(
            "IM stream consumer started",
            metadata: [
                "node_id": .string(app.imNodeID),
                "role": .string(app.imRuntimeRole.rawValue),
                "event_stream_driver": .string(app.eventStreamConfiguration.driver.rawValue),
                "enabled_groups": .array(consumerConfiguration.enabledGroups.sorted().map { .string($0) })
            ]
        )

        var tasks: [NamedStreamConsumerTask] = []

        if consumerConfiguration.isEnabled("summary-projection-consumer") {
            tasks.append(NamedStreamConsumerTask(groupID: "summary-projection-consumer", task: Task {
                    try await KafkaConversationEventStreamConsumerRunner(
                        app: app,
                        groupID: "summary-projection-consumer",
                        clientSuffix: "summary-projection-consumer",
                        topics: [app.eventStreamConfiguration.topic],
                        consumerFactory: { shardID in
                            [
                                ConversationProjectionConsumer(
                                    app: app,
                                    sourceDB: app.conversationShardRouter.commandDatabase(forShardID: shardID)
                                )
                            ]
                        }
                    ).run()
                }
            ))
        }

        if consumerConfiguration.isEnabled("domain-delivery-consumer") {
            tasks.append(NamedStreamConsumerTask(groupID: "domain-delivery-consumer", task: Task {
                    try await KafkaConversationEventStreamConsumerRunner(
                        app: app,
                        groupID: "domain-delivery-consumer",
                        clientSuffix: "domain-delivery-consumer",
                        topics: [app.eventStreamConfiguration.topic],
                        replayRecordsEnabled: consumerConfiguration.domainDeliveryReplayRecordsEnabled,
                        consumerFactory: { shardID in
                            let sourceDB = app.conversationShardRouter.commandDatabase(forShardID: shardID)
                            return [
                                // Owner deliveries with structural timeline notices must observe the
                                // notice projection first. Keeping both in this consumer group avoids
                                // a cross-group race that can otherwise stall a Kafka partition.
                                ConversationTimelineNoticeProjectionConsumer(
                                    db: sourceDB,
                                    app: app
                                ),
                                OwnerDomainEventDeliveryConsumer(
                                    app: app,
                                    sourceDB: sourceDB,
                                    relayRealtimeAfterRecord: consumerConfiguration.domainDeliveryRelayAfterRecord
                                )
                            ]
                        }
                    ).run()
                }
            ))
        }

        if consumerConfiguration.isEnabled("realtime-delivery-consumer") {
            tasks.append(NamedStreamConsumerTask(groupID: "realtime-delivery-consumer", task: Task {
                    try await KafkaConversationEventStreamConsumerRunner(
                        app: app,
                        groupID: "realtime-delivery-consumer",
                        clientSuffix: "realtime-delivery-consumer",
                        topics: [app.eventStreamConfiguration.topic],
                        replayRecordsEnabled: consumerConfiguration.realtimeDeliveryReplayRecordsEnabled,
                        autoOffsetReset: .latest,
                        coalesceInterleavedMessageCreatedBatches: true,
                        consumerFactory: { shardID in
                            let sourceDB = app.conversationShardRouter.commandDatabase(forShardID: shardID)
                            return [
                                ConversationRealtimeDeliveryConsumer(
                                    app: app,
                                    sourceDB: sourceDB
                                )
                            ]
                        }
                    ).run()
                }
            ))
        }

        if consumerConfiguration.isEnabled("changes-log-consumer") {
            tasks.append(NamedStreamConsumerTask(groupID: "changes-log-consumer", task: Task {
                    try await KafkaConversationEventStreamConsumerRunner(
                        app: app,
                        groupID: "changes-log-consumer",
                        clientSuffix: "changes-log-consumer",
                        topics: [app.eventStreamConfiguration.topic],
                        consumerFactory: { shardID in
                            [
                                ChangesLogConsumer(
                                    app: app,
                                    sourceDB: app.conversationShardRouter.commandDatabase(forShardID: shardID)
                                )
                            ]
                        }
                    ).run()
                }
            ))
        }

        if consumerConfiguration.isEnabled("search-index-consumer") {
            tasks.append(NamedStreamConsumerTask(groupID: "search-index-consumer", task: Task {
                    try await KafkaConversationEventStreamConsumerRunner(
                        app: app,
                        groupID: "search-index-consumer",
                        clientSuffix: "search-index-consumer",
                        topics: [app.eventStreamConfiguration.topic],
                        consumerFactory: { shardID in
                            [
                                ConversationSearchIndexConsumer(
                                    app: app,
                                    db: app.conversationShardRouter.commandDatabase(forShardID: shardID)
                                )
                            ]
                        }
                    ).run()
                }
            ))
        }

        if consumerConfiguration.isEnabled("notification-consumer") {
            tasks.append(NamedStreamConsumerTask(groupID: "notification-consumer", task: Task {
                    try await KafkaConversationEventStreamConsumerRunner(
                        app: app,
                        groupID: "notification-consumer",
                        clientSuffix: "notification-consumer",
                        topics: [app.eventStreamConfiguration.topic],
                        consumerFactory: { _ in
                            [
                                ConversationNotificationConsumer(app: app)
                            ]
                        }
                    ).run()
                }
            ))
        }

        if consumerConfiguration.isEnabled("repair-replay-consumer") {
            tasks.append(NamedStreamConsumerTask(groupID: "repair-replay-consumer", task: Task {
                    try await KafkaConversationEventStreamConsumerRunner(
                        app: app,
                        groupID: "repair-replay-consumer",
                        clientSuffix: "repair-replay-consumer",
                        topics: [app.eventStreamConfiguration.deadLetterTopic],
                        consumerFactory: { _ in
                            [
                                RepairReplayConsumer(
                                    db: app.imWriteDB,
                                    consumerGroupID: "repair-replay-consumer"
                                )
                            ]
                        }
                    ).run()
                }
            ))
        }

        try await superviseStreamConsumerTasks(
            tasks,
            app: app,
            shutdownSignal: {
                await waitForShutdownSignal(queueLabel: "imserver.stream-consumer.signal")
            }
        )

        app.logger.notice(
            "IM stream consumer stopping",
            metadata: [
                "node_id": .string(app.imNodeID),
                "role": .string(app.imRuntimeRole.rawValue)
            ]
        )
        await app.shutdownConversationEventStreamProducerIfConfigured()
        exit(EXIT_SUCCESS)
    }
}

struct NamedStreamConsumerTask: Sendable {
    let groupID: String
    let task: Task<Void, any Error>
}

enum IMStreamConsumerSupervisionResult: Sendable {
    case shutdown
    case taskFinished(groupID: String, result: Result<Void, any Error>)
}

func superviseStreamConsumerTasks(
    _ tasks: [NamedStreamConsumerTask],
    app: Application,
    shutdownSignal: @Sendable @escaping () async -> Void
) async throws {
    guard !tasks.isEmpty else {
        app.logger.warning("IM stream consumer started with no enabled consumer groups")
        await shutdownSignal()
        return
    }

    let firstResult = FirstStreamConsumerSupervisionResult()
    let shutdownMonitor = Task {
        await shutdownSignal()
        await firstResult.yield(.shutdown)
    }
    let taskMonitors = tasks.map { consumerTask in
        Task {
            let result = await consumerTask.task.result
            await firstResult.yield(.taskFinished(groupID: consumerTask.groupID, result: result))
        }
    }
    let result = await firstResult.wait()
    shutdownMonitor.cancel()
    for monitor in taskMonitors {
        monitor.cancel()
    }

    switch result {
    case .shutdown:
        for task in tasks {
            task.task.cancel()
        }
        for task in tasks {
            _ = await task.task.result
        }
    case .taskFinished(let groupID, let result):
        for task in tasks {
            task.task.cancel()
        }
        for task in tasks where task.groupID != groupID {
            _ = await task.task.result
        }
        switch result {
        case .success:
            app.logger.critical(
                "IM stream consumer task exited unexpectedly",
                metadata: ["group_id": .string(groupID)]
            )
            throw Abort(.internalServerError, reason: "IM stream consumer \(groupID) exited unexpectedly.")
        case .failure(let error):
            app.logger.critical(
                "IM stream consumer task failed",
                metadata: [
                    "group_id": .string(groupID),
                    "error": .string(String(describing: error))
                ]
            )
            throw error
        }
    }
}

private actor FirstStreamConsumerSupervisionResult {
    private var result: IMStreamConsumerSupervisionResult?
    private var continuation: CheckedContinuation<IMStreamConsumerSupervisionResult, Never>?

    func wait() async -> IMStreamConsumerSupervisionResult {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            if let result {
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
            }
        }
    }

    func yield(_ result: IMStreamConsumerSupervisionResult) {
        guard self.result == nil else {
            return
        }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}

func waitForShutdownSignal(queueLabel: String) async {
    let state = SignalContinuationResumeState()
    await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)

            let queue = DispatchQueue(label: queueLabel)
            let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
            let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)

            let finish: @Sendable () -> Void = {
                state.resumeOnce()
            }

            intSource.setEventHandler(handler: finish)
            termSource.setEventHandler(handler: finish)
            state.install(continuation: continuation, intSource: intSource, termSource: termSource)
        }
    } onCancel: {
        state.resumeOnce()
    }
}

final class SignalContinuationResumeState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var intSource: (any DispatchSourceSignal)?
    private var termSource: (any DispatchSourceSignal)?

    func install(
        continuation: CheckedContinuation<Void, Never>,
        intSource: any DispatchSourceSignal,
        termSource: any DispatchSourceSignal
    ) {
        lock.lock()
        if resumed {
            lock.unlock()
            intSource.cancel()
            termSource.cancel()
            continuation.resume()
            return
        }
        self.continuation = continuation
        self.intSource = intSource
        self.termSource = termSource
        lock.unlock()

        intSource.resume()
        termSource.resume()
    }

    func resumeOnce() {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        let continuation = self.continuation
        let intSource = self.intSource
        let termSource = self.termSource
        self.continuation = nil
        self.intSource = nil
        self.termSource = nil
        lock.unlock()

        intSource?.cancel()
        termSource?.cancel()
        continuation?.resume()
    }
}

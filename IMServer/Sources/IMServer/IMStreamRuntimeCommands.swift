import ConsoleKit
@preconcurrency import Dispatch
import Foundation
import Vapor

#if canImport(Darwin)
import Darwin
#else
import Glibc
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

        let task = Task {
            let relay = ConversationOutboxRelay(app: app)
            while !Task.isCancelled {
                do {
                    let relayedCount = try await relay.relayPendingEvents(limit: configuration.batchSize)
                    if relayedCount == 0 {
                        try await Task.sleep(nanoseconds: configuration.pollIntervalNanoseconds)
                    }
                } catch {
                    app.logger.warning(
                        "Conversation outbox relay iteration failed",
                        metadata: ["error": .string(String(describing: error))]
                    )
                    try? await Task.sleep(nanoseconds: configuration.pollIntervalNanoseconds)
                }
            }
        }

        await waitForShutdownSignal(queueLabel: "imserver.outbox-relay.signal")
        task.cancel()
        _ = await task.result

        app.logger.notice(
            "IM outbox relay stopping",
            metadata: [
                "node_id": .string(app.imNodeID),
                "role": .string(app.imRuntimeRole.rawValue)
            ]
        )
    }
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

private func waitForShutdownSignal(queueLabel: String) async {
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

private final class SignalContinuationResumeState: @unchecked Sendable {
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

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

        var tasks: [Task<Void, any Error>] = []

        if consumerConfiguration.isEnabled("summary-projection-consumer") {
            tasks.append(Task {
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
            })
        }

        if consumerConfiguration.isEnabled("changes-log-consumer") {
            tasks.append(Task {
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
            })
        }

        if consumerConfiguration.isEnabled("search-index-consumer") {
            tasks.append(Task {
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
            })
        }

        if consumerConfiguration.isEnabled("notification-consumer") {
            tasks.append(Task {
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
            })
        }

        if consumerConfiguration.isEnabled("repair-replay-consumer") {
            tasks.append(Task {
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
            })
        }

        await waitForShutdownSignal(queueLabel: "imserver.stream-consumer.signal")
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            _ = await task.result
        }

        app.logger.notice(
            "IM stream consumer stopping",
            metadata: [
                "node_id": .string(app.imNodeID),
                "role": .string(app.imRuntimeRole.rawValue)
            ]
        )
    }
}

private func waitForShutdownSignal(queueLabel: String) async {
    await withCheckedContinuation { continuation in
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let queue = DispatchQueue(label: queueLabel)
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        let state = SignalContinuationResumeState()

        let finish: @Sendable () -> Void = {
            state.resumeOnce {
                intSource.cancel()
                termSource.cancel()
                continuation.resume()
            }
        }

        intSource.setEventHandler(handler: finish)
        termSource.setEventHandler(handler: finish)
        intSource.resume()
        termSource.resume()
    }
}

private final class SignalContinuationResumeState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resumeOnce(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else {
            return
        }
        resumed = true
        body()
    }
}

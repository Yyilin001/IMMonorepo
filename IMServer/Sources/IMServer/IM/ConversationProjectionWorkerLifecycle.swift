import Foundation
import NIOConcurrencyHelpers
import Vapor

final class ConversationProjectionWorkerLifecycle: LifecycleHandler, @unchecked Sendable {
    private let taskLock = NIOLock()
    private var task: Task<Void, Never>?

    func didBootAsync(_ application: Application) async throws {
        guard application.conversationProjectionMode == .asynchronous else {
            return
        }

        let configuration = application.conversationOutboxConfiguration
        taskLock.withLock {
            task = Task {
                while !Task.isCancelled {
                    do {
                        var processedCount = 0
                        for shard in application.conversationShardRouter.allCommandDatabases() {
                            processedCount += try await ConversationOutboxProcessor(db: shard.database).processPendingBatch(
                                app: application,
                                configuration: configuration
                            )
                        }
                        if processedCount == 0 {
                            try await Task.sleep(nanoseconds: configuration.pollIntervalNanoseconds)
                        }
                    } catch {
                        application.logger.warning(
                            "Conversation projection worker iteration failed",
                            metadata: [
                                "node_id": .string(application.imNodeID),
                                "error": .string(String(describing: error))
                            ]
                        )
                        try? await Task.sleep(nanoseconds: configuration.pollIntervalNanoseconds)
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

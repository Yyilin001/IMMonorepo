import Vapor
import Logging
import NIOCore
import NIOPosix

@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()
        let runtimeRole = normalizeRuntimeRole(in: &env)
        let shouldResetIMSchema = env.arguments.contains("--reset-im-schema")
        env.commandInput.arguments.removeAll { $0 == "--reset-im-schema" }
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)
        app.imRuntimeRole = runtimeRole

        // 这里会尝试将 NIO 安装为 Swift Concurrency 的全局执行器。
        // 如果你想减少 NIO 与 Swift Concurrency 之间的上下文切换，可以启用它。
        // 注意：这会与某些使用 `.wait()` 或依赖干净关闭流程的库产生问题。
        // 如果启用它，请避免在此之前调用异步函数，否则可能触发断言失败。
        // let executorTakeoverSuccess = NIOSingletons.unsafeTryInstallSingletonPosixEventLoopGroupAsConcurrencyGlobalExecutor()
        // app.logger.debug("已尝试将 SwiftNIO 的 EventLoopGroup 安装为 Swift 的全局并发执行器", metadata: ["success": .stringConvertible(executorTakeoverSuccess)])
        
        do {
            app.shouldResetIMSchema = shouldResetIMSchema
            try await configure(app)
            let summaryRepairService = IMSummaryReadModelRepairService(app: app)
            let shouldRebuildConversationSummaries = env.arguments.contains("--rebuild-conversation-summaries")
            let shouldVerifyConversationSummaries = env.arguments.contains("--verify-conversation-summaries")
            let shouldRequeueFailedConversationEvents = env.arguments.contains("--requeue-failed-conversation-events")
            let shouldReplayConversationDeadLetterEvents = env.arguments.contains("--replay-conversation-dead-letter-events")
            let repairConversationSummaryOwnerID = env.arguments
                .drop(while: { $0 != "--repair-conversation-summary-owner" })
                .dropFirst()
                .first

            if shouldRebuildConversationSummaries {
                let rebuiltUserCount = try await summaryRepairService.rebuildAllSummaries()
                app.logger.notice(
                    "Conversation summary repair completed",
                    metadata: ["rebuilt_user_count": .stringConvertible(rebuiltUserCount)]
                )
                if !shouldVerifyConversationSummaries {
                    try await app.asyncShutdown()
                    return
                }
            }

            if shouldVerifyConversationSummaries {
                let verificationResult = try await summaryRepairService.verifyAllSummaries()
                app.logger.notice(
                    "Conversation summary verification completed",
                    metadata: [
                        "owner_user_count": .stringConvertible(verificationResult.ownerUserCount),
                        "tombstone_summary_count": .stringConvertible(verificationResult.tombstoneSummaryCount),
                        "missing_summary_count": .stringConvertible(verificationResult.missingSummaryCount),
                        "stale_active_summary_count": .stringConvertible(verificationResult.staleActiveSummaryCount),
                        "latest_visible_message_mismatch_count": .stringConvertible(verificationResult.latestVisibleMessageMismatchCount),
                        "unread_mismatch_count": .stringConvertible(verificationResult.unreadMismatchCount)
                    ]
                )
                try await app.asyncShutdown()
                return
            }

            if let repairConversationSummaryOwnerID {
                guard let ownerUserID = UUID(uuidString: repairConversationSummaryOwnerID) else {
                    app.logger.error(
                        "Invalid repair conversation summary owner identifier",
                        metadata: ["owner_user_id": .string(repairConversationSummaryOwnerID)]
                    )
                    try await app.asyncShutdown()
                    return
                }

                try await summaryRepairService.rebuildSummaries(for: ownerUserID)
                app.logger.notice(
                    "Conversation summary owner repair completed",
                    metadata: ["owner_user_id": .string(ownerUserID.uuidString)]
                )
                try await app.asyncShutdown()
                return
            }

            if shouldRequeueFailedConversationEvents {
                var requeuedCount = 0
                for shard in app.conversationShardRouter.allCommandDatabases() {
                    requeuedCount += try await ConversationOutboxService(db: shard.database).requeueFailedEvents(
                        maxRetryCount: app.conversationOutboxConfiguration.maxRetries
                    )
                }
                app.logger.notice(
                    "Failed conversation outbox events requeued",
                    metadata: ["requeued_event_count": .stringConvertible(requeuedCount)]
                )
                try await app.asyncShutdown()
                return
            }

            if shouldReplayConversationDeadLetterEvents {
                let replayedCount = try await ConversationReplayService(app: app)
                    .replayPendingEvents(limit: 200)
                app.logger.notice(
                    "Conversation dead-letter replay completed",
                    metadata: ["replayed_event_count": .stringConvertible(replayedCount)]
                )
                try await app.asyncShutdown()
                return
            }
            try await app.execute()
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private static func normalizeRuntimeRole(in env: inout Environment) -> IMRuntimeRole {
        var commandInput = env.commandInput
        let requestedRole = extractRequestedRole(from: &commandInput)
        let role: IMRuntimeRole

        switch requestedRole {
        case .some(.gateway):
            role = .gateway
        case .some(.commandAPI):
            role = .commandAPI
        case .some(.queryAPI):
            role = .queryAPI
        case .some(.outboxRelay):
            role = .outboxRelay
        case .some(.streamConsumer):
            role = .streamConsumer
        case .some(.projectionWorker):
            role = .projectionWorker
        case .some(.combined):
            role = .combined
        case .some(.ops):
            role = .ops
        case .none:
            if commandInput.arguments.contains("--rebuild-conversation-summaries")
                || commandInput.arguments.contains("--verify-conversation-summaries")
                || commandInput.arguments.contains("--repair-conversation-summary-owner")
                || commandInput.arguments.contains("--requeue-failed-conversation-events")
                || commandInput.arguments.contains("--replay-conversation-dead-letter-events")
                || commandInput.arguments.contains("--reset-im-schema") && !commandInput.arguments.contains("serve")
            {
                role = .ops
            } else if commandInput.arguments.first == "outbox-relay" {
                role = .outboxRelay
            } else if commandInput.arguments.first == "stream-consumer" {
                role = .streamConsumer
            } else if commandInput.arguments.first == "worker" || commandInput.arguments.first == "projection-worker" {
                role = .projectionWorker
            } else if let environmentRole = IMRuntimeRole.loadFromEnvironment() {
                role = environmentRole
            } else {
                role = .combined
            }
        }

        switch role {
        case .projectionWorker:
            rewriteServeCommand(&commandInput, to: "projection-worker")
        case .outboxRelay:
            rewriteServeCommand(&commandInput, to: "outbox-relay")
        case .streamConsumer:
            rewriteServeCommand(&commandInput, to: "stream-consumer")
        case .ops:
            rewriteServeCommand(&commandInput, to: "ops")
        case .gateway, .commandAPI, .queryAPI, .combined:
            break
        }

        env.commandInput = commandInput
        return role
    }

    private static func extractRequestedRole(from commandInput: inout CommandInput) -> IMRuntimeRole? {
        guard let roleFlagIndex = commandInput.arguments.firstIndex(of: "--role") else {
            return nil
        }

        guard commandInput.arguments.indices.contains(commandInput.arguments.index(after: roleFlagIndex)) else {
            commandInput.arguments.remove(at: roleFlagIndex)
            return nil
        }

        let valueIndex = commandInput.arguments.index(after: roleFlagIndex)
        let rawRole = commandInput.arguments[valueIndex]
        commandInput.arguments.remove(at: valueIndex)
        commandInput.arguments.remove(at: roleFlagIndex)

        switch rawRole {
        case "gateway":
            return .gateway
        case "command-api":
            return .commandAPI
        case "query-api":
            return .queryAPI
        case "outbox-relay":
            return .outboxRelay
        case "stream-consumer":
            return .streamConsumer
        case "projection-worker", "worker":
            return .projectionWorker
        case "combined":
            return .combined
        case "ops":
            return .ops
        case "api":
            return .combined
        default:
            return nil
        }
    }

    private static func rewriteServeCommand(_ commandInput: inout CommandInput, to commandName: String) {
        if let serveIndex = commandInput.arguments.firstIndex(of: "serve") {
            commandInput.arguments[serveIndex] = commandName
            return
        }

        if !commandInput.arguments.contains(commandName) {
            commandInput.arguments.insert(commandName, at: 0)
        }
    }
}

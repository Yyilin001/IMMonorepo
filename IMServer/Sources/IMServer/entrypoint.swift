import Vapor
import Logging
import NIOCore
import NIOPosix

@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)

        // 这里会尝试将 NIO 安装为 Swift Concurrency 的全局执行器。
        // 如果你想减少 NIO 与 Swift Concurrency 之间的上下文切换，可以启用它。
        // 注意：这会与某些使用 `.wait()` 或依赖干净关闭流程的库产生问题。
        // 如果启用它，请避免在此之前调用异步函数，否则可能触发断言失败。
        // let executorTakeoverSuccess = NIOSingletons.unsafeTryInstallSingletonPosixEventLoopGroupAsConcurrencyGlobalExecutor()
        // app.logger.debug("已尝试将 SwiftNIO 的 EventLoopGroup 安装为 Swift 的全局并发执行器", metadata: ["success": .stringConvertible(executorTakeoverSuccess)])
        
        do {
            try await configure(app)
            let projectionService = IMConversationSummaryProjectionService(db: app.db)
            let shouldRebuildConversationSummaries = env.arguments.contains("--rebuild-conversation-summaries")
            let shouldVerifyConversationSummaries = env.arguments.contains("--verify-conversation-summaries")

            if shouldRebuildConversationSummaries {
                let rebuiltUserCount = try await projectionService.rebuildAllSummaries()
                app.logger.notice(
                    "Conversation summary backfill completed",
                    metadata: ["rebuilt_user_count": .stringConvertible(rebuiltUserCount)]
                )
                if !shouldVerifyConversationSummaries {
                    try await app.asyncShutdown()
                    return
                }
            }

            if shouldVerifyConversationSummaries {
                let verificationResult = try await projectionService.verifyAllSummaries()
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
            try await app.execute()
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}

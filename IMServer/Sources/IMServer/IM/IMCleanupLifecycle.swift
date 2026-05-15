import Fluent
import Foundation
import Vapor

struct IMCleanupConfiguration: Sendable {
    let enabled: Bool
    let intervalSeconds: Int

    static func load() -> IMCleanupConfiguration {
        let enabled = (Environment.get("IM_CLEANUP_ENABLED") ?? "false").lowercased() == "true"
        let intervalSeconds = max(60, Environment.get("IM_CLEANUP_INTERVAL_SECONDS").flatMap(Int.init(_:)) ?? 86_400)
        return IMCleanupConfiguration(enabled: enabled, intervalSeconds: intervalSeconds)
    }
}

final class IMCleanupLifecycle: LifecycleHandler, @unchecked Sendable {
    private var task: Task<Void, Never>?

    func didBootAsync(_ application: Application) async throws {
        let configuration = IMCleanupConfiguration.load()
        guard configuration.enabled else {
            return
        }

        task = Task { [weak application] in
            while !Task.isCancelled {
                guard let application else {
                    return
                }
                do {
                    try await IMCleanupService(app: application).runOnce()
                } catch {
                    application.logger.warning(
                        "IM cleanup task failed",
                        metadata: ["error": .string(String(describing: error))]
                    )
                }

                try? await Task.sleep(nanoseconds: UInt64(configuration.intervalSeconds) * 1_000_000_000)
            }
        }
    }

    func shutdownAsync(_ application: Application) async {
        task?.cancel()
        task = nil
    }
}

struct IMCleanupService {
    let app: Application

    func runOnce(now: Date = Date()) async throws {
        async let inviteCount = deleteExpiredUnusedInvites(now: now)
        async let pushTokenCount = deleteInactivePushTokens(now: now)
        async let visibilityCount = deleteOldVisibilityOverlays(now: now)

        let counts = try await (inviteCount, pushTokenCount, visibilityCount)
        app.logger.info(
            "IM cleanup completed",
            metadata: [
                "expired_invites": .stringConvertible(counts.0),
                "inactive_push_tokens": .stringConvertible(counts.1),
                "visibility_overlays": .stringConvertible(counts.2)
            ]
        )
    }

    private func deleteExpiredUnusedInvites(now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let rows = try await GroupInvite.query(on: app.imWriteDB)
            .filter(\.$expiresAt < cutoff)
            .filter(\.$useCount == 0)
            .all()
        try await rows.delete(on: app.imWriteDB)
        return rows.count
    }

    private func deleteInactivePushTokens(now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-90 * 24 * 60 * 60)
        let rows = try await PushDeviceToken.query(on: app.db)
            .filter(\.$isActive == false)
            .filter(\.$updatedAt < cutoff)
            .all()
        try await rows.delete(on: app.db)
        return rows.count
    }

    private func deleteOldVisibilityOverlays(now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-365 * 24 * 60 * 60)
        var deletedCount = 0
        for shard in app.conversationShardRouter.allCommandDatabases() {
            let messageRows = try await MessageVisibilityOverride.query(on: shard.database)
                .filter(\.$createdAt < cutoff)
                .all()
            let conversationRows = try await ConversationVisibilityOverride.query(on: shard.database)
                .filter(\.$updatedAt < cutoff)
                .all()
            try await messageRows.delete(on: shard.database)
            try await conversationRows.delete(on: shard.database)
            deletedCount += messageRows.count + conversationRows.count
        }
        return deletedCount
    }
}


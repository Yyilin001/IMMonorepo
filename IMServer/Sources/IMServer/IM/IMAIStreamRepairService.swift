import Fluent
import Vapor

final class IMAIStreamRepairLifecycle: LifecycleHandler, @unchecked Sendable {
    private var sweeperTask: Task<Void, Never>?

    func didBootAsync(_ application: Application) async throws {
        guard application.imRuntimeRole.servesGateway || application.imRuntimeRole.servesCommandAPI else {
            return
        }
        do {
            try await IMAIStreamRepairService(app: application).repairStaleStreamingMessages(
                reason: .serverRestarted
            )
        } catch {
            application.logger.warning(
                "AI stream startup repair failed",
                metadata: ["error": .string(String(describing: error))]
            )
        }

        sweeperTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    try Task.checkCancellation()
                    try await IMAIStreamRepairService(app: application).repairStaleStreamingMessages(
                        reason: .streamLost,
                        updatedBefore: Date().addingTimeInterval(-240),
                        skipActiveLeases: true
                    )
                } catch is CancellationError {
                    return
                } catch {
                    application.logger.warning(
                        "AI stream runtime stale repair failed",
                        metadata: ["error": .string(String(describing: error))]
                    )
                }
            }
        }
    }

    func shutdownAsync(_ application: Application) async {
        sweeperTask?.cancel()
        sweeperTask = nil
    }
}

struct IMAIStreamRepairService {
    private static let pageSize = 100

    let app: Application

    @discardableResult
    func repairStaleStreamingMessages(
        reason: AIStreamRepairReason = .serverRestarted,
        now: Date = Date(),
        updatedBefore: Date? = nil,
        skipActiveLeases: Bool = false
    ) async throws -> Int {
        let stateStore = AIMessageStreamStateStore(app: app)
        var repairedCount = 0
        for shard in app.conversationShardRouter.allCommandDatabases() {
            var offset = 0
            while true {
                var query = AIMessageStreamIndex.query(on: shard.database)
                    .filter(\.$state == MessageStreamLifecycleState.streaming.rawValue)
                    .sort(\.$updatedAt)
                    .range(offset..<(offset + Self.pageSize))
                if let updatedBefore {
                    query = query.filter(\.$updatedAt < updatedBefore)
                }
                let candidates = try await query.all()
                guard !candidates.isEmpty else {
                    break
                }
                await app.aiStreamMetrics.recordStartupRepairPage()
                for index in candidates {
                    if skipActiveLeases, try await app.aiStreamLeaseStore.isActive(streamID: index.streamID) {
                        continue
                    }
                    let didRepair = try await stateStore.repair(index: index, reason: reason, now: now)
                    if didRepair {
                        repairedCount += 1
                    }
                }
                guard candidates.count == Self.pageSize else {
                    break
                }
                if skipActiveLeases {
                    offset += Self.pageSize
                }
            }
        }
        if repairedCount > 0 {
            switch reason {
            case .serverRestarted:
                await app.aiStreamMetrics.recordStartupStaleRepair(count: repairedCount)
            case .streamLost:
                await app.aiStreamMetrics.recordRuntimeStaleRepair(count: repairedCount)
            }
            app.logger.warning(
                "AI stream repair marked stale streams failed",
                metadata: [
                    "count": .stringConvertible(repairedCount),
                    "reason": .string(reason.errorCode)
                ]
            )
            try await InlineOutboxProjectionRuntime(app: app).flushIfAllowed()
        }
        return repairedCount
    }

    func auditConsistency() async throws -> [AIMessageStreamConsistencyIssue] {
        try await AIMessageStreamStateStore(app: app).auditConsistency()
    }
}

import IMV2ServerApplication
import FluentKit
import Foundation

extension PostgresV2GroupJoinQuotaStore: V2GroupJoinQuotaRecoveryStoring {}

public extension V2GroupJoinQuotaRecoveryWorker {
    init(controlDatabase: any Database, coordinator: V2ActorInvitationCoordinator,
         deadline: @escaping @Sendable () -> ContinuousClock.Instant,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.init(jobs: PostgresV2GroupJoinQuotaStore(database: controlDatabase),
                  resume: { intent, _ in try await coordinator.resumeSubmission(intent, deadline: deadline()) },
                  now: now)
    }
}

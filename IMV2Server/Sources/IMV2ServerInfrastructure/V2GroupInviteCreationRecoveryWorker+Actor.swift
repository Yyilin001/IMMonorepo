import IMV2ServerApplication
import Foundation

public extension V2GroupInviteCreationRecoveryWorker {
    init(jobs: any V2GroupInviteCreationRecoveryStoring,
                coordinator: V2ActorInvitationCoordinator,
                deadline: @escaping @Sendable () -> ContinuousClock.Instant,
                policy: V2GroupInvitationPolicy = .standard,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.init(jobs: jobs,
                  invitations: V2ActorInvitationCreationResumer(coordinator: coordinator, deadline: deadline),
                  policy: policy, now: now)
    }
}

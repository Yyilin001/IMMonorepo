import Foundation
import IMV2ServerApplication

struct V2ActorInvitationCreationResumer: V2GroupInviteCreationResuming {
    let coordinator: V2ActorInvitationCoordinator
    let deadline: @Sendable () -> ContinuousClock.Instant

    func resumeCreation(_ intent: V2GroupInviteCreationIntent, now: Date) async throws {
        try await coordinator.resumeCreation(intent, evaluatedAt: now, deadline: deadline())
    }
}

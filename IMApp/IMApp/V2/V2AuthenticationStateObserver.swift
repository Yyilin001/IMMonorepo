import Foundation
import IMV2ClientKit

/// Owns one account-scoped stream. Replacement cancels only this observer;
/// a callback already queued for the previous epoch cannot affect a new one.
@MainActor
final class V2AuthenticationStateObserver {
    enum Change: Equatable {
        case authenticationRequired, protectedDataUnavailable, credentialDeletionPending, superseded
    }
    private var task: Task<Void, Never>?
    private var observationID = UUID()

    func start(session: V2AuthSession, epoch: V2AuthSessionEpoch,
               onChange: @escaping @MainActor @Sendable (Change) async -> Void) {
        stop()
        let id = observationID
        task = Task { [weak self] in
            let updates = await session.sessionUpdates(for: epoch)
            for await update in updates {
                guard !Task.isCancelled, self?.observationID == id else { return }
                let change: Change
                switch update.status {
                case .active(.credentialsUnavailable): change = .protectedDataUnavailable
                case .active(.unauthenticated), .ended(.authenticationRequired): change = .authenticationRequired
                case .ended(.credentialDeletionPending): change = .credentialDeletionPending
                case .ended(.superseded): change = .superseded
                default: continue
                }
                await onChange(change)
            }
        }
    }

    func stop() {
        observationID = UUID()
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}

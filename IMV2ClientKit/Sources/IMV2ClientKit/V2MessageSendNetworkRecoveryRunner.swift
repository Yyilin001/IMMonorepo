import Foundation
import IMV2Core

/// Connection-owned wakeup observes both existing and newly parked messages.
/// Observing the durable state closes the race where authentication completes
/// just before an in-flight unavailable callback parks its original command.
public struct V2MessageSendNetworkRecoveryRunner: Sendable {
    private let store: GRDBV2LocalSyncStore
    private let accountID: UserID
    private let isAuthenticated: @Sendable () async throws -> Bool

    public init(store: GRDBV2LocalSyncStore, accountID: UserID,
                isAuthenticated: @escaping @Sendable () async throws -> Bool) {
        self.store = store
        self.accountID = accountID
        self.isAuthenticated = isAuthenticated
    }

    public func run() async throws {
        for try await waiting in store.networkWaitingMessageSendUpdates(accountID: accountID) {
            try Task.checkCancellation()
            guard waiting, try await isAuthenticated() else { continue }
            try Task.checkCancellation()
            try await store.resumeNetworkWaitingMessageSends(accountID: accountID)
        }
    }
}

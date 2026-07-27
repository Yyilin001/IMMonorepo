import Foundation

/// Records only the user's non-sensitive intent to finish deleting a local
/// credential. Tokens and account identifiers remain exclusively in Keychain.
/// The marker is namespaced by the Keychain service so a DEBUG E2E scope and a
/// production session can never affect one another.
protocol V2PendingCredentialDeletionStoring: Sendable {
    func isPending() async -> Bool
    func markPending() async
    func clearPending() async
}

actor V2UserDefaultsPendingCredentialDeletionStore: V2PendingCredentialDeletionStoring {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func isPending() -> Bool { defaults.bool(forKey: key) }

    func markPending() {
        defaults.set(true, forKey: key)
    }

    func clearPending() {
        defaults.removeObject(forKey: key)
    }
}

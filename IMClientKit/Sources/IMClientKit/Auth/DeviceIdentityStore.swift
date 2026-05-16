import Foundation

public protocol DeviceIdentityStore: Sendable {
    func currentDeviceID() throws -> String
    func resetDeviceID()
}

public struct KeychainDeviceIdentityStore: DeviceIdentityStore, Sendable {
    private let keychainStore: TokenStoreHandler
    private let key: String

    public init<Store: TokenStore>(
        keychainStore: Store = KeychainStore(),
        key: String = "stable_device_id"
    ) {
        self.keychainStore = TokenStoreHandler(keychainStore)
        self.key = key
    }

    public func currentDeviceID() throws -> String {
        if let existing = try keychainStore.readString(for: key),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing
        }

        let generated = UUID().uuidString
        try keychainStore.save(generated, for: key)
        return generated
    }

    public func resetDeviceID() {
        keychainStore.delete(key)
    }
}


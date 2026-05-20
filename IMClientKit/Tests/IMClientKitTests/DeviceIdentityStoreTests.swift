import Testing
@testable import IMClientKit

@Suite("DeviceIdentityStoreTests")
struct DeviceIdentityStoreTests {
    @Test func currentDeviceIDPersistsGeneratedIdentifier() throws {
        let keychain = InMemoryTokenStore()
        let store = KeychainDeviceIdentityStore(keychainStore: keychain, key: "test_device_id")

        let first = try store.currentDeviceID()
        let second = try store.currentDeviceID()

        #expect(!first.isEmpty)
        #expect(first == second)
    }

    @Test func resetDeviceIDForcesNewIdentifier() throws {
        let keychain = InMemoryTokenStore()
        let store = KeychainDeviceIdentityStore(keychainStore: keychain, key: "test_device_id")

        let first = try store.currentDeviceID()
        store.resetDeviceID()
        let second = try store.currentDeviceID()

        #expect(first != second)
    }
}


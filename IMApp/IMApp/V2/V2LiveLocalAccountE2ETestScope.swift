import Foundation
import IMV2ClientKit
import IMV2Core

/// A DEBUG-only launch fixture that makes the opt-in local-account UI test
/// repeatable without touching a simulator's real app session, Keychain
/// identity, or local database. Release callers ignore this value entirely.
struct V2LiveLocalAccountE2ETestScope: Sendable, Equatable {
    let deviceID: DeviceID
    private let namespace: UUID

    init?(rawValue: String) {
        guard let namespace = UUID(uuidString: rawValue),
              let deviceID = try? DeviceID(namespace.uuidString)
        else { return nil }
        self.namespace = namespace
        self.deviceID = deviceID
    }

    func keychainService(basedOn productionService: String) -> String {
        productionService + ".local-e2e." + namespace.uuidString.lowercased()
    }

    var databaseFileName: String {
        "sync-local-e2e-\(namespace.uuidString.lowercased()).sqlite"
    }
}

/// A deliberately narrow Debug-launch fixture for the two-install local E2E.
/// It can only prefill the ordinary direct-message UI; it never bypasses the
/// authenticated directory, room-opening or message-send paths.
struct V2LiveLocalAccountE2EConversationLaunchFixture: Sendable, Equatable {
    let directTargetHandle: String?
    let initialMessage: String?

    init(directTargetHandle: String?, initialMessage: String?) {
        self.directTargetHandle = Self.nonEmptyValue(directTargetHandle)
        self.initialMessage = Self.nonEmptyValue(initialMessage)
    }

    private static func nonEmptyValue(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }
}

#if DEBUG
struct V2LiveLocalAccountE2ETestDeviceIdentityProvider: V2DeviceIdentityProvider {
    let value: DeviceID

    init(deviceID: DeviceID) {
        value = deviceID
    }

    func deviceID() async throws -> DeviceID { value }
}
#endif

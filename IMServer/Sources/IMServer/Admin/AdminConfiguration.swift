import Vapor

struct AdminConfiguration: Sendable {
    let isEnabled: Bool
    let sharedSecret: String?

    static func load(from environment: Environment) -> AdminConfiguration {
        AdminConfiguration(
            isEnabled: parseBooleanEnvironment("IM_ADMIN_API_ENABLED", defaultValue: environment != .production),
            sharedSecret: Environment.get("IM_ADMIN_SHARED_SECRET")?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

private struct AdminConfigurationStorageKey: StorageKey {
    typealias Value = AdminConfiguration
}

extension Application {
    var adminConfiguration: AdminConfiguration {
        get {
            if let configuration = storage[AdminConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = AdminConfiguration.load(from: environment)
            storage[AdminConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[AdminConfigurationStorageKey.self] = newValue }
    }
}

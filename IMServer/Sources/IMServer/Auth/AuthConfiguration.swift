import JWTKit
import Vapor

enum AuthConfigurationError: Error, LocalizedError {
    case missingJWTSecret

    var errorDescription: String? {
        switch self {
        case .missingJWTSecret:
            return "生产环境必须显式配置 JWT_SECRET。"
        }
    }
}

struct AuthConfiguration: Sendable {
    let issuer: String
    let jwtSecret: String
    let accessTokenTTL: TimeInterval
    let refreshTokenTTL: TimeInterval
    let refreshGracePeriod: TimeInterval

    static func load(from environment: Environment) throws -> AuthConfiguration {
        let secret = try jwtSecret(for: environment)

        return AuthConfiguration(
            issuer: Environment.get("JWT_ISSUER") ?? "vapor-test",
            jwtSecret: secret,
            accessTokenTTL: 10 * 60,
            refreshTokenTTL: 30 * 24 * 60 * 60,
            refreshGracePeriod: 20
        )
    }

    private static func jwtSecret(for environment: Environment) throws -> String {
        if let configuredSecret = Environment.get("JWT_SECRET")?.trimmed,
           !configuredSecret.isEmpty
        {
            return configuredSecret
        }

        if environment == .production {
            throw AuthConfigurationError.missingJWTSecret
        }

        return "dev-jwt-secret-change-me"
    }
}

private struct AuthConfigurationStorageKey: StorageKey {
    typealias Value = AuthConfiguration
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct JWTKeysStorageKey: StorageKey {
    typealias Value = JWTKeyCollection
}

extension Application {
    var authConfiguration: AuthConfiguration {
        get {
            guard let configuration = self.storage[AuthConfigurationStorageKey.self] else {
                fatalError("AuthConfiguration not configured")
            }
            return configuration
        }
        set {
            self.storage[AuthConfigurationStorageKey.self] = newValue
        }
    }

    var jwtKeys: JWTKeyCollection {
        get {
            if let keys = self.storage[JWTKeysStorageKey.self] {
                return keys
            }

            let keys = JWTKeyCollection()
            self.storage[JWTKeysStorageKey.self] = keys
            return keys
        }
        set {
            self.storage[JWTKeysStorageKey.self] = newValue
        }
    }
}

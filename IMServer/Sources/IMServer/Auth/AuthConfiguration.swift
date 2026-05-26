import JWTKit
import Vapor

enum AuthConfigurationError: Error, LocalizedError {
    case missingJWTSecret
    case missingRedisURL
    case invalidJWTSecrets
    case missingActiveJWTKey(String)

    var errorDescription: String? {
        switch self {
        case .missingJWTSecret:
            return "生产环境必须显式配置 JWT_SECRET。"
        case .missingRedisURL:
            return "生产环境认证限流必须配置 REDIS_URL。"
        case .invalidJWTSecrets:
            return "JWT_SECRETS 格式无效，必须使用 kid:secret 并用逗号分隔。"
        case .missingActiveJWTKey(let kid):
            return "JWT_ACTIVE_KID=\(kid) 未在 JWT_SECRETS 中配置。"
        }
    }
}

struct AuthJWTSigningSecret: Sendable {
    let keyID: String?
    let secret: String
}

struct AuthConfiguration: Sendable {
    let issuer: String
    let jwtSecret: String
    let jwtSecrets: [AuthJWTSigningSecret]
    let activeJWTKeyID: String?
    let accessTokenTTL: TimeInterval
    let refreshTokenTTL: TimeInterval
    let refreshGracePeriod: TimeInterval

    static func load(from environment: Environment) throws -> AuthConfiguration {
        let secrets = try jwtSecrets(for: environment)
        let activeKeyID = try activeJWTKeyID(in: secrets)
        let legacySecret = secrets.first(where: { $0.keyID == activeKeyID })?.secret ?? secrets[0].secret

        return AuthConfiguration(
            issuer: Environment.get("JWT_ISSUER") ?? "vapor-test",
            jwtSecret: legacySecret,
            jwtSecrets: secrets,
            activeJWTKeyID: activeKeyID,
            accessTokenTTL: 10 * 60,
            refreshTokenTTL: 30 * 24 * 60 * 60,
            refreshGracePeriod: 20
        )
    }

    private static func jwtSecrets(for environment: Environment) throws -> [AuthJWTSigningSecret] {
        if let rawSecrets = Environment.get("JWT_SECRETS")?.trimmed,
           !rawSecrets.isEmpty
        {
            let secrets = rawSecrets
                .split(separator: ",")
                .map { rawEntry -> AuthJWTSigningSecret? in
                    let parts = rawEntry.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2 else {
                        return nil
                    }

                    let keyID = String(parts[0]).trimmed
                    let secret = String(parts[1]).trimmed
                    guard !keyID.isEmpty, !secret.isEmpty else {
                        return nil
                    }

                    return AuthJWTSigningSecret(keyID: keyID, secret: secret)
                }

            guard secrets.count == rawSecrets.split(separator: ",").count, !secrets.isEmpty else {
                throw AuthConfigurationError.invalidJWTSecrets
            }

            return secrets.compactMap { $0 }
        }

        if let configuredSecret = Environment.get("JWT_SECRET")?.trimmed,
           !configuredSecret.isEmpty
        {
            return [AuthJWTSigningSecret(keyID: nil, secret: configuredSecret)]
        }

        if environment == .production {
            throw AuthConfigurationError.missingJWTSecret
        }

        return [AuthJWTSigningSecret(keyID: nil, secret: "dev-jwt-secret-change-me")]
    }

    private static func activeJWTKeyID(in secrets: [AuthJWTSigningSecret]) throws -> String? {
        guard let configuredActiveKeyID = Environment.get("JWT_ACTIVE_KID")?.trimmed,
              !configuredActiveKeyID.isEmpty
        else {
            return secrets.first?.keyID
        }

        guard secrets.contains(where: { $0.keyID == configuredActiveKeyID }) else {
            throw AuthConfigurationError.missingActiveJWTKey(configuredActiveKeyID)
        }

        return configuredActiveKeyID
    }
}

enum AuthRateLimitBackend: String, Sendable {
    case memory
    case redis
}

enum AuthEmailDeliveryMode: String, Sendable {
    case log
    case webhook
}

struct AuthSecurityConfiguration: Sendable {
    let rateLimitBackend: AuthRateLimitBackend
    let redisURL: String?
    let emailVerificationRequired: Bool
    let verificationCodeTTL: TimeInterval
    let passwordResetCodeTTL: TimeInterval
    let verificationAttemptLimit: Int
    let auditRetentionDays: Int
    let emailDeliveryMode: AuthEmailDeliveryMode
    let emailWebhookURL: String?
    let emailWebhookSecret: String?

    static func load(from environment: Environment) throws -> AuthSecurityConfiguration {
        let redisURL = Environment.get("REDIS_URL")?.nilIfBlank
        let configuredBackend = Environment.get("AUTH_RATE_LIMIT_BACKEND")
            .flatMap(AuthRateLimitBackend.init(rawValue:))
        let backend = configuredBackend ?? (environment == .production ? .redis : .memory)
        if environment == .production, backend == .redis, redisURL == nil {
            throw AuthConfigurationError.missingRedisURL
        }

        let deliveryMode = Environment.get("AUTH_EMAIL_DELIVERY")
            .flatMap(AuthEmailDeliveryMode.init(rawValue:))
            ?? (environment == .production ? .webhook : .log)

        return AuthSecurityConfiguration(
            rateLimitBackend: backend,
            redisURL: redisURL,
            emailVerificationRequired: Environment.get("AUTH_REQUIRE_EMAIL_VERIFICATION")
                .flatMap(Bool.init(_:)) ?? (environment == .production),
            verificationCodeTTL: Environment.get("AUTH_VERIFICATION_CODE_TTL_SECONDS")
                .flatMap(TimeInterval.init(_:)) ?? 15 * 60,
            passwordResetCodeTTL: Environment.get("AUTH_PASSWORD_RESET_CODE_TTL_SECONDS")
                .flatMap(TimeInterval.init(_:)) ?? 15 * 60,
            verificationAttemptLimit: max(3, Environment.get("AUTH_CODE_ATTEMPT_LIMIT").flatMap(Int.init(_:)) ?? 6),
            auditRetentionDays: max(1, Environment.get("AUTH_AUDIT_RETENTION_DAYS").flatMap(Int.init(_:)) ?? 90),
            emailDeliveryMode: deliveryMode,
            emailWebhookURL: Environment.get("AUTH_EMAIL_WEBHOOK_URL")?.nilIfBlank,
            emailWebhookSecret: Environment.get("AUTH_EMAIL_WEBHOOK_SECRET")?.nilIfBlank
        )
    }
}

private struct AuthConfigurationStorageKey: StorageKey {
    typealias Value = AuthConfiguration
}

private struct AuthSecurityConfigurationStorageKey: StorageKey {
    typealias Value = AuthSecurityConfiguration
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfBlank: String? {
        let normalized = trimmed
        return normalized.isEmpty ? nil : normalized
    }
}

private struct JWTKeysStorageKey: StorageKey {
    typealias Value = JWTKeyCollection
}

extension Application {
    var authConfiguration: AuthConfiguration {
        get {
            guard let configuration = self.storage[AuthConfigurationStorageKey.self] else {
                preconditionFailure("AuthConfiguration not configured")
            }
            return configuration
        }
        set {
            self.storage[AuthConfigurationStorageKey.self] = newValue
        }
    }

    var authSecurityConfiguration: AuthSecurityConfiguration {
        get {
            guard let configuration = self.storage[AuthSecurityConfigurationStorageKey.self] else {
                preconditionFailure("AuthSecurityConfiguration not configured")
            }
            return configuration
        }
        set {
            self.storage[AuthSecurityConfigurationStorageKey.self] = newValue
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

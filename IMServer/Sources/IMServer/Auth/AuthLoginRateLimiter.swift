import Foundation
import NIOCore
import NIOPosix
@preconcurrency import RediStack
import Vapor

struct LoginRateLimitError: AbortError {
    let scopeDescription: String
    let retryAfter: Int

    var status: HTTPResponseStatus {
        .tooManyRequests
    }

    var reason: String {
        "\(scopeDescription)请求过于频繁，请在 \(retryAfter) 秒后重试。"
    }

    var headers: HTTPHeaders {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .retryAfter, value: String(retryAfter))
        return headers
    }
}

struct LoginAttemptReservation: Sendable {
    fileprivate let id: UUID
}

protocol AuthRateLimiting: Sendable {
    func beginLoginAttempt(ipAddress: String?, account: String, now: Date) async throws -> LoginAttemptReservation
    func beginRegistrationAttempt(ipAddress: String?, account: String, now: Date) async throws -> LoginAttemptReservation
    func completeLoginAttempt(_ reservation: LoginAttemptReservation, succeeded: Bool, now: Date) async
    func completeRegistrationAttempt(_ reservation: LoginAttemptReservation, succeeded: Bool, now: Date) async
    func checkRefreshAttempt(ipAddress: String?, account: String?, now: Date) async throws
    func checkPasswordResetAttempt(ipAddress: String?, account: String, now: Date) async throws
    func checkVerificationResendAttempt(ipAddress: String?, account: String, now: Date) async throws
    func checkVerificationConfirmAttempt(ipAddress: String?, account: String, now: Date) async throws
}

actor AuthLoginRateLimiter: AuthRateLimiting {
    struct Rule: Sendable {
        let maxAttempts: Int
        let window: TimeInterval
        let scopeDescription: String
    }

    private let ipRule = Rule(
        maxAttempts: 20,
        window: 5 * 60,
        scopeDescription: "当前 IP 的"
    )
    private let accountRule = Rule(
        maxAttempts: 5,
        window: 15 * 60,
        scopeDescription: "当前账号的"
    )
    private let registrationIPRule = Rule(
        maxAttempts: 10,
        window: 15 * 60,
        scopeDescription: "当前 IP 的注册"
    )
    private let registrationAccountRule = Rule(
        maxAttempts: 3,
        window: 60 * 60,
        scopeDescription: "当前邮箱的注册"
    )
    private let refreshIPRule = Rule(maxAttempts: 60, window: 5 * 60, scopeDescription: "当前 IP 的刷新令牌")
    private let passwordResetIPRule = Rule(maxAttempts: 10, window: 15 * 60, scopeDescription: "当前 IP 的密码重置")
    private let passwordResetAccountRule = Rule(maxAttempts: 3, window: 60 * 60, scopeDescription: "当前账号的密码重置")
    private let verificationResendIPRule = Rule(maxAttempts: 10, window: 15 * 60, scopeDescription: "当前 IP 的验证码")
    private let verificationResendAccountRule = Rule(maxAttempts: 5, window: 60 * 60, scopeDescription: "当前邮箱的验证码")
    private let verificationConfirmIPRule = Rule(maxAttempts: 30, window: 15 * 60, scopeDescription: "当前 IP 的验证码确认")
    private let verificationConfirmAccountRule = Rule(maxAttempts: 8, window: 15 * 60, scopeDescription: "当前邮箱的验证码确认")

    private var ipAttempts: [String: [Date]] = [:]
    private var accountAttempts: [String: [Date]] = [:]
    private var registrationIPAttempts: [String: [Date]] = [:]
    private var registrationAccountAttempts: [String: [Date]] = [:]
    private var pendingReservations: [UUID: PendingReservation] = [:]
    private var pendingIPCounts: [String: Int] = [:]
    private var pendingAccountCounts: [String: Int] = [:]
    private var pendingRegistrationIPCounts: [String: Int] = [:]
    private var pendingRegistrationAccountCounts: [String: Int] = [:]
    private var refreshIPAttempts: [String: [Date]] = [:]
    private var passwordResetIPAttempts: [String: [Date]] = [:]
    private var passwordResetAccountAttempts: [String: [Date]] = [:]
    private var verificationResendIPAttempts: [String: [Date]] = [:]
    private var verificationResendAccountAttempts: [String: [Date]] = [:]
    private var verificationConfirmIPAttempts: [String: [Date]] = [:]
    private var verificationConfirmAccountAttempts: [String: [Date]] = [:]

    func beginLoginAttempt(ipAddress: String?, account: String, now: Date) async throws -> LoginAttemptReservation {
        try beginAttempt(kind: .login, ipAddress: ipAddress, account: account, now: now)
    }

    func beginRegistrationAttempt(ipAddress: String?, account: String, now: Date) async throws -> LoginAttemptReservation {
        try beginAttempt(kind: .registration, ipAddress: ipAddress, account: account, now: now)
    }

    func completeLoginAttempt(_ reservation: LoginAttemptReservation, succeeded: Bool, now: Date) async {
        completeAttempt(reservation, expectedKind: .login, succeeded: succeeded, now: now)
    }

    func completeRegistrationAttempt(_ reservation: LoginAttemptReservation, succeeded: Bool, now: Date) async {
        completeAttempt(reservation, expectedKind: .registration, succeeded: succeeded, now: now)
    }

    func checkRefreshAttempt(ipAddress: String?, account _: String?, now: Date) async throws {
        try checkAndRecord(key: normalize(ipAddress: ipAddress), storage: &refreshIPAttempts, rule: refreshIPRule, now: now)
    }

    func checkPasswordResetAttempt(ipAddress: String?, account: String, now: Date) async throws {
        try checkAndRecord(key: normalize(ipAddress: ipAddress), storage: &passwordResetIPAttempts, rule: passwordResetIPRule, now: now)
        try checkAndRecord(key: account, storage: &passwordResetAccountAttempts, rule: passwordResetAccountRule, now: now)
    }

    func checkVerificationResendAttempt(ipAddress: String?, account: String, now: Date) async throws {
        try checkAndRecord(key: normalize(ipAddress: ipAddress), storage: &verificationResendIPAttempts, rule: verificationResendIPRule, now: now)
        try checkAndRecord(key: account, storage: &verificationResendAccountAttempts, rule: verificationResendAccountRule, now: now)
    }

    func checkVerificationConfirmAttempt(ipAddress: String?, account: String, now: Date) async throws {
        try checkAndRecord(key: normalize(ipAddress: ipAddress), storage: &verificationConfirmIPAttempts, rule: verificationConfirmIPRule, now: now)
        try checkAndRecord(key: account, storage: &verificationConfirmAccountAttempts, rule: verificationConfirmAccountRule, now: now)
    }

    private func beginAttempt(
        kind: AttemptKind,
        ipAddress: String?,
        account: String,
        now: Date
    ) throws -> LoginAttemptReservation {
        let normalizedIP = normalize(ipAddress: ipAddress)

        switch kind {
        case .login:
            if let retryAfter = retryAfter(
                for: normalizedIP,
                committedStorage: &ipAttempts,
                pendingStorage: &pendingIPCounts,
                rule: ipRule,
                now: now
            ) {
                throw LoginRateLimitError(scopeDescription: ipRule.scopeDescription, retryAfter: retryAfter)
            }

            if let retryAfter = retryAfter(
                for: account,
                committedStorage: &accountAttempts,
                pendingStorage: &pendingAccountCounts,
                rule: accountRule,
                now: now
            ) {
                throw LoginRateLimitError(scopeDescription: accountRule.scopeDescription, retryAfter: retryAfter)
            }
        case .registration:
            if let retryAfter = retryAfter(
                for: normalizedIP,
                committedStorage: &registrationIPAttempts,
                pendingStorage: &pendingRegistrationIPCounts,
                rule: registrationIPRule,
                now: now
            ) {
                throw LoginRateLimitError(scopeDescription: registrationIPRule.scopeDescription, retryAfter: retryAfter)
            }

            if let retryAfter = retryAfter(
                for: account,
                committedStorage: &registrationAccountAttempts,
                pendingStorage: &pendingRegistrationAccountCounts,
                rule: registrationAccountRule,
                now: now
            ) {
                throw LoginRateLimitError(scopeDescription: registrationAccountRule.scopeDescription, retryAfter: retryAfter)
            }
        }

        let reservation = PendingReservation(kind: kind, ipAddress: normalizedIP, account: account)
        pendingReservations[reservation.id] = reservation

        switch kind {
        case .login:
            pendingIPCounts[normalizedIP, default: 0] += 1
            pendingAccountCounts[account, default: 0] += 1
        case .registration:
            pendingRegistrationIPCounts[normalizedIP, default: 0] += 1
            pendingRegistrationAccountCounts[account, default: 0] += 1
        }

        return LoginAttemptReservation(id: reservation.id)
    }

    private func completeAttempt(
        _ reservation: LoginAttemptReservation,
        expectedKind: AttemptKind,
        succeeded: Bool,
        now: Date
    ) {
        guard let pending = pendingReservations.removeValue(forKey: reservation.id),
              pending.kind == expectedKind
        else {
            return
        }

        switch pending.kind {
        case .login:
            decrementPendingCount(for: pending.ipAddress, in: &pendingIPCounts)
            decrementPendingCount(for: pending.account, in: &pendingAccountCounts)

            if succeeded {
                accountAttempts.removeValue(forKey: pending.account)
                return
            }

            recordAttempt(for: pending.ipAddress, in: &ipAttempts, rule: ipRule, now: now)
            recordAttempt(for: pending.account, in: &accountAttempts, rule: accountRule, now: now)
        case .registration:
            decrementPendingCount(for: pending.ipAddress, in: &pendingRegistrationIPCounts)
            decrementPendingCount(for: pending.account, in: &pendingRegistrationAccountCounts)
            recordAttempt(for: pending.ipAddress, in: &registrationIPAttempts, rule: registrationIPRule, now: now)
            recordAttempt(
                for: pending.account,
                in: &registrationAccountAttempts,
                rule: registrationAccountRule,
                now: now
            )
        }
    }

    private func retryAfter(
        for key: String,
        committedStorage: inout [String: [Date]],
        pendingStorage: inout [String: Int],
        rule: Rule,
        now: Date
    ) -> Int? {
        let attempts = prunedAttempts(for: key, in: &committedStorage, window: rule.window, now: now)
        let pendingCount = pendingStorage[key, default: 0]
        guard attempts.count + pendingCount >= rule.maxAttempts else {
            return nil
        }

        guard let oldestAttempt = attempts.first else {
            return max(1, Int(ceil(rule.window)))
        }

        return max(1, Int(ceil(oldestAttempt.addingTimeInterval(rule.window).timeIntervalSince(now))))
    }

    private func recordAttempt(
        for key: String,
        in storage: inout [String: [Date]],
        rule: Rule,
        now: Date
    ) {
        var attempts = prunedAttempts(for: key, in: &storage, window: rule.window, now: now)
        attempts.append(now)
        storage[key] = attempts
    }

    private func checkAndRecord(
        key: String,
        storage: inout [String: [Date]],
        rule: Rule,
        now: Date
    ) throws {
        var emptyPending: [String: Int] = [:]
        if let retryAfter = retryAfter(
            for: key,
            committedStorage: &storage,
            pendingStorage: &emptyPending,
            rule: rule,
            now: now
        ) {
            throw LoginRateLimitError(scopeDescription: rule.scopeDescription, retryAfter: retryAfter)
        }
        recordAttempt(for: key, in: &storage, rule: rule, now: now)
    }

    @discardableResult
    private func prunedAttempts(
        for key: String,
        in storage: inout [String: [Date]],
        window: TimeInterval,
        now: Date
    ) -> [Date] {
        let cutoff = now.addingTimeInterval(-window)
        let attempts = (storage[key] ?? []).filter { $0 > cutoff }

        if attempts.isEmpty {
            storage.removeValue(forKey: key)
        } else {
            storage[key] = attempts
        }

        return attempts
    }

    private func normalize(ipAddress: String?) -> String {
        let trimmed = ipAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    private func decrementPendingCount(for key: String, in storage: inout [String: Int]) {
        let remaining = max(0, storage[key, default: 0] - 1)
        if remaining == 0 {
            storage.removeValue(forKey: key)
        } else {
            storage[key] = remaining
        }
    }
}

private struct PendingReservation: Sendable {
    let id: UUID
    let kind: AttemptKind
    let ipAddress: String
    let account: String

    init(kind: AttemptKind, ipAddress: String, account: String) {
        self.id = UUID()
        self.kind = kind
        self.ipAddress = ipAddress
        self.account = account
    }
}

private enum AttemptKind: Sendable {
    case login
    case registration
}

final class RedisAuthRateLimiter: AuthRateLimiting, @unchecked Sendable {
    private struct Rule {
        let maxAttempts: Int
        let window: Int64
        let scopeDescription: String
    }

    private let pool: RedisConnectionPool
    private let logger: Logger
    private let keyPrefix = "im:auth:rate"
    private let loginIPRule = Rule(maxAttempts: 20, window: 5 * 60, scopeDescription: "当前 IP 的")
    private let loginAccountRule = Rule(maxAttempts: 5, window: 15 * 60, scopeDescription: "当前账号的")
    private let registrationIPRule = Rule(maxAttempts: 10, window: 15 * 60, scopeDescription: "当前 IP 的注册")
    private let registrationAccountRule = Rule(maxAttempts: 3, window: 60 * 60, scopeDescription: "当前邮箱的注册")
    private let refreshIPRule = Rule(maxAttempts: 60, window: 5 * 60, scopeDescription: "当前 IP 的刷新令牌")
    private let passwordResetIPRule = Rule(maxAttempts: 10, window: 15 * 60, scopeDescription: "当前 IP 的密码重置")
    private let passwordResetAccountRule = Rule(maxAttempts: 3, window: 60 * 60, scopeDescription: "当前账号的密码重置")
    private let verificationResendIPRule = Rule(maxAttempts: 10, window: 15 * 60, scopeDescription: "当前 IP 的验证码")
    private let verificationResendAccountRule = Rule(maxAttempts: 5, window: 60 * 60, scopeDescription: "当前邮箱的验证码")
    private let verificationConfirmIPRule = Rule(maxAttempts: 30, window: 15 * 60, scopeDescription: "当前 IP 的验证码确认")
    private let verificationConfirmAccountRule = Rule(maxAttempts: 8, window: 15 * 60, scopeDescription: "当前邮箱的验证码确认")

    init(redisURL: String, logger: Logger, eventLoop: any EventLoop) throws {
        self.logger = logger
        let url = try URL(string: redisURL).unwrap(or: RedisRoutingError.invalidURL(redisURL))
        let host = try url.host.unwrap(or: RedisRoutingError.invalidURL(redisURL))
        let address = try SocketAddress.makeAddressResolvingHost(
            host,
            port: url.port ?? RedisConnection.Configuration.defaultPort
        )
        let factoryConfiguration = RedisConnectionPool.ConnectionFactoryConfiguration(
            connectionInitialDatabase: Int(url.lastPathComponent),
            connectionUsername: url.user,
            connectionPassword: url.password,
            connectionDefaultLogger: logger
        )
        pool = RedisConnectionPool(
            configuration: .init(
                initialServerConnectionAddresses: [address],
                maximumConnectionCount: .maximumActiveConnections(4),
                connectionFactoryConfiguration: factoryConfiguration,
                minimumConnectionCount: 1,
                poolDefaultLogger: logger
            ),
            boundEventLoop: eventLoop
        )
    }

    func start() async throws {
        pool.activate(logger: logger)
        _ = try await pool.leaseConnection { $0.ping() }.get()
    }

    func shutdown() async {
        let promise = pool.eventLoop.makePromise(of: Void.self)
        pool.close(promise: promise, logger: logger)
        try? await promise.futureResult.get()
    }

    func beginLoginAttempt(ipAddress: String?, account: String, now _: Date) async throws -> LoginAttemptReservation {
        try await check(scope: "login:ip", key: normalize(ipAddress: ipAddress), rule: loginIPRule)
        try await check(scope: "login:account", key: account, rule: loginAccountRule)
        return LoginAttemptReservation(id: UUID())
    }

    func beginRegistrationAttempt(ipAddress: String?, account: String, now _: Date) async throws -> LoginAttemptReservation {
        try await check(scope: "register:ip", key: normalize(ipAddress: ipAddress), rule: registrationIPRule)
        try await check(scope: "register:account", key: account, rule: registrationAccountRule)
        return LoginAttemptReservation(id: UUID())
    }

    func completeLoginAttempt(_: LoginAttemptReservation, succeeded: Bool, now _: Date) async {
        _ = succeeded
    }

    func completeRegistrationAttempt(_: LoginAttemptReservation, succeeded _: Bool, now _: Date) async {}

    func checkRefreshAttempt(ipAddress: String?, account _: String?, now _: Date) async throws {
        try await check(scope: "refresh:ip", key: normalize(ipAddress: ipAddress), rule: refreshIPRule)
    }

    func checkPasswordResetAttempt(ipAddress: String?, account: String, now _: Date) async throws {
        try await check(scope: "password_reset:ip", key: normalize(ipAddress: ipAddress), rule: passwordResetIPRule)
        try await check(scope: "password_reset:account", key: account, rule: passwordResetAccountRule)
    }

    func checkVerificationResendAttempt(ipAddress: String?, account: String, now _: Date) async throws {
        try await check(scope: "verification_resend:ip", key: normalize(ipAddress: ipAddress), rule: verificationResendIPRule)
        try await check(scope: "verification_resend:account", key: account, rule: verificationResendAccountRule)
    }

    func checkVerificationConfirmAttempt(ipAddress: String?, account: String, now _: Date) async throws {
        try await check(scope: "verification_confirm:ip", key: normalize(ipAddress: ipAddress), rule: verificationConfirmIPRule)
        try await check(scope: "verification_confirm:account", key: account, rule: verificationConfirmAccountRule)
    }

    private func check(scope: String, key: String, rule: Rule) async throws {
        let redisKey = RedisKey("\(keyPrefix):\(scope):\(key)")
        let count = try await pool.increment(redisKey).get()
        if count == 1 {
            _ = try await pool.expire(redisKey, after: .seconds(rule.window)).get()
        }
        guard count <= rule.maxAttempts else {
            let lifetime = try await pool.ttl(redisKey).get()
            let retryAfter: Int
            switch lifetime {
            case .limited(.seconds(let seconds)):
                retryAfter = max(1, Int(seconds))
            case .limited(.milliseconds(let milliseconds)):
                retryAfter = max(1, Int(ceil(Double(milliseconds) / 1000.0)))
            case .keyDoesNotExist, .unlimited:
                retryAfter = max(1, Int(rule.window))
            }
            throw LoginRateLimitError(scopeDescription: rule.scopeDescription, retryAfter: retryAfter)
        }
    }

    private func normalize(ipAddress: String?) -> String {
        let trimmed = ipAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "unknown" : trimmed
    }
}

final class AuthRateLimiterLifecycle: LifecycleHandler {
    private let limiter: RedisAuthRateLimiter

    init(limiter: RedisAuthRateLimiter) {
        self.limiter = limiter
    }

    func shutdown(_ application: Application) {
        _ = application
        Task {
            await self.limiter.shutdown()
        }
    }
}

enum AuthRateLimiterFactory {
    static func make(app: Application, configuration: AuthSecurityConfiguration) async throws -> any AuthRateLimiting {
        switch configuration.rateLimitBackend {
        case .memory:
            return AuthLoginRateLimiter()
        case .redis:
            let redisURL = try configuration.redisURL.unwrap(or: AuthConfigurationError.missingRedisURL)
            let limiter = try RedisAuthRateLimiter(
                redisURL: redisURL,
                logger: app.logger,
                eventLoop: app.eventLoopGroup.next()
            )
            try await limiter.start()
            app.lifecycle.use(AuthRateLimiterLifecycle(limiter: limiter))
            return limiter
        }
    }
}

private struct AuthLoginRateLimiterStorageKey: StorageKey {
    typealias Value = any AuthRateLimiting
}

extension Application {
    var authLoginRateLimiter: any AuthRateLimiting {
        get {
            if let limiter = self.storage[AuthLoginRateLimiterStorageKey.self] {
                return limiter
            }

            let limiter = AuthLoginRateLimiter()
            self.storage[AuthLoginRateLimiterStorageKey.self] = limiter
            return limiter
        }
        set {
            self.storage[AuthLoginRateLimiterStorageKey.self] = newValue
        }
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> any Error) throws -> Wrapped {
        guard let value = self else {
            throw error()
        }
        return value
    }
}

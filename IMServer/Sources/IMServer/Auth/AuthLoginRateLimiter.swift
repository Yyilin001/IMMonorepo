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

actor AuthLoginRateLimiter {
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

    private var ipAttempts: [String: [Date]] = [:]
    private var accountAttempts: [String: [Date]] = [:]
    private var registrationIPAttempts: [String: [Date]] = [:]
    private var registrationAccountAttempts: [String: [Date]] = [:]
    private var pendingReservations: [UUID: PendingReservation] = [:]
    private var pendingIPCounts: [String: Int] = [:]
    private var pendingAccountCounts: [String: Int] = [:]
    private var pendingRegistrationIPCounts: [String: Int] = [:]
    private var pendingRegistrationAccountCounts: [String: Int] = [:]

    func beginLoginAttempt(ipAddress: String?, account: String, now: Date) throws -> LoginAttemptReservation {
        try beginAttempt(kind: .login, ipAddress: ipAddress, account: account, now: now)
    }

    func beginRegistrationAttempt(ipAddress: String?, account: String, now: Date) throws -> LoginAttemptReservation {
        try beginAttempt(kind: .registration, ipAddress: ipAddress, account: account, now: now)
    }

    func completeLoginAttempt(_ reservation: LoginAttemptReservation, succeeded: Bool, now: Date) {
        completeAttempt(reservation, expectedKind: .login, succeeded: succeeded, now: now)
    }

    func completeRegistrationAttempt(_ reservation: LoginAttemptReservation, succeeded: Bool, now: Date) {
        completeAttempt(reservation, expectedKind: .registration, succeeded: succeeded, now: now)
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

private struct AuthLoginRateLimiterStorageKey: StorageKey {
    typealias Value = AuthLoginRateLimiter
}

extension Application {
    var authLoginRateLimiter: AuthLoginRateLimiter {
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

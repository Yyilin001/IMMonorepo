import Crypto
import Foundation
import IMV2Core
import IMV2ServerContracts

/// 管理用例统一执行认证与授权，HTTP 层不能自行拼装操作主体。
public struct V2AdminService: Sendable {
    private let accounts: [String: V2AdminAccount]
    private let store: any V2AdminStore
    private let passwords: any V2PasswordHashing
    private let disableAccount: @Sendable (String, V2AccountDisableCommand) async throws -> V2AccountDisableOutcome
    private let now: @Sendable () -> Date
    public let sessionLifetime: TimeInterval = 1_800

    public init(accounts: [V2AdminAccount], store: any V2AdminStore, passwords: any V2PasswordHashing,
                now: @escaping @Sendable () -> Date = Date.init,
                disableAccount: @escaping @Sendable (String, V2AccountDisableCommand) async throws -> V2AccountDisableOutcome) throws {
        guard !accounts.isEmpty, accounts.count <= 100,
              Set(accounts.map(\.username)).count == accounts.count,
              accounts.allSatisfy({ Self.validUsername($0.username) && V2PasswordHashPolicy.supports($0.passwordHash) }) else {
            throw V2AdminError.invalidInput
        }
        self.accounts = Dictionary(uniqueKeysWithValues: accounts.map { ($0.username, $0) })
        self.store = store; self.passwords = passwords; self.disableAccount = disableAccount; self.now = now
    }

    public static func validUsername(_ value: String) -> Bool {
        (3...64).contains(value.utf8.count) && value.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 || $0 == 46
        }
    }

    public func login(username: String, password: String, replacing oldToken: String?) async throws -> (token: String, identity: V2AdminIdentity) {
        guard username.utf8.count <= 64, password.utf8.count <= 1_024 else { throw V2AdminError.invalidInput }
        let account = accounts[username]
        guard try await store.consumeLoginBudget(username: account?.username, now: now()) else { throw V2AdminError.rateLimited }
        let validPassword = V2PasswordHashPolicy.accepts(password)
        let matches = try await passwords.verify(validPassword ? password : "invalid-password-input", created: account?.passwordHash ?? V2PasswordHashPolicy.dummyDigest)
        guard let account, validPassword, matches else {
            try await store.record(principal: account.map { "admin:\($0.username)" }, action: "login", target: nil, outcome: "rejected", now: now())
            throw V2AdminError.unauthorized
        }
        let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
        let expires = now().addingTimeInterval(sessionLifetime)
        try await store.createSession(.init(digest: Self.digest(token), username: username,
            credentialVersion: Self.version(account), expiresAt: expires), replacing: tokenDigest(token: oldToken), now: now())
        return (token, .init(username: username, role: account.role, expiresAt: expires))
    }

    public func identity(token: String?) async throws -> V2AdminIdentity {
        guard let digest = tokenDigest(token: token), let session = try await store.session(digest: digest, now: now()),
              let account = accounts[session.username], session.credentialVersion == Self.version(account), session.expiresAt > now() else {
            throw V2AdminError.unauthorized
        }
        return .init(username: account.username, role: account.role, expiresAt: session.expiresAt)
    }

    public func logout(token: String?) async throws {
        let identity = try await identity(token: token)
        guard let digest = tokenDigest(token: token) else { throw V2AdminError.unauthorized }
        try await store.revokeSession(digest: digest, principal: identity.principal, now: now())
    }

    public func users(token: String?, query: String, after: UUID?, limit: Int) async throws -> [V2AdminUser] {
        let identity = try await identity(token: token)
        guard query.utf8.count <= 80, (1...50).contains(limit) else { throw V2AdminError.invalidInput }
        let rows = try await store.users(query: query, after: after, limit: limit)
        try await store.record(principal: identity.principal, action: "users_search", target: nil, outcome: "succeeded", now: now())
        return rows
    }

    public func user(token: String?, id: UUID) async throws -> V2AdminUser {
        let identity = try await identity(token: token)
        guard let user = try await store.user(id: id) else { throw V2AdminError.notFound }
        try await store.record(principal: identity.principal, action: "user_view", target: id, outcome: "succeeded", now: now())
        return user
    }

    public func disable(token: String?, id: UUID, userID: UUID, reason: V2AccountDisableReason) async throws -> V2AdminAudit {
        let identity = try await identity(token: token)
        guard identity.role == .operatorRole else {
            try await store.record(principal: identity.principal, action: "account_disable", target: userID, outcome: "forbidden", now: now())
            throw V2AdminError.forbidden
        }
        // 先持久化不可变意图。任何未知结果均保留 pending，用相同 ID 恢复 Owner 原回执。
        let prepared = try await store.prepareDisable(id: id, principal: identity.principal, target: userID, reason: reason, now: now())
        guard prepared.outcome == "pending" else { return prepared }
        let result = try await disableAccount(identity.principal, .init(userID: .init(userID.uuidString), operationID: id, reason: reason))
        let outcome: String
        switch result {
        case .disabled, .idempotent: outcome = "disabled"
        case .alreadyDisabled: outcome = "already_disabled"
        }
        return try await store.finishDisable(id: id, outcome: outcome, now: now())
    }

    public func audit(token: String?, id: UUID) async throws -> V2AdminAudit {
        _ = try await identity(token: token)
        guard let row = try await store.audit(id: id) else { throw V2AdminError.notFound }
        return row
    }

    public func audits(token: String?, before: Int64?, target: UUID?, limit: Int) async throws -> [V2AdminAudit] {
        _ = try await identity(token: token)
        guard (1...50).contains(limit), before.map({ $0 > 0 }) ?? true else { throw V2AdminError.invalidInput }
        return try await store.audits(before: before, target: target, limit: limit)
    }

    private func tokenDigest(token: String?) -> String? {
        guard let token, token.count == 64, token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return Self.digest(token)
    }
    private static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func version(_ account: V2AdminAccount) -> String { digest(account.username + ":" + account.passwordHash + ":" + account.role.rawValue) }
}

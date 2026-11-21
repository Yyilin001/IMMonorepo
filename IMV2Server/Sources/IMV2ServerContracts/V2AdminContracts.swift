import Foundation

public enum V2AdminRole: String, Codable, Sendable { case viewer, operatorRole = "operator" }

/// 由受信部署配置提供，不接受浏览器指定角色或操作主体。
public struct V2AdminAccount: Codable, Sendable {
    public let username: String
    public let passwordHash: String
    public let role: V2AdminRole
    public init(username: String, passwordHash: String, role: V2AdminRole) {
        self.username = username; self.passwordHash = passwordHash; self.role = role
    }
}

public struct V2AdminIdentity: Codable, Sendable, Equatable {
    public let username: String
    public let role: V2AdminRole
    public let expiresAt: Date
    public init(username: String, role: V2AdminRole, expiresAt: Date) {
        self.username = username; self.role = role; self.expiresAt = expiresAt
    }
    public var principal: String { "admin:\(username)" }
}

public struct V2AdminSession: Sendable {
    public let digest: String
    public let username: String
    public let credentialVersion: String
    public let expiresAt: Date
    public init(digest: String, username: String, credentialVersion: String, expiresAt: Date) {
        self.digest = digest; self.username = username; self.credentialVersion = credentialVersion; self.expiresAt = expiresAt
    }
}

public struct V2AdminUser: Codable, Sendable {
    public let userID: UUID
    public let publicHandle: String
    public let displayName: String
    public let state: String
    public let accountKind: String
    public let createdAt: Date
    public let disabledAt: Date?
    public let activeDevices: Int
    public init(userID: UUID, publicHandle: String, displayName: String, state: String, accountKind: String,
                createdAt: Date, disabledAt: Date?, activeDevices: Int) {
        self.userID = userID; self.publicHandle = publicHandle; self.displayName = displayName
        self.state = state; self.accountKind = accountKind; self.createdAt = createdAt
        self.disabledAt = disabledAt; self.activeDevices = activeDevices
    }
}

public struct V2AdminAudit: Codable, Sendable, Equatable {
    public let sequence: String
    public let operationID: UUID
    public let principal: String?
    public let action: String
    public let targetUserID: UUID?
    public let reason: String?
    public let outcome: String
    public let occurredAt: Date
    public let completedAt: Date?
    public init(sequence: String, operationID: UUID, principal: String?, action: String, targetUserID: UUID?,
                reason: String?, outcome: String, occurredAt: Date, completedAt: Date?) {
        self.sequence = sequence; self.operationID = operationID; self.principal = principal; self.action = action
        self.targetUserID = targetUserID; self.reason = reason; self.outcome = outcome
        self.occurredAt = occurredAt; self.completedAt = completedAt
    }
}

public enum V2AdminError: Error, Sendable { case unauthorized, forbidden, invalidInput, notFound, conflict, rateLimited, unavailable }

public protocol V2AdminStore: Sendable {
    func consumeLoginBudget(username: String?, now: Date) async throws -> Bool
    func createSession(_ session: V2AdminSession, replacing digest: String?, now: Date) async throws
    func session(digest: String, now: Date) async throws -> V2AdminSession?
    func revokeSession(digest: String, principal: String, now: Date) async throws
    func users(query: String, after: UUID?, limit: Int) async throws -> [V2AdminUser]
    func user(id: UUID) async throws -> V2AdminUser?
    func record(principal: String?, action: String, target: UUID?, outcome: String, now: Date) async throws
    func prepareDisable(id: UUID, principal: String, target: UUID, reason: V2AccountDisableReason, now: Date) async throws -> V2AdminAudit
    func finishDisable(id: UUID, outcome: String, now: Date) async throws -> V2AdminAudit
    func audit(id: UUID) async throws -> V2AdminAudit?
    func audits(before: Int64?, target: UUID?, limit: Int) async throws -> [V2AdminAudit]
}

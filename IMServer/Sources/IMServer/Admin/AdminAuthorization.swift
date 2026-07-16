import Vapor

enum AdminRole: String, CaseIterable, Codable, Sendable {
    case superAdmin = "super_admin"
    case moderator
    case support

    var permissions: Set<AdminPermission> {
        switch self {
        case .superAdmin:
            Set(AdminPermission.allCases)
        case .moderator:
            [.reportsRead, .reportsWrite]
        case .support:
            [.overviewRead, .usersRead, .conversationsInspect]
        }
    }
}

enum AdminPermission: String, CaseIterable, Sendable {
    case overviewRead = "overview.read"
    case usersRead = "users.read"
    case usersInspectSecurity = "users.inspect_security"
    case usersWriteStatus = "users.write_status"
    case usersWriteRole = "users.write_role"
    case conversationsInspect = "conversations.inspect"
    case messagesInspect = "messages.inspect"
    case conversationsWriteGovernance = "conversations.write_governance"
    case reportsRead = "reports.read"
    case reportsWrite = "reports.write"
    case auditRead = "audit.read"
}

struct AdminAccessContext: Sendable {
    let actor: String
    let role: AdminRole
    let userID: UUID?
    let authenticationMethod: AuthenticationMethod

    enum AuthenticationMethod: String, Sendable {
        case sharedSecret = "shared_secret"
        case accessToken = "access_token"
    }

    func requires(_ permission: AdminPermission) throws {
        guard role.permissions.contains(permission) else {
            throw Abort(.forbidden, reason: "当前管理员角色无权执行该操作。")
        }
    }
}

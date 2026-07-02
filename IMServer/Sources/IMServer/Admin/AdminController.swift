import Fluent
import Vapor

struct AdminController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("admin", use: adminConsole)

        let api = routes.grouped("admin", "api")
        api.get("overview", use: overview)
        api.get("users", use: users)
        api.patch("users", ":userID", "status", use: updateUserStatus)
        api.get("reports", use: reports)
        api.patch("reports", ":reportID", use: updateReport)
        api.get("audit-events", use: auditEvents)
    }

    func adminConsole(req: Request) throws -> Response {
        guard req.application.adminConfiguration.isEnabled else {
            throw Abort(.notFound)
        }
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/html; charset=utf-8")]),
            body: .init(string: AdminConsoleHTML.page)
        )
    }

    func overview(req: Request) async throws -> AdminOverviewResponse {
        try requireAdminAccess(req)

        async let totalUsers = User.query(on: req.db).count()
        async let activeUsers = User.query(on: req.db).filter(\.$status == UserStatus.active.rawValue).count()
        async let disabledUsers = User.query(on: req.db).filter(\.$status == UserStatus.disabled.rawValue).count()
        async let activeSessions = AuthSession.query(on: req.db).filter(\.$revokedAt == nil).count()
        async let pendingReports = UserReport.query(on: req.db).filter(\.$status == "pending").count()
        async let reviewingReports = UserReport.query(on: req.db).filter(\.$status == "reviewing").count()

        let userCounts = AdminOverviewResponse.UserCounts(
            total: try await totalUsers,
            active: try await activeUsers,
            disabled: try await disabledUsers
        )
        let reportCounts = AdminOverviewResponse.ReportCounts(
            pending: try await pendingReports,
            reviewing: try await reviewingReports
        )
        let activeSessionCount = try await activeSessions

        return AdminOverviewResponse(
            users: userCounts,
            activeSessions: activeSessionCount,
            reports: reportCounts
        )
    }

    func users(req: Request) async throws -> AdminUserPageResponse {
        try requireAdminAccess(req)
        let query = try req.query.decode(AdminUserPageQuery.self)
        let limit = max(1, min(query.limit ?? 50, 100))
        let offset = max(0, query.cursor.flatMap(Int.init) ?? 0)
        let status = query.status?.trimmedNonEmpty
        let searchTerm = query.query?.trimmedNonEmpty?.lowercased()

        let builder = User.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
        if let status {
            builder.filter(\.$status == status)
        }

        if let searchTerm {
            let allRows = try await builder.all()
            let filteredRows = allRows.filter { user in
                user.email.lowercased().contains(searchTerm)
                    || (user.displayName?.lowercased().contains(searchTerm) ?? false)
                    || (user.id?.uuidString.lowercased().contains(searchTerm) ?? false)
            }
            let page = Array(filteredRows.dropFirst(offset).prefix(limit))
            let nextOffset = offset + page.count
            return try AdminUserPageResponse(
                items: page.map(AdminUserResponse.init(user:)),
                nextCursor: nextOffset < filteredRows.count ? "\(nextOffset)" : nil,
                hasMore: nextOffset < filteredRows.count
            )
        }

        let rows = try await builder.range(offset..<(offset + limit + 1)).all()
        let page = Array(rows.prefix(limit))
        let nextOffset = offset + page.count
        return try AdminUserPageResponse(
            items: page.map(AdminUserResponse.init(user:)),
            nextCursor: rows.count > limit ? "\(nextOffset)" : nil,
            hasMore: rows.count > limit
        )
    }

    func updateUserStatus(req: Request) async throws -> AdminUserResponse {
        let actor = try requireAdminAccess(req)
        guard let rawID = req.parameters.get("userID"), let userID = UUID(uuidString: rawID) else {
            throw Abort(.badRequest, reason: "用户 ID 无效。")
        }

        let body = try req.content.decode(AdminUserStatusUpdateRequest.self)
        let status = body.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let statusEnum = UserStatus(rawValue: status) else {
            throw Abort(.badRequest, reason: "用户状态无效。")
        }
        guard let user = try await User.find(userID, on: req.db) else {
            throw Abort(.notFound, reason: "用户不存在。")
        }

        let previousStatus = user.status
        user.status = statusEnum.rawValue
        try await user.update(on: req.db)

        var revokedSessions = 0
        if statusEnum == .disabled {
            let response = try await AuthService(app: req.application, db: req.db).logoutAll(userID: userID)
            revokedSessions = response.revokedSessions
        }

        try await recordAudit(
            req,
            actor: actor,
            action: "user.status.update",
            targetType: "user",
            targetID: userID.uuidString,
            metadata: [
                "previousStatus": previousStatus,
                "status": statusEnum.rawValue,
                "revokedSessions": "\(revokedSessions)",
                "note": body.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ]
        )

        return try AdminUserResponse(user: user)
    }

    func reports(req: Request) async throws -> ReportPageResponse {
        try requireAdminAccess(req)
        let query = try req.query.decode(ReportPageQuery.self)
        let limit = max(1, min(query.limit ?? 50, 100))
        let offset = max(0, query.cursor.flatMap(Int.init) ?? 0)
        let builder = UserReport.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
        if let status = query.status?.trimmedNonEmpty {
            builder.filter(\.$status == status.lowercased())
        }
        if let targetType = query.targetType?.trimmedNonEmpty {
            builder.filter(\.$targetType == targetType.lowercased())
        }

        let rows = try await builder.range(offset..<(offset + limit + 1)).all()
        let page = Array(rows.prefix(limit))
        let nextOffset = offset + page.count
        return ReportPageResponse(
            items: try page.map(Self.response(from:)),
            nextCursor: rows.count > limit ? "\(nextOffset)" : nil,
            hasMore: rows.count > limit
        )
    }

    func updateReport(req: Request) async throws -> ReportResponse {
        let actor = try requireAdminAccess(req)
        guard let rawID = req.parameters.get("reportID"), let reportID = UUID(uuidString: rawID) else {
            throw Abort(.badRequest, reason: "举报 ID 无效。")
        }
        let body = try req.content.decode(ReportUpdateRequest.self)
        let status = body.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["pending", "reviewing", "resolved", "rejected"].contains(status) else {
            throw Abort(.badRequest, reason: "举报状态无效。")
        }
        guard let report = try await UserReport.find(reportID, on: req.db) else {
            throw Abort(.notFound, reason: "举报记录不存在。")
        }

        let previousStatus = report.status
        report.status = status
        report.handledNote = body.handledNote?.trimmedNonEmpty
        try await report.update(on: req.db)

        try await recordAudit(
            req,
            actor: actor,
            action: "report.status.update",
            targetType: "report",
            targetID: reportID.uuidString,
            metadata: [
                "previousStatus": previousStatus,
                "status": status,
                "handledNote": report.handledNote ?? ""
            ]
        )

        return try Self.response(from: report)
    }

    func auditEvents(req: Request) async throws -> AdminAuditEventPageResponse {
        try requireAdminAccess(req)
        let query = try req.query.decode(AdminAuditEventPageQuery.self)
        let limit = max(1, min(query.limit ?? 50, 100))
        let offset = max(0, query.cursor.flatMap(Int.init) ?? 0)
        let builder = AdminAuditEvent.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
        if let action = query.action?.trimmedNonEmpty {
            builder.filter(\.$action == action)
        }

        let rows = try await builder.range(offset..<(offset + limit + 1)).all()
        let page = Array(rows.prefix(limit))
        let nextOffset = offset + page.count
        return try AdminAuditEventPageResponse(
            items: page.map(AdminAuditEventResponse.init(event:)),
            nextCursor: rows.count > limit ? "\(nextOffset)" : nil,
            hasMore: rows.count > limit
        )
    }

    @discardableResult
    private func requireAdminAccess(_ req: Request) throws -> String {
        let configuration = req.application.adminConfiguration
        guard configuration.isEnabled else {
            throw Abort(.notFound)
        }

        let actor = req.headers.first(name: "X-IM-Admin-Actor")?.trimmedNonEmpty ?? "admin"
        guard let expectedSecret = configuration.sharedSecret?.trimmedNonEmpty else {
            guard req.application.environment != .production else {
                throw Abort(.internalServerError, reason: "IM_ADMIN_SHARED_SECRET is required when admin API is enabled in production.")
            }
            return actor
        }

        let providedSecret = req.headers.first(name: "X-IM-Admin-Secret")
            ?? bearerToken(from: req.headers.first(name: .authorization))
        guard providedSecret == expectedSecret else {
            throw Abort(.unauthorized, reason: "Invalid admin secret.")
        }
        return actor
    }

    private func recordAudit(
        _ req: Request,
        actor: String,
        action: String,
        targetType: String?,
        targetID: String?,
        metadata: [String: String] = [:]
    ) async throws {
        let event = AdminAuditEvent(
            actor: actor,
            action: action,
            targetType: targetType,
            targetID: targetID,
            requestID: req.headers.first(name: "X-Request-ID"),
            ipAddress: req.remoteAddress?.ipAddress,
            metadataJSON: metadata.isEmpty ? nil : try Self.encodeMetadata(metadata)
        )
        try await event.save(on: req.db)
    }

    private static func encodeMetadata(_ metadata: [String: String]) throws -> String {
        let data = try JSONEncoder().encode(metadata)
        return String(decoding: data, as: UTF8.self)
    }

    private func bearerToken(from authorization: String?) -> String? {
        guard let authorization else {
            return nil
        }
        let prefix = "Bearer "
        guard authorization.hasPrefix(prefix) else {
            return nil
        }
        return String(authorization.dropFirst(prefix.count))
    }

    private static func response(from report: UserReport) throws -> ReportResponse {
        ReportResponse(
            id: try report.requireID(),
            targetType: report.targetType,
            targetID: report.targetID,
            reporterUserID: report.reporterUserID,
            conversationID: report.conversationID,
            messageID: report.messageID,
            reason: report.reason,
            detail: report.detail,
            status: report.status,
            handledNote: report.handledNote,
            messageSnapshotJSON: report.messageSnapshotJSON,
            createdAt: report.createdAt
        )
    }
}

struct AdminOverviewResponse: Content, Equatable, Sendable {
    struct UserCounts: Content, Equatable, Sendable {
        let total: Int
        let active: Int
        let disabled: Int
    }

    struct ReportCounts: Content, Equatable, Sendable {
        let pending: Int
        let reviewing: Int
    }

    let users: UserCounts
    let activeSessions: Int
    let reports: ReportCounts
}

struct AdminUserPageQuery: Content {
    let query: String?
    let status: String?
    let cursor: String?
    let limit: Int?
}

struct AdminUserResponse: Content, Equatable, Sendable {
    let id: UUID
    let email: String
    let status: String
    let displayName: String?
    let avatarPreset: String?
    let adminRole: String?
    let createdAt: Date?
    let updatedAt: Date?

    init(user: User) throws {
        id = try user.requireID()
        email = user.email
        status = user.status
        displayName = user.displayName
        avatarPreset = user.avatarPreset
        adminRole = user.adminRole
        createdAt = user.createdAt
        updatedAt = user.updatedAt
    }
}

struct AdminUserPageResponse: Content, Equatable, Sendable {
    let items: [AdminUserResponse]
    let nextCursor: String?
    let hasMore: Bool
}

struct AdminUserStatusUpdateRequest: Content {
    let status: String
    let note: String?
}

struct AdminAuditEventPageQuery: Content {
    let action: String?
    let cursor: String?
    let limit: Int?
}

struct AdminAuditEventResponse: Content, Equatable, Sendable {
    let id: UUID
    let actor: String
    let action: String
    let targetType: String?
    let targetID: String?
    let requestID: String?
    let ipAddress: String?
    let metadataJSON: String?
    let createdAt: Date?

    init(event: AdminAuditEvent) throws {
        id = try event.requireID()
        actor = event.actor
        action = event.action
        targetType = event.targetType
        targetID = event.targetID
        requestID = event.requestID
        ipAddress = event.ipAddress
        metadataJSON = event.metadataJSON
        createdAt = event.createdAt
    }
}

struct AdminAuditEventPageResponse: Content, Equatable, Sendable {
    let items: [AdminAuditEventResponse]
    let nextCursor: String?
    let hasMore: Bool
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

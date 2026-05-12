import Fluent
import Vapor

struct InternalReportsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let internalRoutes = routes.grouped("internal")
        internalRoutes.get("reports", use: reports)
        internalRoutes.patch("reports", ":reportID", use: updateReport)
    }

    func reports(req: Request) async throws -> ReportPageResponse {
        try requireInternalSecret(req)
        let query = try req.query.decode(ReportPageQuery.self)
        let limit = max(1, min(query.limit ?? 50, 100))
        let offset = max(0, query.cursor.flatMap(Int.init) ?? 0)
        let builder = UserReport.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
        if let status = query.status?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty {
            builder.filter(\.$status == status)
        }
        if let targetType = query.targetType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !targetType.isEmpty {
            builder.filter(\.$targetType == targetType)
        }
        let rows = try await builder.all()
        let page = Array(rows.dropFirst(offset).prefix(limit))
        let nextOffset = offset + page.count
        return ReportPageResponse(
            items: try page.map(Self.response(from:)),
            nextCursor: nextOffset < rows.count ? "\(nextOffset)" : nil,
            hasMore: nextOffset < rows.count
        )
    }

    func updateReport(req: Request) async throws -> ReportResponse {
        try requireInternalSecret(req)
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
        report.status = status
        report.handledNote = body.handledNote?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        try await report.update(on: req.db)
        return try Self.response(from: report)
    }

    private func requireInternalSecret(_ req: Request) throws {
        let expected = Environment.get("IM_COMMAND_INTERNAL_SHARED_SECRET")
            ?? Environment.get("IM_INTERNAL_SHARED_SECRET")
        guard let expected, !expected.isEmpty else {
            if req.application.environment == .production {
                throw Abort(.internalServerError, reason: "IM_INTERNAL_SHARED_SECRET is required in production.")
            }
            return
        }
        guard req.headers.first(name: "X-IM-Internal-Secret") == expected else {
            throw Abort(.unauthorized, reason: "Invalid internal secret.")
        }
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

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

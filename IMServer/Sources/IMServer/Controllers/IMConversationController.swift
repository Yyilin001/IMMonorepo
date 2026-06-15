import Vapor

struct IMConversationController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        try registerCommandRoutes(on: routes)
        try registerQueryRoutes(on: routes)
    }

    func registerCommandRoutes(on routes: any RoutesBuilder) throws {
        let protected = routes.grouped("api", "im")
            .grouped(
                AccessTokenAuthenticator(),
                User.guardMiddleware(throwing: Abort(.unauthorized, reason: "用户未登录。"))
            )

        IMConversationCommandRoute.registerControllerRoutes(on: protected, controller: self)
    }

    func registerQueryRoutes(on routes: any RoutesBuilder) throws {
        let protected = routes.grouped("api", "im")
            .grouped(
                AccessTokenAuthenticator(),
                User.guardMiddleware(throwing: Abort(.unauthorized, reason: "用户未登录。"))
            )

        protected.get("conversations", use: conversations)
        protected.get("conversations", "changes", use: conversationChanges)
        protected.get("domain-events", use: domainEventChanges)
        protected.get("conversations", ":conversationID", "members", use: members)
        protected.get("conversations", ":conversationID", "timeline", use: timeline)
        protected.get("conversations", ":conversationID", "timeline", "since", use: timelineSince)
        protected.get("conversations", ":conversationID", "receipts", "summary", use: receiptSummary)
        protected.get("conversations", ":conversationID", "search", use: searchMessages)
        protected.get("conversations", ":conversationID", "messages", ":messageID", "stream", use: messageStreamSnapshot)
        protected.get("favorites", use: favorites)
        protected.post("client-health", use: reportClientHealth)
    }

    func reportClientHealth(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        let report = try req.content.decode(IMClientHealthReportRequest.self)
        try validateClientHealthReport(report)
        await req.application.clientHealthMetrics.record(userID: userID, report: report)
        return .noContent
    }

    private func validateClientHealthReport(_ report: IMClientHealthReportRequest) throws {
        let trimmedReason = report.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty, trimmedReason.count <= 64 else {
            throw Abort(.badRequest, reason: "客户端健康上报 reason 无效。")
        }
        guard report.snapshot.deferredDomainEventCount >= 0,
              report.snapshot.fullRefreshConversationCount >= 0
        else {
            throw Abort(.badRequest, reason: "客户端健康上报计数无效。")
        }
        if let diagnostics = report.snapshot.timelineCatchUpDiagnostics {
            guard diagnostics.hintQueuedCount >= 0,
                  diagnostics.hintSkippedAlreadyLoadedCount >= 0,
                  diagnostics.deferredCount >= 0,
                  diagnostics.sinceRequestCount >= 0,
                  diagnostics.sinceSuccessCount >= 0,
                  diagnostics.sinceFailureCount >= 0,
                  diagnostics.appliedPageCount >= 0,
                  diagnostics.appliedItemCount >= 0
            else {
                throw Abort(.badRequest, reason: "客户端 timeline 补洞健康上报计数无效。")
            }
        }
        if let configuration = report.snapshot.timelineCatchUpConfiguration {
            let maximumMilliseconds = 600_000
            guard (0...maximumMilliseconds).contains(configuration.selectedHintInitialJitterMilliseconds),
                  (0...maximumMilliseconds).contains(configuration.selectedHintMinimumIntervalMilliseconds),
                  (0...maximumMilliseconds).contains(configuration.selectedHintMicroBatchMilliseconds)
            else {
                throw Abort(.badRequest, reason: "客户端 timeline 补洞配置上报无效。")
            }
        }
    }
}

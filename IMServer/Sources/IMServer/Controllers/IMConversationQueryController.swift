import Vapor

extension IMConversationController {
    func conversations(req: Request) async throws -> IMConversationPageResponse {
        let user = try req.auth.require(User.self)
        let query = try req.query.decode(IMConversationPageQuery.self)
        return try await QueryReadModelFacade(app: req.application)
            .listConversations(
                for: try user.requireID(),
                cursor: query.cursor,
                limit: query.limit,
                kind: query.kind
            )
    }

    func conversationChanges(req: Request) async throws -> IMConversationChangesResponse {
        let user = try req.auth.require(User.self)
        let query = try req.query.decode(IMConversationChangesQuery.self)
        return try await QueryReadModelFacade(app: req.application)
            .listConversationChanges(
                for: try user.requireID(),
                afterToken: query.afterToken,
                cursor: query.cursor,
                limit: query.limit
            )
    }

    func domainEventChanges(req: Request) async throws -> DomainEventChangesResponse {
        let user = try req.auth.require(User.self)
        let query = try req.query.decode(IMDomainEventChangesQuery.self)
        return try await OwnerDomainEventDeliveryService(
            db: req.application.summaryShardRouter.database(forOwnerUserID: try user.requireID())
        ).list(
            ownerUserID: try user.requireID(),
            afterCursor: query.after ?? 0,
            limit: query.limit
        )
    }

    func members(req: Request) async throws -> IMConversationMemberPageResponse {
        let user = try req.auth.require(User.self)
        let query = try req.query.decode(IMConversationMemberPageQuery.self)
        guard
            let rawConversationID = req.parameters.get("conversationID"),
            let conversationID = UUID(uuidString: rawConversationID)
        else {
            throw Abort(.badRequest, reason: "会话 ID 无效。")
        }

        return try await QueryReadModelFacade(app: req.application)
            .listMemberPage(
                in: conversationID,
                for: try user.requireID(),
                cursor: query.cursor,
                limit: query.limit,
                query: query.q
            )
    }

    func searchMessages(req: Request) async throws -> IMConversationMessageSearchPageResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let query = try req.query.decode(IMMessageSearchQuery.self)

        return try await QueryReadModelFacade(app: req.application)
            .searchMessages(
                in: conversationID,
                for: try user.requireID(),
                query: query.q,
                cursor: query.cursor,
                limit: query.limit
            )
    }

    func timeline(req: Request) async throws -> IMTimelinePageResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let query = try req.query.decode(IMMessageHistoryQuery.self)

        return try await QueryReadModelFacade(app: req.application)
            .listTimeline(
                in: conversationID,
                for: try user.requireID(),
                beforeSequence: try query.beforeSequence.map {
                    try imIntSequence($0, field: "beforeSequence")
                },
                limit: query.limit
            )
    }

    func timelineSince(req: Request) async throws -> IMTimelinePageResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let query = try req.query.decode(IMTimelineSinceQuery.self)

        return try await QueryReadModelFacade(app: req.application)
            .listTimelineSince(
                in: conversationID,
                for: try user.requireID(),
                afterSequence: try imIntSequence(query.afterSequence, field: "afterSequence"),
                limit: query.limit
            )
    }
}

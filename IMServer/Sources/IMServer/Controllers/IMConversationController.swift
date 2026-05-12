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
        protected.get("conversations", ":conversationID", "members", use: members)
        protected.get("conversations", ":conversationID", "messages", use: messages)
        protected.get("conversations", ":conversationID", "receipts", "summary", use: receiptSummary)
        protected.get("conversations", ":conversationID", "search", use: searchMessages)
        protected.get("conversations", ":conversationID", "messages", "since", use: messagesSince)
        protected.get("favorites", use: favorites)
    }
}

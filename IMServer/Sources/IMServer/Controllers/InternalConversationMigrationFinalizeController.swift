import Vapor

/// Rebuilds target-local derived search state while the source owns the
/// cutover lease. The target never changes `conversation_directory` itself.
struct InternalConversationMigrationFinalizeController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("internal", "im", "migrations")
            .post("target-finalize", use: targetFinalize)
    }

    func targetFinalize(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(IMCellConversationMigrationFinalizeRequest.self)
        let migration = try await InternalConversationMigrationIngressAuthorization.validate(
            req: req,
            conversationID: body.conversationID,
            originCellID: body.originCellID,
            targetCellID: body.targetCellID,
            targetShardID: body.targetShardID,
            sourceRouteVersion: body.sourceRouteVersion,
            transferToken: body.transferToken,
            allowedStatuses: [.cutoverPreparing]
        )
        guard migration.cutoverLeaseToken == body.cutoverLeaseToken,
              let leaseExpiresAt = migration.cutoverLeaseExpiresAt,
              leaseExpiresAt > Date(),
              req.application.conversationShardRouter.shardIDs.contains(body.targetShardID)
        else {
            throw Abort(.conflict, reason: "Remote target finalization does not own the active cutover lease.")
        }
        try await ConversationShardMigrationSearchIndexRebuilder.rebuild(
            app: req.application,
            conversationID: body.conversationID,
            database: req.application.conversationShardRouter.commandDatabase(forShardID: body.targetShardID),
            pageSize: min(max(body.pageSize, 1), 1_000)
        )
        return .noContent
    }
}

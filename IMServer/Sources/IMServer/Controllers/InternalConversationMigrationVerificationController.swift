import Fluent
import Vapor

/// Returns target canonical state for a source-owned migration verification.
/// No route change happens here; the source still performs the final fenced
/// directory CAS after comparing the returned fingerprint.
struct InternalConversationMigrationVerificationController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("internal", "im", "migrations")
            .post("target-verification", use: targetVerification)
    }

    func targetVerification(req: Request) async throws -> IMCellConversationMigrationVerificationResponse {
        let body = try req.content.decode(IMCellConversationMigrationVerificationRequest.self)
        _ = try await InternalConversationMigrationIngressAuthorization.validate(
            req: req,
            conversationID: body.conversationID,
            originCellID: body.originCellID,
            targetCellID: body.targetCellID,
            targetShardID: body.targetShardID,
            sourceRouteVersion: body.sourceRouteVersion,
            transferToken: body.transferToken,
            allowedStatuses: [.verifying, .cutoverPreparing]
        )
        guard req.application.conversationShardRouter.shardIDs.contains(body.targetShardID) else {
            throw Abort(.badRequest, reason: "Unknown target conversation shard: \(body.targetShardID)")
        }
        let pageSize = min(max(body.pageSize, 1), 1_000)
        let database = req.application.conversationShardRouter.commandDatabase(forShardID: body.targetShardID)
        let eventIDs = try await ConversationDomainEvent.query(on: database)
            .filter(\.$conversationID == body.conversationID)
            .all()
            .compactMap(\.id)
        let sideEffectCount = eventIDs.isEmpty ? 0 : try await ConversationDomainEventSideEffect.query(on: database)
            .filter(\.$eventID ~~ eventIDs)
            .count()
        return try await IMCellConversationMigrationVerificationResponse(
            snapshot: ConversationShardMigrationPreflight(app: req.application).snapshot(
                conversationID: body.conversationID,
                database: database
            ),
            fingerprint: ConversationShardMigrationFingerprint.compute(
                conversationID: body.conversationID,
                database: database,
                pageSize: pageSize
            ),
            sideEffectCount: sideEffectCount
        )
    }
}

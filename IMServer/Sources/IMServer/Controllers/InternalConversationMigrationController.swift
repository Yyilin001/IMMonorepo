import Vapor

/// Authenticated target-side preflight used by a source Cell before any future
/// cross-Cell migration transfer. It exposes only row counts and never changes
/// the target shard.
struct InternalConversationMigrationController: RouteCollection {
    private static let internalSecretHeader = "X-IM-Internal-Secret"

    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("internal", "im", "migrations")
            .post("target-preflight", use: targetPreflight)
    }

    func targetPreflight(req: Request) async throws -> ConversationShardMigrationPreflight.CanonicalDataSnapshot {
        let body = try req.content.decode(IMCellShardMigrationTargetPreflightRequest.self)
        try validate(req: req, body: body)
        guard req.application.conversationShardRouter.shardIDs.contains(body.targetShardID) else {
            throw Abort(.badRequest, reason: "Unknown target conversation shard: \(body.targetShardID)")
        }
        return try await ConversationShardMigrationPreflight(app: req.application).snapshot(
            conversationID: body.conversationID,
            database: req.application.conversationShardRouter.commandDatabase(forShardID: body.targetShardID)
        )
    }

    private func validate(req: Request, body: IMCellShardMigrationTargetPreflightRequest) throws {
        let expectedSecret = req.application.cellIngressConfiguration.sharedSecret?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expectedSecret, !expectedSecret.isEmpty,
              req.headers.first(name: Self.internalSecretHeader) == expectedSecret
        else {
            throw Abort(.unauthorized, reason: "Invalid remote Cell migration ingress credential.")
        }
        guard IMRealtimeCellConfiguration.isValid(cellID: body.originCellID),
              body.originCellID != req.application.imRealtimeCellID,
              body.targetCellID == req.application.imRealtimeCellID
        else {
            throw Abort(.badGateway, reason: "Invalid remote Cell migration preflight route.")
        }
    }
}

struct IMCellShardMigrationTargetPreflightRequest: Content, Sendable {
    let conversationID: UUID
    let originCellID: String
    let targetCellID: String
    let targetShardID: String
}

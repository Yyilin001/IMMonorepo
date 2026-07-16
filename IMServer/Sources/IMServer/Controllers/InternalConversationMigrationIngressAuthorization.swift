import Vapor

/// Shared authentication and control-record binding for mutable/readback
/// cross-Cell migration endpoints. The long-lived ingress secret authenticates
/// the Cell, while the migration capability authorizes only one active move.
enum InternalConversationMigrationIngressAuthorization {
    private static let internalSecretHeader = "X-IM-Internal-Secret"

    static func validate(
        req: Request,
        conversationID: UUID,
        originCellID: String,
        targetCellID: String,
        targetShardID: String,
        sourceRouteVersion: Int,
        transferToken: String,
        allowedStatuses: Set<ConversationShardMigrationStatus>
    ) async throws -> ConversationShardMigration {
        let expectedSecret = req.application.cellIngressConfiguration.sharedSecret?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expectedSecret, !expectedSecret.isEmpty,
              req.headers.first(name: internalSecretHeader) == expectedSecret
        else {
            throw Abort(.unauthorized, reason: "Invalid remote Cell migration ingress credential.")
        }
        guard IMRealtimeCellConfiguration.isValid(cellID: originCellID),
              originCellID != req.application.imRealtimeCellID,
              targetCellID == req.application.imRealtimeCellID
        else {
            throw Abort(.badGateway, reason: "Invalid remote Cell migration transfer route.")
        }
        guard let migration = try await ConversationShardMigration.find(conversationID, on: req.application.db),
              migration.sourceCellID == originCellID,
              migration.sourceRouteVersion == sourceRouteVersion,
              migration.targetCellID == targetCellID,
              migration.targetShardID == targetShardID,
              allowedStatuses.contains(migration.statusEnum),
              let configuredTransferToken = migration.transferToken,
              configuredTransferToken == transferToken,
              let expiresAt = migration.transferTokenExpiresAt,
              expiresAt > Date()
        else {
            throw Abort(.conflict, reason: "Migration transfer is not authorized by an active source migration intent.")
        }
        return migration
    }
}

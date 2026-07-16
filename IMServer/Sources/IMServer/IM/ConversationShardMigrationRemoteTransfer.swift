import Foundation
import Vapor

/// Source-side client for a single remote canonical migration page. Progress
/// is persisted only after this call receives a complete idempotent response,
/// so a transport failure can safely replay the exact page.
struct ConversationShardMigrationRemoteTransfer {
    let app: Application
    let migration: ConversationShardMigration

    func upload<Record: Encodable>(
        kind: IMCellConversationMigrationTransferKind,
        records: [Record]
    ) async throws {
        try await upload(
            kind: kind,
            records: try records.map { try JSONEncoder().encode($0) }
        )
    }

    func upload(
        kind: IMCellConversationMigrationTransferKind,
        records: [Data]
    ) async throws {
        guard !records.isEmpty else { return }
        guard let endpoint = try await app.cellIngressEndpointResolver.endpoint(
            for: migration.targetCellID,
            purpose: .command
        ) else {
            throw Abort(.serviceUnavailable, reason: "No command ingress endpoint is configured for target Cell \(migration.targetCellID).")
        }
        guard let sharedSecret = app.cellIngressConfiguration.sharedSecret?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !sharedSecret.isEmpty,
              let transferToken = migration.transferToken,
              !transferToken.isEmpty,
              let expiresAt = migration.transferTokenExpiresAt,
              expiresAt > Date()
        else {
            throw Abort(.serviceUnavailable, reason: "Remote conversation migration requires an active Cell ingress secret and transfer capability.")
        }

        let conversationID = try migration.requireID()
        let batch = IMCellConversationMigrationTransferBatch(
            conversationID: conversationID,
            originCellID: migration.sourceCellID,
            targetCellID: migration.targetCellID,
            targetShardID: migration.targetShardID,
            sourceRouteVersion: migration.sourceRouteVersion,
            transferToken: transferToken,
            kind: kind,
            records: records,
            checksum: IMCellConversationMigrationTransferBatch.checksum(for: records)
        )
        let startedAt = Date()
        await app.conversationShardMigrationMetrics.recordRemotePageAttempt(
            recordCount: records.count,
            byteCount: records.reduce(0) { $0 + $1.count }
        )
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: "Content-Type", value: "application/json")
        headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: sharedSecret)
        let baseURL = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        do {
            let response = try await app.client.post(
                URI(string: "\(baseURL)/internal/im/migrations/transfer-page"),
                headers: headers
            ) { request in
                try request.content.encode(batch)
            }
            guard response.status == .ok else {
                throw Abort(.badGateway, reason: "Target Cell \(migration.targetCellID) rejected migration transfer with HTTP \(response.status.code).")
            }
            let result = try response.content.decode(IMCellConversationMigrationTransferResponse.self)
            guard result.importedCount + result.alreadyPresentCount == records.count else {
                throw Abort(.badGateway, reason: "Target Cell \(migration.targetCellID) returned an incomplete migration transfer acknowledgement.")
            }
            await app.conversationShardMigrationMetrics.recordRemotePageSuccess(
                elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            )
        } catch {
            await app.conversationShardMigrationMetrics.recordRemotePageFailure(
                elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            )
            throw error
        }
    }

    func verify(pageSize: Int) async throws -> IMCellConversationMigrationVerificationResponse {
        let body = try verificationRequest(pageSize: pageSize)
        let response = try await post(path: "target-verification", body: body)
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "Target Cell \(migration.targetCellID) rejected migration verification with HTTP \(response.status.code).")
        }
        return try response.content.decode(IMCellConversationMigrationVerificationResponse.self)
    }

    func finalizeSearchIndex(cutoverLeaseToken: String, pageSize: Int) async throws {
        let verification = try verificationRequest(pageSize: pageSize)
        let body = IMCellConversationMigrationFinalizeRequest(
            conversationID: verification.conversationID,
            originCellID: verification.originCellID,
            targetCellID: verification.targetCellID,
            targetShardID: verification.targetShardID,
            sourceRouteVersion: verification.sourceRouteVersion,
            transferToken: verification.transferToken,
            cutoverLeaseToken: cutoverLeaseToken,
            pageSize: verification.pageSize
        )
        let response = try await post(path: "target-finalize", body: body)
        guard response.status == .noContent else {
            throw Abort(.badGateway, reason: "Target Cell \(migration.targetCellID) rejected migration finalization with HTTP \(response.status.code).")
        }
    }

    private func verificationRequest(pageSize: Int) throws -> IMCellConversationMigrationVerificationRequest {
        guard let transferToken = migration.transferToken,
              !transferToken.isEmpty,
              let expiresAt = migration.transferTokenExpiresAt,
              expiresAt > Date()
        else {
            throw Abort(.serviceUnavailable, reason: "Remote conversation migration requires an active transfer capability.")
        }
        return try IMCellConversationMigrationVerificationRequest(
            conversationID: migration.requireID(),
            originCellID: migration.sourceCellID,
            targetCellID: migration.targetCellID,
            targetShardID: migration.targetShardID,
            sourceRouteVersion: migration.sourceRouteVersion,
            transferToken: transferToken,
            pageSize: min(max(pageSize, 1), 1_000)
        )
    }

    private func post<Body: Content>(path: String, body: Body) async throws -> ClientResponse {
        guard let endpoint = try await app.cellIngressEndpointResolver.endpoint(
            for: migration.targetCellID,
            purpose: .command
        ) else {
            throw Abort(.serviceUnavailable, reason: "No command ingress endpoint is configured for target Cell \(migration.targetCellID).")
        }
        guard let sharedSecret = app.cellIngressConfiguration.sharedSecret?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !sharedSecret.isEmpty
        else {
            throw Abort(.serviceUnavailable, reason: "Remote conversation migration requires a Cell ingress secret.")
        }
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: "Content-Type", value: "application/json")
        headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: sharedSecret)
        let baseURL = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        return try await app.client.post(
            URI(string: "\(baseURL)/internal/im/migrations/\(path)"),
            headers: headers
        ) { request in
            try request.content.encode(body)
        }
    }
}

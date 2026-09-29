import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core

extension PostgresV2ResourceLifecycleStore: V2ResourceLifecyclePort {
    public func create(request: V2ResourceUploadRequest, home: V2ResourceHome, actor: UserID, device: DeviceID,
                       allocate: @escaping @Sendable () throws -> V2StoredObjectReference,
                       expiresAt: Date, now: Date) async throws -> V2ResourceUploadSnapshot {
        let homeKind: String
        let homeID: UUID
        switch home {
        case .account(let id): homeKind = "account"; homeID = try id.resourceUUID
        case .room(let id): homeKind = "room"; homeID = try id.resourceUUID
        }
        let usageKind: String
        switch request.usage {
        case .messageAttachment: usageKind = "message_attachment"
        case .userAvatar: usageKind = "user_avatar"
        case .groupAvatar: usageKind = "group_avatar"
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let row = try await create(homeKind: homeKind, homeID: homeID, usageKind: usageKind,
            actor: try actor.resourceUUID, device: try device.resourceUUID,
            operation: try request.operationID.resourceUUID, mediaID: try request.mediaID.resourceUUID,
            contentType: request.contentType, byteCount: request.byteCount,
            requestJSON: String(decoding: try encoder.encode(request), as: UTF8.self),
            allocate: allocate, expiresAt: expiresAt, now: now)
        return try row.snapshot()
    }

    public func upload(session: UUID, actor: UUID, device: UUID) async throws -> V2ResourceUploadSnapshot {
        try await status(session: session, actor: actor, device: device).snapshot()
    }
    public func claimUploadFinalize(session: UUID, generation: Int64, actor: UUID, device: UUID, now: Date) async throws -> V2ResourceUploadSnapshot {
        try await claimFinalize(session: session, generation: generation, actor: actor, device: device, now: now).snapshot()
    }
    public func publishUpload(_ claim: V2ResourceUploadSnapshot, facts: V2StoredObjectFacts, actor: UUID, device: UUID, now: Date) async throws {
        try await publishUploadClaim(sessionID: claim.sessionID, mediaID: claim.mediaID,
            generation: claim.generation, placement: claim.placement, claimToken: claim.claimToken,
            facts: facts, actor: actor, device: device, now: now)
    }
    public func cancelUpload(session: UUID, generation: Int64, actor: UUID, device: UUID, now: Date) async throws -> V2ResourceUploadSnapshot {
        try await cancel(session: session, generation: generation, actor: actor, device: device, now: now).snapshot()
    }
}

private extension V2Identifier {
    var resourceUUID: UUID {
        get throws {
            guard let value = UUID(uuidString: rawValue) else { throw V2ResourceProviderError.configurationInvalid }
            return value
        }
    }
}

private extension V2PersistedResourceUpload {
    func snapshot() throws -> V2ResourceUploadSnapshot {
        let phase: V2ResourceUploadPhase
        switch state {
        case "created": phase = .created
        case "uploading": phase = .uploading
        case "finalizing": phase = .finalizing
        case "completed": phase = .completed
        case "cancelled": phase = .cancelled
        case "expired": phase = .expired
        case "failed": phase = .failed
        default: throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let mediaPhase: V2ResourceMediaPhase
        switch mediaState {
        case "pending_upload": mediaPhase = .pendingUpload
        case "scanning": mediaPhase = .scanning
        case "available": mediaPhase = .available
        case "expired": mediaPhase = .expired
        case "failed": mediaPhase = .failed
        default: throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return try .init(sessionID: sessionID, mediaID: mediaID, generation: generation,
            phase: phase, mediaPhase: mediaPhase,
            request: JSONDecoder().decode(V2ResourceUploadRequest.self, from: Data(requestJSON.utf8)),
            placement: placement, expiresAt: expiresAt, claimToken: claimToken)
    }
}

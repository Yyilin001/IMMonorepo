import Foundation
import IMV2Core

/// Upload use case for the authenticated media edge. It creates a durable
/// intent, exchanges only its opaque session for an in-memory provider target,
/// and leaves the actual state transition to the explicit completion callback.
public struct V2MediaEdgeUploadService: Sendable {
    private let media: V2MediaService
    private let providerSessions: V2MediaUploadProviderSessionService

    public init(media: V2MediaService, providerSessions: V2MediaUploadProviderSessionService) {
        self.media = media
        self.providerSessions = providerSessions
    }

    public func uploadTarget(
        actorUserID: UserID,
        deviceID: DeviceID,
        operationID: MediaUploadOperationID,
        mediaID: MediaID,
        contentType: String,
        byteCount: Int64
    ) async throws -> V2MediaProviderObjectTarget {
        let grant = try await media.requestUpload(
            actorUserID: actorUserID,
            deviceID: deviceID,
            operationID: operationID,
            mediaID: mediaID,
            contentType: contentType,
            byteCount: byteCount
        )
        return try await providerSessions.exchangeUpload(
            actorUserID: actorUserID,
            deviceID: deviceID,
            uploadSessionID: grant.uploadSessionID
        )
    }

    public func uploadCompleted(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID) async throws {
        try await media.uploadCompleted(actorUserID: actorUserID, deviceID: deviceID, mediaID: mediaID)
    }

    public func uploadStatus(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID) async throws -> V2MediaObjectState {
        try await media.uploadStatus(actorUserID: actorUserID, deviceID: deviceID, mediaID: mediaID)
    }
}

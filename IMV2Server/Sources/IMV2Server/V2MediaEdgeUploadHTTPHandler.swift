import Foundation
import IMV2Core

/// Framework-neutral upload transport adapter. It validates only transport
/// identifiers; device authentication and upload-state policy live in the
/// edge/service/store layers below it.
public struct V2MediaEdgeUploadHTTPHandler: Sendable {
    private let edge: V2MediaEdgeUploadService

    public init(edge: V2MediaEdgeUploadService) { self.edge = edge }

    public func uploadTarget(
        actorUserID: UserID,
        deviceID: DeviceID,
        rawOperationID: String,
        rawMediaID: String,
        contentType: String,
        byteCount: Int64
    ) async throws -> V2MediaUploadTargetEnvelope {
        guard rawOperationID.utf8.count <= 128, rawMediaID.utf8.count <= 128 else {
            throw V2MediaEdgeUploadHTTPHandlerError.invalidIdentifier
        }
        let operationID: MediaUploadOperationID
        let mediaID: MediaID
        do {
            operationID = try .init(rawOperationID)
            mediaID = try .init(rawMediaID)
        } catch {
            throw V2MediaEdgeUploadHTTPHandlerError.invalidIdentifier
        }
        let target = try await edge.uploadTarget(
            actorUserID: actorUserID,
            deviceID: deviceID,
            operationID: operationID,
            mediaID: mediaID,
            contentType: contentType,
            byteCount: byteCount
        )
        do {
            return try .init(
                url: target.url,
                headers: target.headers,
                expiresAt: target.expiresAt,
                expectedByteCount: target.expectedByteCount
            )
        } catch {
            throw V2MediaEdgeUploadHTTPHandlerError.invalidProviderTarget
        }
    }

    public func uploadCompleted(actorUserID: UserID, deviceID: DeviceID, rawMediaID: String) async throws {
        guard rawMediaID.utf8.count <= 128, let mediaID = try? MediaID(rawMediaID) else {
            throw V2MediaEdgeUploadHTTPHandlerError.invalidIdentifier
        }
        try await edge.uploadCompleted(actorUserID: actorUserID, deviceID: deviceID, mediaID: mediaID)
    }

    public func uploadStatus(actorUserID: UserID, deviceID: DeviceID, rawMediaID: String) async throws -> V2MediaUploadStatusEnvelope {
        guard rawMediaID.utf8.count <= 128, let mediaID = try? MediaID(rawMediaID) else {
            throw V2MediaEdgeUploadHTTPHandlerError.invalidIdentifier
        }
        return .init(state: try await edge.uploadStatus(actorUserID: actorUserID, deviceID: deviceID, mediaID: mediaID))
    }
}

public enum V2MediaEdgeUploadHTTPHandlerError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidProviderTarget
}

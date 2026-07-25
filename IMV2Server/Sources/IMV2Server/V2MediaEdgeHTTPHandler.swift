import Foundation
import IMV2Core

/// Framework-neutral HTTP transport adapter for `GET /v2/media/{mediaID}`.
/// A Vapor route is responsible only for extracting an already-authenticated
/// user/device and mapping this typed result or error to HTTP. This handler
/// intentionally owns neither bearer-token parsing nor provider configuration.
public struct V2MediaEdgeHTTPHandler: Sendable {
    private let edge: V2MediaEdgeDownloadService

    public init(edge: V2MediaEdgeDownloadService) {
        self.edge = edge
    }

    public func downloadTarget(
        actorUserID: UserID,
        deviceID: DeviceID,
        rawMediaID: String
    ) async throws -> V2MediaDownloadTargetEnvelope {
        guard rawMediaID.utf8.count <= 128 else { throw V2MediaEdgeHTTPHandlerError.invalidMediaID }
        let mediaID: MediaID
        do {
            mediaID = try MediaID(rawMediaID)
        } catch {
            throw V2MediaEdgeHTTPHandlerError.invalidMediaID
        }
        let target = try await edge.downloadTarget(actorUserID: actorUserID, deviceID: deviceID, mediaID: mediaID)
        do {
            return try .init(
                url: target.url,
                headers: target.headers,
                expiresAt: target.expiresAt,
                expectedByteCount: target.expectedByteCount
            )
        } catch {
            // Provider values must never reach an HTTP response if they fail
            // the stable contract validation.
            throw V2MediaEdgeHTTPHandlerError.invalidProviderTarget
        }
    }
}

public enum V2MediaEdgeHTTPHandlerError: Error, Equatable, Sendable {
    case invalidMediaID
    case invalidProviderTarget
}

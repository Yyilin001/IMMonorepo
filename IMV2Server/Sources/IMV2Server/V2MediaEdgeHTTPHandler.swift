import Foundation
import IMV2Core

/// Framework-neutral HTTP transport adapter for `GET /v2/media/{mediaID}`.
/// A Vapor route is responsible only for extracting an already-authenticated
/// user/device and mapping this typed result or error to HTTP. This handler
/// intentionally owns neither bearer-token parsing nor provider configuration.
public struct V2MediaEdgeHTTPHandler: Sendable {
    private let edge: any V2MediaDownloadTargetResolving

    public init(edge: V2MediaEdgeDownloadService) {
        self.edge = edge
    }
    public init(resolver: any V2MediaDownloadTargetResolving) { edge = resolver }

    public func downloadTarget(
        actorUserID: UserID,
        deviceID: DeviceID,
        rawMediaID: String,
        rawRoomID: String? = nil,
        rawMessageID: String? = nil
    ) async throws -> V2MediaDownloadTargetEnvelope {
        guard rawMediaID.utf8.count <= 128 else { throw V2MediaEdgeHTTPHandlerError.invalidMediaID }
        let mediaID: MediaID
        do {
            mediaID = try MediaID(rawMediaID)
        } catch {
            throw V2MediaEdgeHTTPHandlerError.invalidMediaID
        }
        let message: V2MediaMessageLocation?
        switch (rawRoomID, rawMessageID) {
        case (nil, nil): message = nil
        case (.some(let room), .some(let identifier)):
            guard room.utf8.count <= 128, identifier.utf8.count <= 128,
                  let roomUUID = UUID(uuidString: room), let messageUUID = UUID(uuidString: identifier)
            else { throw V2MediaEdgeHTTPHandlerError.invalidMessageLocation }
            message = .init(roomID: .init(uuid: roomUUID), messageID: .init(uuid: messageUUID))
        default: throw V2MediaEdgeHTTPHandlerError.invalidMessageLocation
        }
        let target = try await edge.downloadTarget(actorUserID: actorUserID, deviceID: deviceID, mediaID: mediaID, message: message)
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
    case invalidMessageLocation
    case messageOwnerUnavailable
}

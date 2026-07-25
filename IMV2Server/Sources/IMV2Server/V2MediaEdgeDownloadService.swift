import Foundation
import IMV2Core

/// Authenticated media-edge use case. A thin HTTP handler may decode a device
/// identity and media ID, then call this service; it must never reimplement
/// membership, withdrawal, or provider-session policy itself.
public struct V2MediaEdgeDownloadService: Sendable {
    private let media: V2MediaService
    private let providerSessions: V2MediaProviderSessionService

    public init(media: V2MediaService, providerSessions: V2MediaProviderSessionService) {
        self.media = media
        self.providerSessions = providerSessions
    }

    /// Produces an in-memory provider target for exactly one authenticated
    /// device. The opaque grant is intentionally internal to this use case and
    /// is never returned to a chat client, event log, or persistent record.
    public func downloadTarget(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID) async throws -> V2MediaProviderObjectTarget {
        let grant = try await media.requestDownload(actorUserID: actorUserID, deviceID: deviceID, mediaID: mediaID)
        return try await providerSessions.exchangeDownload(
            actorUserID: actorUserID,
            deviceID: deviceID,
            downloadSessionID: grant.downloadSessionID
        )
    }
}

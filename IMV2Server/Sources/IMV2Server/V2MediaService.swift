import Foundation
import IMV2Core

/// Boundary owned by the authenticated upload/download service. Implementors
/// may hand a session to S3, a CDN, or another object system, but no object URL
/// is returned through this IM domain API.
public protocol V2MediaStore: Sendable {
    func requestUpload(_ command: V2RequestMediaUploadCommand, deviceID: DeviceID, expiresAt: Date, now: Date) async throws -> V2MediaUploadGrant
    func requestDownload(requesterUserID: UserID, deviceID: DeviceID, mediaID: MediaID, expiresAt: Date, now: Date) async throws -> V2MediaDownloadGrant
    func markUploadCompleted(ownerUserID: UserID, deviceID: DeviceID, mediaID: MediaID, now: Date) async throws
    func uploadStatus(ownerUserID: UserID, deviceID: DeviceID, mediaID: MediaID, now: Date) async throws -> V2MediaObjectState
    func recordScanResult(mediaID: MediaID, passed: Bool, now: Date) async throws
    func assertAvailableForReference(ownerUserID: UserID, mediaIDs: [MediaID], now: Date) async throws
}

/// The scanner callback is deliberately separated from a user command. A
/// caller that can upload cannot choose its own scan outcome.
public struct V2MediaService: Sendable {
    private let store: any V2MediaStore
    private let limits: V2MediaUploadLimits
    private let downloadLimits: V2MediaDownloadLimits
    private let now: @Sendable () -> Date

    public init(store: any V2MediaStore, limits: V2MediaUploadLimits, downloadLimits: V2MediaDownloadLimits = .standard, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.limits = limits
        self.downloadLimits = downloadLimits
        self.now = now
    }

    public func requestUpload(actorUserID: UserID, deviceID: DeviceID, operationID: MediaUploadOperationID, mediaID: MediaID, contentType: String, byteCount: Int64) async throws -> V2MediaUploadGrant {
        let instant = now()
        let command = try V2RequestMediaUploadCommand(actorUserID: actorUserID, operationID: operationID, mediaID: mediaID, contentType: contentType, byteCount: byteCount, limits: limits)
        let grant = try await store.requestUpload(command, deviceID: deviceID, expiresAt: instant.addingTimeInterval(limits.temporaryLifetime), now: instant)
        // The store validates a new deadline after checking durable replay.
        // Validate the persisted result using the clock after that await.
        guard grant.mediaID == mediaID, v2PostgresTimestampPrecedes(now(), grant.expiresAt) else { throw V2MediaServiceError.invalidGrant }
        return grant
    }

    public func uploadCompleted(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID) async throws {
        try await store.markUploadCompleted(ownerUserID: actorUserID, deviceID: deviceID, mediaID: mediaID, now: now())
    }

    public func uploadStatus(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID) async throws -> V2MediaObjectState {
        try await store.uploadStatus(ownerUserID: actorUserID, deviceID: deviceID, mediaID: mediaID, now: now())
    }

    public func scannerCompleted(mediaID: MediaID, passed: Bool) async throws {
        try await store.recordScanResult(mediaID: mediaID, passed: passed, now: now())
    }

    /// The gateway must derive both identifiers from authentication. This
    /// layer records only a short-lived opaque session; the media edge alone
    /// may exchange it for a provider-specific single-object target.
    public func requestDownload(actorUserID: UserID, deviceID: DeviceID, mediaID: MediaID) async throws -> V2MediaDownloadGrant {
        let instant = now()
        guard let expiry = v2PostgresFutureTimestamp(now: instant, interval: downloadLimits.grantLifetime) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let grant = try await store.requestDownload(
            requesterUserID: actorUserID,
            deviceID: deviceID,
            mediaID: mediaID,
            expiresAt: expiry,
            now: instant
        )
        guard grant.mediaID == mediaID, v2PostgresTimestampPrecedes(now(), grant.expiresAt) else {
            throw V2MediaServiceError.invalidGrant
        }
        return grant
    }

    /// Message acceptance calls this within its owning SQL transaction before
    /// a room event, fan-out plan, or outbox row is committed.
    public func assertAvailableForReference(ownerUserID: UserID, media: [V2MediaReference]) async throws {
        try await store.assertAvailableForReference(ownerUserID: ownerUserID, mediaIDs: media.map(\.mediaID), now: now())
    }
}

public enum V2MediaServiceError: Error, Equatable, Sendable { case invalidGrant }

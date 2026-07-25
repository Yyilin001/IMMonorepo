import Foundation
import IMV2Core

/// Provider capability for issuing a single short-lived upload target. It is
/// intentionally separate from the download capability so a deployment cannot
/// accidentally grant write access to a download-only adapter.
public protocol V2MediaUploadObjectProvider: Sendable {
    func issueUploadTarget(
        mediaID: MediaID,
        contentType: String,
        byteCount: Int64,
        expiresAt: Date
    ) async throws -> V2MediaProviderObjectTarget
}

public struct V2ClaimedMediaUpload: Equatable, Sendable {
    public let mediaID: MediaID
    public let uploadSessionID: MediaUploadSessionID
    public let contentType: String
    public let byteCount: Int64
    public let expiresAt: Date
    public let claimToken: UUID

    public init(
        mediaID: MediaID,
        uploadSessionID: MediaUploadSessionID,
        contentType: String,
        byteCount: Int64,
        expiresAt: Date,
        claimToken: UUID
    ) {
        self.mediaID = mediaID
        self.uploadSessionID = uploadSessionID
        self.contentType = contentType
        self.byteCount = byteCount
        self.expiresAt = expiresAt
        self.claimToken = claimToken
    }
}

/// The store atomically verifies the currently authenticated device, owner,
/// `pending_upload` state, and grant state before provider access is issued.
public protocol V2MediaUploadSessionStore: Sendable {
    func claimUpload(
        ownerUserID: UserID,
        deviceID: DeviceID,
        uploadSessionID: MediaUploadSessionID,
        now: Date,
        leaseDuration: TimeInterval
    ) async throws -> V2ClaimedMediaUpload
    func completeUploadTarget(_ claim: V2ClaimedMediaUpload, now: Date) async throws
    func releaseUploadTarget(_ claim: V2ClaimedMediaUpload) async throws
}

/// Exchanges one durable, device-bound upload session for one in-memory
/// provider target. The completion callback remains separate: it may only
/// advance the media state after this target exchange has been consumed.
public struct V2MediaUploadProviderSessionService: Sendable {
    private let store: any V2MediaUploadSessionStore
    private let provider: any V2MediaUploadObjectProvider
    private let leaseDuration: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        store: any V2MediaUploadSessionStore,
        provider: any V2MediaUploadObjectProvider,
        leaseDuration: TimeInterval = 15,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard leaseDuration > 0 else { throw V2MediaUploadProviderSessionError.invalidLeaseDuration }
        self.store = store
        self.provider = provider
        self.leaseDuration = leaseDuration
        self.now = now
    }

    public func exchangeUpload(
        actorUserID: UserID,
        deviceID: DeviceID,
        uploadSessionID: MediaUploadSessionID
    ) async throws -> V2MediaProviderObjectTarget {
        let instant = now()
        let claim = try await store.claimUpload(
            ownerUserID: actorUserID,
            deviceID: deviceID,
            uploadSessionID: uploadSessionID,
            now: instant,
            leaseDuration: leaseDuration
        )
        do {
            guard claim.expiresAt > instant else { throw V2MediaUploadProviderSessionError.expiredSession }
            let target = try await provider.issueUploadTarget(
                mediaID: claim.mediaID,
                contentType: claim.contentType,
                byteCount: claim.byteCount,
                expiresAt: claim.expiresAt
            )
            guard target.expiresAt > instant,
                  target.expiresAt <= claim.expiresAt,
                  target.url.scheme?.lowercased() == "https",
                  target.url.host != nil,
                  target.expectedByteCount == claim.byteCount,
                  target.headers.allSatisfy({ name, value in
                      !name.isEmpty
                          && !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
                          && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
                  })
            else { throw V2MediaUploadProviderSessionError.invalidProviderTarget }
            try await store.completeUploadTarget(claim, now: now())
            return target
        } catch {
            try? await store.releaseUploadTarget(claim)
            throw error
        }
    }
}

public enum V2MediaUploadProviderSessionError: Error, Equatable, Sendable {
    case invalidLeaseDuration
    case expiredSession
    case invalidProviderTarget
}

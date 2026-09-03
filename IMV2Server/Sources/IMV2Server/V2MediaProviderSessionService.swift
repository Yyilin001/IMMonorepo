import Foundation
import IMV2Core

/// This value is returned only from the authenticated media edge to the
/// requesting device. It is deliberately not Codable and must never be added
/// to a chat event, log field, push payload, or database row.
public struct V2MediaProviderObjectTarget: Equatable, Sendable {
    public let url: URL
    public let headers: [String: String]
    public let expiresAt: Date
    public let expectedByteCount: Int64?

    public init(url: URL, headers: [String: String] = [:], expiresAt: Date, expectedByteCount: Int64? = nil) {
        self.url = url
        self.headers = headers
        self.expiresAt = expiresAt
        self.expectedByteCount = expectedByteCount
    }
}

/// Object-store details belong behind this boundary. A production adapter can
/// use S3, a CDN, or another provider without leaking provider credentials
/// into the IM authority database or protocol.
public protocol V2MediaObjectProvider: Sendable {
    func issueDownloadTarget(mediaID: MediaID, expiresAt: Date) async throws -> V2MediaProviderObjectTarget
}

public struct V2ClaimedMediaDownload: Equatable, Sendable {
    public let mediaID: MediaID
    public let downloadSessionID: MediaDownloadSessionID
    public let expiresAt: Date
    public let claimToken: UUID

    public init(mediaID: MediaID, downloadSessionID: MediaDownloadSessionID, expiresAt: Date, claimToken: UUID) {
        self.mediaID = mediaID
        self.downloadSessionID = downloadSessionID
        self.expiresAt = expiresAt
        self.claimToken = claimToken
    }
}

public protocol V2MediaDownloadSessionStore: Sendable {
    /// Claiming must re-evaluate authentication and content authorization,
    /// because a short-lived IM grant is not itself a revocation bypass.
    func claimDownload(
        requesterUserID: UserID,
        deviceID: DeviceID,
        downloadSessionID: MediaDownloadSessionID,
        now: Date,
        leaseDuration: TimeInterval
    ) async throws -> V2ClaimedMediaDownload
    func completeDownload(_ claim: V2ClaimedMediaDownload, now: Date) async throws
    func releaseDownload(_ claim: V2ClaimedMediaDownload) async throws
}

/// Exchanges exactly one opaque session for one provider object target. The
/// service creates no detached work and does not hold a database transaction
/// while the provider signs its URL.
public struct V2MediaProviderSessionService: Sendable {
    private let store: any V2MediaDownloadSessionStore
    private let provider: any V2MediaObjectProvider
    private let leaseDuration: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        store: any V2MediaDownloadSessionStore,
        provider: any V2MediaObjectProvider,
        leaseDuration: TimeInterval = 15,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard leaseDuration > 0 else { throw V2MediaProviderSessionError.invalidLeaseDuration }
        self.store = store
        self.provider = provider
        self.leaseDuration = leaseDuration
        self.now = now
    }

    public func exchangeDownload(
        actorUserID: UserID,
        deviceID: DeviceID,
        downloadSessionID: MediaDownloadSessionID
    ) async throws -> V2MediaProviderObjectTarget {
        let instant = now()
        let claim = try await store.claimDownload(
            requesterUserID: actorUserID,
            deviceID: deviceID,
            downloadSessionID: downloadSessionID,
            now: instant,
            leaseDuration: leaseDuration
        )
        do {
            guard claim.expiresAt > instant else { throw V2MediaProviderSessionError.expiredSession }
            let target = try await provider.issueDownloadTarget(mediaID: claim.mediaID, expiresAt: claim.expiresAt)
            guard target.expiresAt > instant,
                  target.expiresAt <= claim.expiresAt,
                  target.url.scheme?.lowercased() == "https",
                  target.url.host != nil,
                  target.url.user == nil,
                  target.url.password == nil,
                  target.url.fragment == nil,
                  target.expectedByteCount.map({ $0 >= 0 }) ?? true,
                  target.headers.allSatisfy({ name, value in
                      V2MediaProviderTargetHeaderPolicy.isAllowed(name: name, value: value)
                  })
            else {
                throw V2MediaProviderSessionError.invalidProviderTarget
            }
            try await store.completeDownload(claim, now: now())
            return target
        } catch {
            try? await store.releaseDownload(claim)
            throw error
        }
    }
}

enum V2MediaProviderTargetHeaderPolicy {
    static func isAllowed(name: String, value: String) -> Bool {
        let canonical = name.lowercased()
        let allowedName = canonical == "content-type"
            || canonical == "content-md5"
            || canonical == "digest"
            || canonical.hasPrefix("x-amz-")
            || canonical.hasPrefix("x-oss-")
            || canonical.hasPrefix("x-goog-")
        return allowedName
            && !name.isEmpty
            && name.utf8.count <= 128
            && value.utf8.count <= 8_192
            && !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }
}

public enum V2MediaProviderSessionError: Error, Equatable, Sendable {
    case invalidLeaseDuration
    case expiredSession
    case invalidProviderTarget
}

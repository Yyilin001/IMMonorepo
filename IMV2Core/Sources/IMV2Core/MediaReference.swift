import Foundation

/// A chat payload carries only this opaque reference. Object locations and
/// bearer URLs stay outside the IM protocol and are never persisted in events.
public struct V2MediaReference: Hashable, Codable, Sendable {
    public let mediaID: MediaID
    public init(mediaID: MediaID) { self.mediaID = mediaID }
}

/// A server-derived, durable description of a message attachment. It exposes
/// only presentation facts that are already available from the scanned media
/// object; object locations and download credentials remain outside message
/// events and local projections.
public struct V2MediaPresentation: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case image
        case animatedImage = "animated_image"
        case video
        case audio
        case file
    }

    public let mediaID: MediaID
    public let kind: Kind
    public let contentType: String
    public let byteCount: Int64

    public init(mediaID: MediaID, kind: Kind, contentType: String, byteCount: Int64) throws {
        let normalizedContentType = contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedContentType == contentType,
              normalizedContentType.contains("/"),
              !normalizedContentType.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              normalizedContentType.utf8.count <= 127,
              byteCount >= 0
        else { throw V2MediaValidationError.invalidPresentation }
        self.mediaID = mediaID
        self.kind = kind
        self.contentType = normalizedContentType
        self.byteCount = byteCount
    }

    public static func kind(forContentType contentType: String) -> Kind {
        if contentType.hasPrefix("image/gif") { return .animatedImage }
        if contentType.hasPrefix("image/") { return .image }
        if contentType.hasPrefix("video/") { return .video }
        if contentType.hasPrefix("audio/") { return .audio }
        return .file
    }
}

public struct V2MediaUploadLimits: Equatable, Sendable {
    public let maximumBytes: Int64
    public let temporaryLifetime: TimeInterval

    public init(maximumBytes: Int64, temporaryLifetime: TimeInterval = 86_400) throws {
        guard maximumBytes > 0, temporaryLifetime > 0 else { throw V2MediaValidationError.invalidLimits }
        self.maximumBytes = maximumBytes
        self.temporaryLifetime = temporaryLifetime
    }
}

/// Requesting an upload is a durable intent. The resulting upload target is
/// deliberately provider-owned and must not be added to this domain value.
public struct V2RequestMediaUploadCommand: Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: MediaUploadOperationID
    public let mediaID: MediaID
    public let contentType: String
    public let byteCount: Int64

    public init(actorUserID: UserID, operationID: MediaUploadOperationID, mediaID: MediaID, contentType: String, byteCount: Int64, limits: V2MediaUploadLimits) throws {
        let normalizedContentType = contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedContentType == contentType,
              normalizedContentType.contains("/"),
              !normalizedContentType.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              normalizedContentType.utf8.count <= 127,
              byteCount > 0, byteCount <= limits.maximumBytes
        else { throw V2MediaValidationError.invalidUploadIntent }
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.mediaID = mediaID
        self.contentType = normalizedContentType
        self.byteCount = byteCount
    }
}

/// The chat backend authorizes an upload session but never exposes an object
/// location through its durable message model. The upload edge exchanges this
/// opaque session for a provider-specific, short-lived upload target.
public struct V2MediaUploadGrant: Equatable, Sendable {
    public let mediaID: MediaID
    public let uploadSessionID: MediaUploadSessionID
    public let expiresAt: Date
    public init(mediaID: MediaID, uploadSessionID: MediaUploadSessionID, expiresAt: Date) {
        self.mediaID = mediaID
        self.uploadSessionID = uploadSessionID
        self.expiresAt = expiresAt
    }
}

/// Download grants are intentionally opaque to the IM domain. The separately
/// authenticated media edge exchanges this short-lived session for a single
/// provider object target; neither a URL nor a bearer token is durable chat
/// state.
public struct V2MediaDownloadGrant: Equatable, Sendable {
    public let mediaID: MediaID
    public let downloadSessionID: MediaDownloadSessionID
    public let expiresAt: Date

    public init(mediaID: MediaID, downloadSessionID: MediaDownloadSessionID, expiresAt: Date) {
        self.mediaID = mediaID
        self.downloadSessionID = downloadSessionID
        self.expiresAt = expiresAt
    }
}

/// Ephemeral JSON payload emitted only by the authenticated media edge. It is
/// deliberately separate from `V2MediaReference` and must never be embedded
/// in a chat event, sync projection, local outbox, or backup. The URL and
/// headers are provider credentials, not durable IM state.
public struct V2MediaDownloadTargetEnvelope: Codable, Equatable, Sendable {
    public let url: String
    public let headers: [String: String]
    public let expiresAtUnixMilliseconds: Int64
    public let expectedByteCount: Int64?

    public init(
        url: URL,
        headers: [String: String] = [:],
        expiresAt: Date,
        expectedByteCount: Int64? = nil
    ) throws {
        guard url.scheme?.lowercased() == "https",
              url.host != nil,
              expiresAt.timeIntervalSince1970.isFinite,
              expectedByteCount.map({ $0 >= 0 }) ?? true,
              headers.allSatisfy({ name, value in
                  !name.isEmpty
                      && !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
                      && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
              })
        else { throw V2MediaValidationError.invalidDownloadTarget }

        let milliseconds = (expiresAt.timeIntervalSince1970 * 1_000).rounded(.down)
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min),
              milliseconds <= Double(Int64.max)
        else { throw V2MediaValidationError.invalidDownloadTarget }

        self.url = url.absoluteString
        self.headers = headers
        self.expiresAtUnixMilliseconds = Int64(milliseconds)
        self.expectedByteCount = expectedByteCount
    }

    public var expiresAt: Date {
        Date(timeIntervalSince1970: TimeInterval(expiresAtUnixMilliseconds) / 1_000)
    }
}

/// Ephemeral upload counterpart to `V2MediaDownloadTargetEnvelope`. It has
/// the same deliberately narrow transport shape, but a separate type keeps a
/// write credential from being accidentally used by a download call site.
/// Like the download envelope, it must never be stored in a message, local
/// outbox, sync projection, backup, or log.
public struct V2MediaUploadTargetEnvelope: Codable, Equatable, Sendable {
    public let url: String
    public let headers: [String: String]
    public let expiresAtUnixMilliseconds: Int64
    public let expectedByteCount: Int64?

    public init(
        url: URL,
        headers: [String: String] = [:],
        expiresAt: Date,
        expectedByteCount: Int64? = nil
    ) throws {
        guard url.scheme?.lowercased() == "https",
              url.host != nil,
              expiresAt.timeIntervalSince1970.isFinite,
              expectedByteCount.map({ $0 >= 0 }) ?? true,
              headers.allSatisfy({ name, value in
                  !name.isEmpty
                      && !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
                      && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
              })
        else { throw V2MediaValidationError.invalidUploadTarget }

        let milliseconds = (expiresAt.timeIntervalSince1970 * 1_000).rounded(.down)
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min),
              milliseconds <= Double(Int64.max)
        else { throw V2MediaValidationError.invalidUploadTarget }

        self.url = url.absoluteString
        self.headers = headers
        self.expiresAtUnixMilliseconds = Int64(milliseconds)
        self.expectedByteCount = expectedByteCount
    }

    public var expiresAt: Date {
        Date(timeIntervalSince1970: TimeInterval(expiresAtUnixMilliseconds) / 1_000)
    }
}

/// The upload owner may poll this small no-store envelope after completion.
/// It intentionally contains only the lifecycle result, never object-store
/// metadata, scanner diagnostics, or another user's media information.
public struct V2MediaUploadStatusEnvelope: Codable, Equatable, Sendable {
    public let state: V2MediaObjectState

    public init(state: V2MediaObjectState) {
        self.state = state
    }
}

public struct V2MediaDownloadLimits: Equatable, Sendable {
    public let grantLifetime: TimeInterval

    public init(grantLifetime: TimeInterval = 120) throws {
        guard grantLifetime > 0, grantLifetime <= 900 else {
            throw V2MediaValidationError.invalidLimits
        }
        self.grantLifetime = grantLifetime
    }

    public static let standard = try! V2MediaDownloadLimits()
}

public enum V2MediaObjectState: String, Codable, Equatable, Sendable {
    case pendingUpload
    case scanning
    case available
    case failed
    case expired
}

public enum V2MediaLifecycleEvent: Equatable, Sendable {
    case uploadCompleted
    case scanPassed
    case scanFailed
    case expire
}

public struct V2MediaObject: Equatable, Sendable {
    public let mediaID: MediaID
    public let ownerUserID: UserID
    public let contentType: String
    public let byteCount: Int64
    public let state: V2MediaObjectState
    public let expiresAt: Date

    public init(mediaID: MediaID, ownerUserID: UserID, contentType: String, byteCount: Int64, state: V2MediaObjectState = .pendingUpload, expiresAt: Date) {
        self.mediaID = mediaID
        self.ownerUserID = ownerUserID
        self.contentType = contentType
        self.byteCount = byteCount
        self.state = state
        self.expiresAt = expiresAt
    }
}

public enum V2MediaLifecycle {
    /// Failed and expired media are terminal. A new upload intent is required
    /// instead of reviving an object whose bytes or scan result are no longer
    /// trustworthy.
    public static func transition(_ object: V2MediaObject, event: V2MediaLifecycleEvent, now: Date) throws -> V2MediaObject {
        if now >= object.expiresAt {
            guard event == .expire || object.state == .expired else { throw V2MediaValidationError.expired }
            return .init(mediaID: object.mediaID, ownerUserID: object.ownerUserID, contentType: object.contentType, byteCount: object.byteCount, state: .expired, expiresAt: object.expiresAt)
        }
        let state: V2MediaObjectState
        switch (object.state, event) {
        case (.pendingUpload, .uploadCompleted): state = .scanning
        case (.scanning, .scanPassed): state = .available
        case (.scanning, .scanFailed): state = .failed
        case (.pendingUpload, .expire), (.scanning, .expire): state = .expired
        default: throw V2MediaValidationError.invalidStateTransition
        }
        return .init(mediaID: object.mediaID, ownerUserID: object.ownerUserID, contentType: object.contentType, byteCount: object.byteCount, state: state, expiresAt: object.expiresAt)
    }
}

public enum V2MediaValidationError: Error, Equatable, Sendable {
    case invalidLimits
    case invalidUploadIntent
    case invalidStateTransition
    case expired
    case invalidAttachmentSet
    case invalidDownloadTarget
    case invalidUploadTarget
    case invalidPresentation
}

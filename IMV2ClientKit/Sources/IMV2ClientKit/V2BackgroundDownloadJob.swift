import Foundation
import IMV2Core

/// Persistable task identity and immutable bytes, without any object URL or header.
struct V2BackgroundDownloadTask: Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    let identifier: Int
    let grantID: UUID
    let expectedByteCount: Int64
    let checksum: V2ResourceChecksum
    let originDigest: String
    let expiresAtMilliseconds: Int64
    var expiresAt: Date { Date(timeIntervalSince1970: Double(expiresAtMilliseconds) / 1_000) }

    init(id: UUID, sessionID: UUID, identifier: Int, grantID: UUID, expectedByteCount: Int64,
         checksum: V2ResourceChecksum, originDigest: String, expiresAtMilliseconds: Int64) throws {
        guard identifier >= 0, expectedByteCount > 0, expectedByteCount <= 512 * 1_024 * 1_024,
              originDigest.utf8.count == 64,
              originDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              expiresAtMilliseconds > 0
        else { throw V2BackgroundTransferError.mappingConflict }
        self.id = id; self.sessionID = sessionID; self.identifier = identifier; self.grantID = grantID
        self.expectedByteCount = expectedByteCount; self.checksum = checksum
        self.originDigest = originDigest; self.expiresAtMilliseconds = expiresAtMilliseconds
    }
}

struct V2BackgroundDownloadJob: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case preparing
        case paused
        case transferring(V2BackgroundDownloadTask)
        case downloaded(V2BackgroundDownloadTask)
        case cancelled(V2BackgroundDownloadTask?)
    }
    let id: UUID
    let mediaID: MediaID
    let message: V2MediaMessageLocation?
    let state: State
    let attemptCount: Int
    let retryAtMilliseconds: Int64
    init(id: UUID, mediaID: MediaID, message: V2MediaMessageLocation?, state: State,
         attemptCount: Int = 0, retryAtMilliseconds: Int64 = 0) {
        self.id = id; self.mediaID = mediaID; self.message = message; self.state = state
        self.attemptCount = attemptCount; self.retryAtMilliseconds = retryAtMilliseconds
    }
}

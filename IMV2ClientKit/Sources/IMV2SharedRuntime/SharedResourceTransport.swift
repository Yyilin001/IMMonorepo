import Foundation
import IMV2Core
import IMV2ClientRuntime

actor SharedMediaResolver: V2ClientMediaDownloadTargetResolver {
    let reader: V2HTTPMediaDownloadTargetResolver
    var previewDeadlines: [MediaID: ContinuousClock.Instant] = [:]
    init(base: URL, http: V2SessionHTTPAuthorization) throws { reader = try .init(endpoint: base.appendingPathComponent("v2/media"), credentials: http, transport: http) }
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) async throws -> V2ClientMediaTransferTarget {
        let target = try await reader.resolveDownloadTarget(mediaID: mediaID, message: message)
        guard (1...33_554_432).contains(target.expectedByteCount) else { throw SharedFailure.invalidInput }; return target
    }
    func resolveImagePreviewTarget(mediaID: MediaID, message: V2MediaMessageLocation, size: V2MediaImagePreviewSize) async throws -> V2ClientMediaTransferTarget {
        let target = try await reader.resolveImagePreviewTarget(mediaID: mediaID, message: message, size: size)
        guard (1...2_097_152).contains(target.expectedByteCount) else { throw SharedFailure.invalidInput }
        previewDeadlines = previewDeadlines.filter { $0.value > .now }
        guard previewDeadlines[mediaID] != nil || previewDeadlines.count < 256 else { throw SharedFailure.busy }
        previewDeadlines[mediaID] = .now.advanced(by: .seconds(max(0, target.expiresAt.timeIntervalSinceNow)))
        return target
    }
}

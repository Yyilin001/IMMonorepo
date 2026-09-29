import IMV2ServerContracts
import Foundation
import IMV2Core

/// Construction is restricted to the server authorization boundary, never decoded from an API request.
public struct V2AuthorizedResourceDelivery: Sendable {
    public let facts: V2StoredObjectFacts
    public let expiresAt: Date
    package init(facts: V2StoredObjectFacts, expiresAt: Date) { self.facts=facts;self.expiresAt=expiresAt }
}
public protocol V2ResourceDelivery: Sendable {
    func issue(_ request: V2AuthorizedResourceDelivery) async throws -> V2ResourceTransferPlan
}

extension V2ResourceTransferPlan {
    /// An adapter cannot widen authorization or substitute different bytes.
    package func validateDownload(facts: V2StoredObjectFacts, expiresAt: Date, now: Date = Date()) throws {
        let digest = facts.sha256.map { String(format: "%02x", $0) }.joined()
        guard mode == .httpGet, expectedByteCount == facts.byteCount,
              checksum?.value == digest, self.expiresAt <= expiresAt, self.expiresAt > now
        else { throw V2ResourceProviderError.integrityMismatch }
    }
}

/// Authorizes one byte stream before returning its immutable byte facts.
/// Callers must await close after reads finish, including cancellation and failure.
public protocol V2ResourceByteServing: Sendable {
    func stream(placementID: UUID, capability: String) async throws -> (
        byteCount: Int64, etag: String, bytes: V2ResourceByteStream,
        close: @Sendable () async -> Void
    )
}

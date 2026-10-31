import Foundation

/// Exact keys retained by the receiver from one delta. This is a disposable
/// compression receipt, never authorization or a cumulative message cursor.
public struct V2AuthorPresentationReceipt: Equatable, Sendable {
    public let streamID: UUID
    public let viewID: UUID
    public let sequence: UInt64
    public let keys: [V2ProfileViewLookupKey]
    /// Minimum time still retained at receipt construction; zero confirms
    /// application but creates no compression opportunity.
    public let minimumRemainingMilliseconds: Int64

    public init(streamID: UUID, viewID: UUID, sequence: UInt64, keys: [V2ProfileViewLookupKey], minimumRemainingMilliseconds: Int64) throws {
        guard (0...V2PresentationAccessLease.maximumLifetimeMilliseconds).contains(minimumRemainingMilliseconds),
              sequence > 0, sequence <= UInt64(Int64.max),
              (1...V2AuthorPresentationDelta.maximumEntries).contains(keys.count),
              keys.allSatisfy(\.isValidAuthorPresentationKey), Set(keys).count == keys.count else {
            throw V2ResourceValidationError.invalidPresentationLease
        }
        self.streamID = streamID; self.viewID = viewID; self.sequence = sequence; self.keys = keys
        self.minimumRemainingMilliseconds = minimumRemainingMilliseconds
    }
}

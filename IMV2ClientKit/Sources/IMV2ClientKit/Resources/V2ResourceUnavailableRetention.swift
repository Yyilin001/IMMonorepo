import Foundation
import IMV2Core

/// A bounded, account-scoped selection. No inaccessible metadata leaves the
/// resource owner. Repeating a committed plan cannot remove newer selections.
public struct V2ResourceUnavailableRetentionPlan: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let count: Int
    public let hasMore: Bool
    public let expiresAt: Date
    let scope: V2AccountStorageScope
    let selections: [V2ResourceRetentionSelection]
}

struct V2ResourceRetentionSelection: Equatable, Sendable {
    let key: V2ResourceVariantKey
    let intentID: UUID
}

public struct V2ResourceUnavailableRetentionResult: Equatable, Sendable {
    public let releasedCount: Int
    public let skippedCount: Int
}

import Foundation
import IMV2ServerApplication

/// Exact PostgreSQL timestamp text avoids rounding a keyset cursor through Date.
package struct V2PolicyJournalCursor: Decodable, Sendable {
    let createdAt: String
    let operationKey: String
}
package struct V2ScannedPolicyChange: Sendable {
    let change: V2PolicyAuthorizationChange
    let cursor: V2PolicyJournalCursor
}
package struct V2PolicyChangeScanPage: Sendable {
    let entries: [V2ScannedPolicyChange]
    let hasMore: Bool
}
package struct V2PolicyCommitNotification: Equatable, Sendable {
    package let operationKey: String
    package let scopeKey: String
    package let revision: Int64
}
package struct V2ScannedPolicyPublication: Sendable {
    let notification: V2PolicyCommitNotification
    let cursor: V2PolicyJournalCursor
}
package struct V2PolicyPublicationScanPage: Sendable {
    let entries: [V2ScannedPolicyPublication]
    let hasMore: Bool
}
package struct V2PolicyRecoveryReport: Sendable {
    package let scanned: Int
    package let attempted: Int
    package let completed: Int
    package let failed: Int
    package let exhausted: Bool
}

import Foundation
import IMV2Core

/// Account/page-bound permission to read one immutable avatar rendition.
/// Only presentation repositories create it. Bytes may outlive a URL; neither
/// a cached file nor a caller-supplied descriptor can create this permission.
public struct V2AvatarReadGrant: Sendable {
    public let avatar: V2ResourceAvatarAccess
    public let home: V2ResourceHome
    /// Immutable display deadline for this particular read. A later repository
    /// renewal does not extend pixels decoded under this grant.
    public let deadline: ContinuousClock.Instant
    let downloadDeadline: ContinuousClock.Instant?
    let now: @Sendable () -> ContinuousClock.Instant
    private let validate: @Sendable () async throws -> Bool

    init(avatar: V2ResourceAvatarAccess, home: V2ResourceHome,
         deadline: ContinuousClock.Instant, downloadDeadline: ContinuousClock.Instant?,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         validate: @escaping @Sendable () async throws -> Bool) {
        self.avatar = avatar; self.home = home; self.deadline = deadline
        self.downloadDeadline = downloadDeadline; self.now = now; self.validate = validate
    }

    public func requireValid() async throws {
        try Task.checkCancellation()
        guard deadline > now(), try await validate(), deadline > now() else {
            throw V2ResourceStorageError.unavailable
        }
        try Task.checkCancellation()
    }

    func downloadPlan() throws -> V2ResourceTransferPlan {
        guard let plan = avatar.plan, let downloadDeadline, downloadDeadline > now(),
              deadline > now() else { throw V2ClientMediaTransferError.targetExpired }
        return plan
    }
}

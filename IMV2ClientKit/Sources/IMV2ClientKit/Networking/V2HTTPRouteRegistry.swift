import Foundation

/// An executable route contract; it grants neither a credential nor replay rights.
public enum V2HTTPRouteKind: String, Sendable {
    case read, authorityRead, submission, recovery, authenticationProof, credentialRecovery
    case deviceSafety, pushIntent, byteTransfer, operatorOnly
    public var accountTransportAllowed: Bool {
        switch self {
        case .read, .authorityRead, .submission, .recovery, .deviceSafety, .pushIntent: true
        case .authenticationProof, .credentialRecovery, .byteTransfer, .operatorOnly: false
        }
    }
}
public struct V2HTTPRoutePolicy: Sendable, Equatable {
    public let method: String
    public let path: String
    public let kind: V2HTTPRouteKind
    public let maximumResponseBytes: Int
    public var permitsAutomaticReplay: Bool { false }
    public var permitsSharedRead: Bool { kind == .read }
    public var requiresAccountScope: Bool { kind.accountTransportAllowed }
    public init(_ method: String, _ path: String, _ kind: V2HTTPRouteKind, maximumResponseBytes: Int = 1_048_576) {
        self.method = method; self.path = path; self.kind = kind; self.maximumResponseBytes = maximumResponseBytes
    }
}
public enum V2HTTPRouteRegistry {
    /// No prefix defaults: each added route must have a deliberate contract.
    public static let policies: [V2HTTPRoutePolicy] = [
        .init("GET", "/v2/public-identities/resolve", .authorityRead, maximumResponseBytes: 8192),
        .init("GET", "/v2/public-identities/me", .read, maximumResponseBytes: 8192),
        .init("POST", "/v2/rooms/*/member-administration/admissions", .authorityRead, maximumResponseBytes: 65_536),
        .init("POST", "/v2/rooms/*/member-administration/submit", .submission, maximumResponseBytes: 65_536),
        .init("POST", "/v2/rooms/*/member-administration/operations/recover", .recovery, maximumResponseBytes: 65_536),

        .init("POST", "/v2/rooms/*/membership/admissions", .authorityRead, maximumResponseBytes: 65_536),
        .init("POST", "/v2/rooms/*/membership/submit", .submission, maximumResponseBytes: 65_536),
        .init("POST", "/v2/rooms/*/membership/operations/recover", .recovery, maximumResponseBytes: 65_536),
        .init("POST", "/v2/rooms/*/group-capability-operations/admissions", .authorityRead, maximumResponseBytes: 65_536),
        .init("POST", "/v2/rooms/*/group-capability-operations/submit", .submission, maximumResponseBytes: 65_536),
        .init("POST", "/v2/rooms/*/group-capability-operations/operations/recover", .recovery, maximumResponseBytes: 65_536),
        .init("GET", "/v2/rooms/*/messages/*/pin-baseline", .authorityRead, maximumResponseBytes: 65_536),
        .init("POST", "/v2/group-creation-operations/begin", .submission, maximumResponseBytes: 65_536),
        .init("POST", "/v2/group-creation-operations/append", .submission, maximumResponseBytes: 65_536),
        .init("POST", "/v2/group-creation-operations/finalize", .submission, maximumResponseBytes: 65_536),
        .init("POST", "/v2/group-creation-operations/operations/recover", .recovery, maximumResponseBytes: 65_536),
        .init("GET", "/v2/social/targets/*/baseline", .authorityRead, maximumResponseBytes: 65_536),
        .init("POST", "/v2/social/operations/submit", .submission, maximumResponseBytes: 65_536),
        .init("POST", "/v2/social/operations/recover", .recovery, maximumResponseBytes: 65_536),
        .init("GET", "/v2/account-preferences/*/baseline", .authorityRead, maximumResponseBytes: 65_536),
        .init("POST", "/v2/account-preferences/operations/submit", .submission, maximumResponseBytes: 65_536),
        .init("POST", "/v2/account-preferences/operations/recover", .recovery, maximumResponseBytes: 65_536),
        .init("POST", "/v2/direct-room-operations/submit", .submission, maximumResponseBytes: 65_536),
        .init("POST", "/v2/direct-room-operations/operations/recover", .recovery, maximumResponseBytes: 65_536),
        .init("GET", "/v2/rooms/*/messages/*/moderation-baseline", .authorityRead, maximumResponseBytes: 65_536),
        .init("POST", "/v2/rooms/*/message-moderation-operations/admissions", .authorityRead, maximumResponseBytes: 65_536),
        .init("POST", "/v2/rooms/*/message-moderation-operations/submit", .submission, maximumResponseBytes: 65_536),
        .init("POST", "/v2/rooms/*/message-moderation-operations/operations/recover", .recovery, maximumResponseBytes: 65_536),
        .init("GET", "/v2/devices", .read),
        .init("POST", "/v2/devices/revoke-current", .deviceSafety),
        .init("GET", "/v2/devices/revocation-baseline", .authorityRead, maximumResponseBytes: 65_536),
        .init("POST", "/v2/devices/remote-revocations/submit", .deviceSafety, maximumResponseBytes: 65_536),
        .init("POST", "/v2/devices/remote-revocations/operations/recover", .deviceSafety, maximumResponseBytes: 65_536),
        .init("POST", "/v2/device-credentials", .authenticationProof),
        .init("POST", "/v2/device-credentials/refresh", .credentialRecovery),
        .init("POST", "/v2/device-credentials/revoke", .credentialRecovery),
        .init("POST", "/v2/device-credentials/cancel-registration", .credentialRecovery),
        .init("POST", "/v2/account-auth/password/register", .authenticationProof),
        .init("POST", "/v2/account-auth/password/assertion", .authenticationProof),
        .init("POST", "/v2/account-auth/password/change", .authenticationProof),
        .init("POST", "/v2/account-auth/password/recovery-code", .authenticationProof),
        .init("POST", "/v2/account-auth/password/recover", .authenticationProof),
        .init("GET", "/v2/profile/me", .read),
        .init("PUT", "/v2/profile/me", .submission),
        .init("POST", "/v2/profile/me/operations/recover", .recovery),
        .init("POST", "/v2/profile-presentations/batch", .authorityRead, maximumResponseBytes: 2097152),
        .init("GET", "/v2/profile-presentations/contact-aliases", .read),
        .init("GET", "/v2/profile-presentations/contact-aliases/*", .read, maximumResponseBytes: 65536),
        .init("PUT", "/v2/profile-presentations/contact-aliases/*", .submission, maximumResponseBytes: 65536),
        .init("POST", "/v2/profile-presentations/contact-aliases/*/operations/recover", .recovery, maximumResponseBytes: 65536),
        .init("GET", "/v2/profile-presentations/groups/*/nicknames", .authorityRead, maximumResponseBytes: 262144),
        .init("GET", "/v2/profile-presentations/groups/*/nickname", .read, maximumResponseBytes: 65536),
        .init("PUT", "/v2/profile-presentations/groups/*/nickname", .submission, maximumResponseBytes: 65536),
        .init("POST", "/v2/profile-presentations/groups/*/nickname/operations/recover", .recovery, maximumResponseBytes: 65536),
        .init("GET", "/v2/rooms/*/invitation-operations/baseline", .authorityRead, maximumResponseBytes: 65_536),
        .init("POST", "/v2/rooms/*/invitation-operations/admissions", .authorityRead, maximumResponseBytes: 65_536),
        .init("POST", "/v2/rooms/*/invitation-operations/submit", .submission, maximumResponseBytes: 65_536),
        .init("POST", "/v2/rooms/*/invitation-operations/operations/recover", .recovery, maximumResponseBytes: 65_536),
        .init("GET", "/v2/group-invites", .read),
        .init("POST", "/v2/group-invites/preview", .authorityRead),
        .init("GET", "/v2/group-join-requests", .read),
        .init("GET", "/v2/rooms/*/avatar", .authorityRead, maximumResponseBytes: 65536),
        .init("POST", "/v2/rooms/*/avatar", .submission, maximumResponseBytes: 16384),
        .init("POST", "/v2/rooms/*/avatar/recovery", .recovery, maximumResponseBytes: 16384),
        .init("POST", "/v2/rooms/*/message-mutations/edit", .submission, maximumResponseBytes: 65536),
        .init("POST", "/v2/rooms/*/message-mutations/withdraw", .submission, maximumResponseBytes: 65536),
        .init("POST", "/v2/rooms/*/message-mutations/operations/recover", .recovery, maximumResponseBytes: 65536),
        .init("POST", "/v2/rooms/*/message-reactions/change", .submission, maximumResponseBytes: 65536),
        .init("POST", "/v2/rooms/*/message-reactions/operations/recover", .recovery, maximumResponseBytes: 65536),
        .init("GET", "/v2/rooms/*/message-reactions/*", .read, maximumResponseBytes: 65536),
        .init("POST", "/v2/rooms/*/read-receipts/operations/recover", .recovery, maximumResponseBytes: 65536),
        .init("POST", "/v2/rooms/*/personal-preferences/operations/recover", .recovery),
        .init("POST", "/v2/forward-plans/submit", .submission),
        .init("POST", "/v2/forward-plans/operations/recover", .recovery),
        .init("GET", "/v2/resource-capabilities", .read),
        .init("POST", "/v2/rooms/*/resources/query", .authorityRead, maximumResponseBytes: 524288),
        .init("POST", "/v2/resource-uploads", .submission, maximumResponseBytes: 524288),
        .init("POST", "/v2/resource-uploads/status", .recovery, maximumResponseBytes: 524288),
        .init("POST", "/v2/resource-uploads/targets", .authorityRead, maximumResponseBytes: 524288),
        .init("POST", "/v2/resource-uploads/finalize", .submission, maximumResponseBytes: 524288),
        .init("POST", "/v2/resource-uploads/cancel", .recovery, maximumResponseBytes: 524288),
        .init("POST", "/v2/resource-imports", .submission, maximumResponseBytes: 65536),
        .init("POST", "/v2/resource-imports/status", .recovery, maximumResponseBytes: 65536),
        .init("POST", "/v2/resource-imports/cancel", .recovery, maximumResponseBytes: 65536),
        .init("GET", "/v2/media/*", .authorityRead),
        .init("GET", "/v2/resource-bytes/*", .byteTransfer),
        .init("PUT", "/v2/local-media/upload/*", .byteTransfer),
        .init("GET", "/v2/local-media/download/*", .byteTransfer),
        .init("PUT", "/v2/push-endpoint", .pushIntent, maximumResponseBytes: 1_024),
        .init("DELETE", "/v2/push-endpoint", .pushIntent, maximumResponseBytes: 1_024),
        .init("GET", "/v2/push-endpoint/session", .pushIntent, maximumResponseBytes: 1_024),
        .init("POST", "/v2/push-endpoint/session", .pushIntent, maximumResponseBytes: 1_024),
        .init("PUT", "/v2/push-endpoint/intent", .pushIntent, maximumResponseBytes: 1_024),
        .init("POST", "/internal/v2/accounts/disable", .operatorOnly),
        .init("POST", "/internal/v2/device-snapshots/reset", .operatorOnly),
        .init("POST", "/internal/v2/durable-work/replay", .operatorOnly),
        .init("POST", "/internal/v2/durable-work/replay-event", .operatorOnly),
        .init("POST", "/internal/v2/forward-work/replay", .operatorOnly)
    ]
    public static func policy(method: String, path: String) -> V2HTTPRoutePolicy? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard path.hasPrefix("/"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else { return nil }
        return policies.first {
            let pattern = $0.path.split(separator: "/").map(String.init)
            return $0.method == method.uppercased() && pattern.count == parts.count
                && zip(pattern, parts).allSatisfy { $0 == "*" || $0 == $1 }
        }
    }
}

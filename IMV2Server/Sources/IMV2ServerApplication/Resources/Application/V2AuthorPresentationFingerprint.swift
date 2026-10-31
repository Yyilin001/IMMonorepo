import Crypto
import Foundation
import IMV2Core
import IMV2ActorContracts

/// Bounded equality evidence for an already applied presentation, never an
/// authorization decision. No name, private alias, avatar URL or profile value
/// remains in the per-recipient acknowledgement cache.
struct V2AuthorPresentationFingerprint: Equatable {
    let profileRevision, nicknameRevision, aliasRevision: UInt64
    private let digest: Data

    init(_ value: V2AuthorizedProfilePresentation, avatar: V2ResourceAvatarAccess?) throws {
        try self.init(Content(value, avatar: avatar))
    }

    private init(_ content: Content) throws {
        profileRevision = content.view.revision.rawValue
        nicknameRevision = content.groupMember?.revision.rawValue ?? 0
        aliasRevision = content.contactAlias?.revision.rawValue ?? 0
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        digest = Data(SHA256.hash(data: try encoder.encode(content)))
    }

    /// Lives only while one bounded authority batch is consumed. Reuses content
    /// hashing/accounting across recipients after comparing all content and
    /// authority fields; it never caches or replaces a recipient's access lease.
    struct Batch {
        struct Prepared {
            let fingerprint: V2AuthorPresentationFingerprint
            let retainedBytes: Int
        }
        private struct Entry { let content: Content; let prepared: Prepared }
        private var entries: [V2ProfileViewLookupKey: Entry] = [:]
        private(set) var calculations = 0
        var count: Int { entries.count }

        mutating func prepare(_ value: V2AuthorizedProfilePresentation, avatar: V2ResourceAvatarAccess?) throws -> Prepared {
            let key = value.lease.key, content = Content(value, avatar: avatar)
            if let old = entries[key], old.content == content { return old.prepared }
            let fingerprint = try V2AuthorPresentationFingerprint(content)
            let prepared = Prepared(fingerprint: fingerprint,
                retainedBytes: 256 + V2ActorPayloadBudget.retainedBytes(of: fingerprint)
                    + V2ActorPayloadBudget.retainedBytes(of: key))
            calculations += 1
            if entries[key] != nil || entries.count < 100 { entries[key] = .init(content: content, prepared: prepared) }
            return prepared
        }
    }

    private struct Content: Encodable, Equatable {
        let view: V2ProfileView
        let authority: V2PresentationAuthorityVersion
        let groupMember: V2GroupMemberPresentation?
        let contactAlias: V2ContactAlias?
        let avatar: V2ResourceAvatarAccess?

        init(_ value: V2AuthorizedProfilePresentation, avatar: V2ResourceAvatarAccess?) {
            view = value.view; authority = value.lease.authorityVersion
            groupMember = value.groupMember; contactAlias = value.contactAlias
            self.avatar = avatar?.withoutDownloadPlan()
        }
    }
}

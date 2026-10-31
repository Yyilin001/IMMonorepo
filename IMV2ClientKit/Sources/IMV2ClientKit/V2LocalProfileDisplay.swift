import Foundation
import IMV2Core

/// Account-local display facts. No avatar capability, URL, token or access lease
/// is stored here. These facts never authorize fetching protected resources.
public struct V2LocalProfileDisplay: Codable, Equatable, Sendable {
    public let key: V2ProfileViewLookupKey
    public let identity: V2PublicIdentity
    public let profileRevision: V2ProfileRevision
    public let visibilityRevision: V2ProfileRevision
    public let contextRevision: UInt64
    public let alias: V2ContactAlias?
    public let member: V2GroupMemberPresentation?
    public let observedAt: Int64

    init?(_ presentation: V2AuthorizedProfilePresentation) {
        guard presentation.view.state == .active, let identity = presentation.view.publicIdentity else { return nil }
        key = presentation.lease.key; self.identity = identity
        profileRevision = presentation.view.revision; visibilityRevision = presentation.view.visibilityRevision
        contextRevision = presentation.lease.contextRevision; alias = presentation.contactAlias
        member = presentation.groupMember; observedAt = presentation.lease.observedAtUnixMilliseconds
    }

    func supersedes(_ previous: Self) -> Bool {
        profileRevision >= previous.profileRevision && visibilityRevision >= previous.visibilityRevision
            && contextRevision >= previous.contextRevision && observedAt >= previous.observedAt
            && (alias?.revision.rawValue ?? 0) >= (previous.alias?.revision.rawValue ?? 0)
            && (member?.revision.rawValue ?? 0) >= (previous.member?.revision.rawValue ?? 0)
    }
}

/// Public identity and the account's own remark outlive individual page/context
/// entries. Denying one room cannot roll another screen back to an older name.
struct V2LocalProfileDisplayBasics: Codable, Sendable {
    let identity: V2PublicIdentity
    let profileRevision: V2ProfileRevision
    let visibilityRevision: V2ProfileRevision
    let alias: V2ContactAlias?
    init(_ record: V2LocalProfileDisplay, previous: Self? = nil) {
        let newer = previous.map { record.profileRevision >= $0.profileRevision && record.visibilityRevision >= $0.visibilityRevision } ?? true
        identity = newer ? record.identity : previous!.identity
        profileRevision = newer ? record.profileRevision : previous!.profileRevision
        visibilityRevision = newer ? record.visibilityRevision : previous!.visibilityRevision
        if let incoming = record.alias, previous?.alias.map({ incoming.revision >= $0.revision }) ?? true { alias = incoming }
        else { alias = previous?.alias }
    }
}

public struct V2LocalProfileDisplaySnapshot: Sendable {
    public let records: [V2ProfileViewLookupKey: V2LocalProfileDisplay]
    public let deniedKeys: Set<V2ProfileViewLookupKey>
    public let deniedUsers: Set<UserID>
    let basics: [UserID: V2LocalProfileDisplayBasics]

    init(records: [V2ProfileViewLookupKey: V2LocalProfileDisplay] = [:],
         deniedKeys: Set<V2ProfileViewLookupKey> = [], deniedUsers: Set<UserID> = [],
         basics: [UserID: V2LocalProfileDisplayBasics] = [:]) {
        self.records = records; self.deniedKeys = deniedKeys; self.deniedUsers = deniedUsers
        var merged = basics
        for record in records.values {
            merged[record.key.userID] = .init(record, previous: merged[record.key.userID])
        }
        self.basics = merged
    }

    public struct Value: Sendable, Equatable {
        public let name: String
        public let identity: V2PublicIdentity
    }
    public func value(for key: V2ProfileViewLookupKey) -> Value? {
        guard !deniedKeys.contains(key), !deniedUsers.contains(key.userID),
              let publicProfile = basics[key.userID] else { return nil }
        // Public names and the current account's own contact remarks are shared
        // by contact/direct screens. A room uses remarks only where its exact
        // presentation allowed them; group nicknames never cross rooms.
        let scoped = records[key]
        let permitsRemark: Bool = switch key.context {
        case .directConversation, .relationship: true
        case .room, .groupJoinReview: scoped?.alias != nil
        }
        let name = (permitsRemark ? publicProfile.alias?.remarkName : nil)
            ?? scoped?.member?.groupNickname ?? publicProfile.identity.displayName
        return .init(name: name, identity: publicProfile.identity)
    }
}

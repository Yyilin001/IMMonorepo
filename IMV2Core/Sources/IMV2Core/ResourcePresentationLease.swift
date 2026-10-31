import Foundation

/// 服务端返回的有界展示许可，不是下载能力，也不是服务端授权 witness。
/// 客户端还须绑定本地 account epoch/page activation；切后台、离页或失效事件会提前终止。
public struct V2PresentationAccessLease: Equatable, Codable, Sendable {
    public static let maximumLifetimeMilliseconds: Int64 = 300_000
    public let actorUserID: UserID
    public let deviceID: DeviceID
    public let key: V2ProfileViewLookupKey
    public let profileRevision: V2ProfileRevision
    public let visibilityRevision: V2ProfileRevision
    public let contextRevision: UInt64
    public let authorityVersion: V2PresentationAuthorityVersion
    public let observedAtUnixMilliseconds: Int64
    public let validUntilUnixMilliseconds: Int64
    public var observedAt: Date { V2ResourceTime.date(observedAtUnixMilliseconds) }
    public var validUntil: Date { V2ResourceTime.date(validUntilUnixMilliseconds) }

    public init(actorUserID: UserID, deviceID: DeviceID, key: V2ProfileViewLookupKey,
                profileRevision: V2ProfileRevision, visibilityRevision: V2ProfileRevision,
                contextRevision: UInt64, authorityVersion: V2PresentationAuthorityVersion, observedAt: Date, validUntil: Date) throws {
        try self.init(actorUserID: actorUserID, deviceID: deviceID, key: key, profileRevision: profileRevision,
                      visibilityRevision: visibilityRevision, contextRevision: contextRevision, authorityVersion: authorityVersion,
                      observedAtUnixMilliseconds: V2ResourceTime.milliseconds(observedAt),
                      validUntilUnixMilliseconds: V2ResourceTime.milliseconds(validUntil))
    }

    private init(actorUserID: UserID, deviceID: DeviceID, key: V2ProfileViewLookupKey,
                 profileRevision: V2ProfileRevision, visibilityRevision: V2ProfileRevision,
                 contextRevision: UInt64, authorityVersion: V2PresentationAuthorityVersion,
                 observedAtUnixMilliseconds: Int64, validUntilUnixMilliseconds: Int64) throws {
        let duration = validUntilUnixMilliseconds.subtractingReportingOverflow(observedAtUnixMilliseconds)
        guard !duration.overflow, duration.partialValue > 0,
              duration.partialValue <= Self.maximumLifetimeMilliseconds, contextRevision <= UInt64(Int64.max),
              authorityVersion.matches(key.context), authorityVersion.membershipRevision == contextRevision
        else { throw V2ResourceValidationError.invalidPresentationLease }
        self.actorUserID = actorUserID
        self.deviceID = deviceID
        self.key = key
        self.profileRevision = profileRevision
        self.visibilityRevision = visibilityRevision
        self.contextRevision = contextRevision
        self.authorityVersion = authorityVersion
        self.observedAtUnixMilliseconds = observedAtUnixMilliseconds
        self.validUntilUnixMilliseconds = validUntilUnixMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case actorUserID, deviceID, key, profileRevision, visibilityRevision, contextRevision, authorityVersion
        case observedAtUnixMilliseconds, validUntilUnixMilliseconds
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(actorUserID: values.decode(UserID.self, forKey: .actorUserID), deviceID: values.decode(DeviceID.self, forKey: .deviceID),
                      key: values.decode(V2ProfileViewLookupKey.self, forKey: .key), profileRevision: values.decode(V2ProfileRevision.self, forKey: .profileRevision),
                      visibilityRevision: values.decode(V2ProfileRevision.self, forKey: .visibilityRevision), contextRevision: values.decode(UInt64.self, forKey: .contextRevision),
                      authorityVersion: values.decode(V2PresentationAuthorityVersion.self, forKey: .authorityVersion),
                      observedAtUnixMilliseconds: values.decode(Int64.self, forKey: .observedAtUnixMilliseconds),
                      validUntilUnixMilliseconds: values.decode(Int64.self, forKey: .validUntilUnixMilliseconds))
    }
}

/// 仅对 lease 指定的用户、设备、上下文有效的展示值。下载目标独立交付且不得持久化。
public struct V2AuthorizedProfilePresentation: Equatable, Codable, Sendable {
    public let view: V2ProfileView
    public let lease: V2PresentationAccessLease
    /// Room-local content under this same recipient/context lease. Nil means
    /// no nickname row; a cleared nickname retains its nonzero row revision.
    public let groupMember: V2GroupMemberPresentation?
    /// Private owner field bound to this recipient and target. A cleared row retains its revision.
    public let contactAlias: V2ContactAlias?

    public init(view: V2ProfileView, lease: V2PresentationAccessLease,
                groupMember: V2GroupMemberPresentation? = nil, contactAlias: V2ContactAlias? = nil) throws {
        guard view.userID == lease.key.userID, view.revision == lease.profileRevision,
              view.visibilityRevision == lease.visibilityRevision
        else { throw V2ResourceValidationError.invalidPresentationLease }
        self.view = try V2ProfileView(userID: view.userID, publicIdentity: view.publicIdentity,
                                     avatar: view.avatar, state: view.state, revision: view.revision,
                                     visibilityRevision: view.visibilityRevision)
        if let groupMember {
            guard view.state == .active, case .room(let room) = lease.key.context,
                  groupMember.roomID == room, groupMember.userID == view.userID,
                  try V2GroupMemberPresentation(roomID: room, userID: view.userID,
                    groupNickname: groupMember.groupNickname, revision: groupMember.revision) == groupMember
            else { throw V2ResourceValidationError.invalidPresentationLease }
        }
        if let contactAlias {
            guard view.state == .active, contactAlias.ownerUserID == lease.actorUserID,
                  contactAlias.targetUserID == view.userID, contactAlias.ownerUserID != contactAlias.targetUserID,
                  try V2ContactAlias(ownerUserID: contactAlias.ownerUserID, targetUserID: view.userID,
                    remarkName: contactAlias.remarkName, revision: contactAlias.revision) == contactAlias
            else { throw V2ResourceValidationError.invalidPresentationLease }
        }
        self.lease = lease
        self.groupMember = groupMember
        self.contactAlias = contactAlias
    }

    private enum CodingKeys: String, CodingKey { case view, lease, groupMember, contactAlias }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(view: values.decode(V2ProfileView.self, forKey: .view), lease: values.decode(V2PresentationAccessLease.self, forKey: .lease),
                      groupMember: values.decodeIfPresent(V2GroupMemberPresentation.self, forKey: .groupMember),
                      contactAlias: values.decodeIfPresent(V2ContactAlias.self, forKey: .contactAlias))
    }
}

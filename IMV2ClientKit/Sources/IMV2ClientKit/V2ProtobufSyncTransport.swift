import Crypto
import Foundation
import IMV2Core

/// The authenticated framed connection used by the sync adapter. A concrete
/// TLS client owns reconnect/authentication; this boundary only sends one
/// request and returns the correlated frame, which makes all sync mappings
/// deterministic in offline unit tests.
public protocol V2AuthenticatedFrameTransport: Sendable {
    func request(_ frame: V2Frame) async throws -> V2Frame
}

public struct V2ClientMessageAcceptance: Equatable, Sendable {
    public let messageID: MessageID
    public let roomID: RoomID
    public let roomSequence: UInt64
    public let media: [V2MediaReference]
    public let mentions: [V2MentionTarget]
    public let createdAt: Date

    public init(messageID: MessageID, roomID: RoomID, roomSequence: UInt64, media: [V2MediaReference] = [], mentions: [V2MentionTarget] = [], createdAt: Date) {
        self.messageID = messageID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.media = media
        self.mentions = mentions
        self.createdAt = createdAt
    }
}

public protocol V2ClientMessageTransport: Sendable {
    func sendMessage(roomID: RoomID, clientMessageID: ClientMessageID, text: String, media: [V2MediaReference], mentions: [V2MentionTarget]) async throws -> V2ClientMessageAcceptance
}

public struct V2ClientMembershipChange: Equatable, Sendable {
    public let roomID: RoomID
    public let targetUserID: UserID
    public let action: V2RoomMembershipAction
    public let membershipRevision: UInt64
    public let roomSequence: UInt64
    public let createdAt: Date

    public init(roomID: RoomID, targetUserID: UserID, action: V2RoomMembershipAction, membershipRevision: UInt64, roomSequence: UInt64, createdAt: Date) {
        self.roomID = roomID
        self.targetUserID = targetUserID
        self.action = action
        self.membershipRevision = membershipRevision
        self.roomSequence = roomSequence
        self.createdAt = createdAt
    }
}

public protocol V2ClientMembershipTransport: Sendable {
    func changeMembership(roomID: RoomID, operationID: MembershipOperationID, targetUserID: UserID, action: V2RoomMembershipAction, expectedMembershipRevision: UInt64) async throws -> V2ClientMembershipChange
}

/// Read-only page used by a group-management screen.  It is intentionally
/// fetched on demand instead of being duplicated into every sync record.
public struct V2ClientRoomMember: Equatable, Sendable {
    public let userID: UserID
    public let role: V2RoomMembershipRole
    /// Public profile authorized by the active-room roster read.  It is not a
    /// replacement for a durable contact graph and may be absent while an
    /// older server deployment is being rolled forward.
    public let publicIdentity: V2PublicIdentity?

    public init(userID: UserID, role: V2RoomMembershipRole, publicIdentity: V2PublicIdentity? = nil) {
        self.userID = userID
        self.role = role
        self.publicIdentity = publicIdentity
    }
}

public struct V2ClientRoomMembersPage: Equatable, Sendable {
    public let roomID: RoomID
    public let membershipRevision: UInt64
    public let actorRole: V2RoomMembershipRole
    public let members: [V2ClientRoomMember]
    public let nextCursor: String?

    public init(roomID: RoomID, membershipRevision: UInt64, actorRole: V2RoomMembershipRole, members: [V2ClientRoomMember], nextCursor: String?) {
        self.roomID = roomID
        self.membershipRevision = membershipRevision
        self.actorRole = actorRole
        self.members = members
        self.nextCursor = nextCursor
    }
}

public protocol V2ClientMembershipDirectoryTransport: Sendable {
    func listRoomMembers(roomID: RoomID, cursor: String?, pageSize: Int) async throws -> V2ClientRoomMembersPage
}

public enum V2ClientRoomMembersPageLimits {
    public static let maximumPageSize = 100
}

public struct V2ClientDirectRoom: Equatable, Sendable {
    public let roomID: RoomID
    public let targetUserID: UserID
    public let createdAt: Date

    public init(roomID: RoomID, targetUserID: UserID, createdAt: Date) {
        self.roomID = roomID
        self.targetUserID = targetUserID
        self.createdAt = createdAt
    }
}

/// Authenticated client boundary for direct-room initiation and the
/// device-independent stranger-message preference.
public protocol V2ClientDirectMessagingTransport: Sendable {
    func openDirectRoom(operationID: DirectRoomOperationID, targetUserID: UserID) async throws -> V2ClientDirectRoom
    func setStrangerMessagePermission(operationID: StrangerMessagePreferenceOperationID, permission: V2StrangerMessagePermission) async throws -> Date
}

public struct V2ClientGroupRoom: Equatable, Sendable {
    public let roomID: RoomID
    public let title: String
    public let deliveryMode: V2GroupDeliveryMode
    public let memberUserIDs: [UserID]
    public let memberCount: UInt32
    public let createdAt: Date

    public init(roomID: RoomID, title: String, deliveryMode: V2GroupDeliveryMode, memberUserIDs: [UserID], memberCount: UInt32, createdAt: Date) {
        self.roomID = roomID
        self.title = title
        self.deliveryMode = deliveryMode
        self.memberUserIDs = memberUserIDs.sorted()
        self.memberCount = memberCount
        self.createdAt = createdAt
    }
}

/// A bounded server-side staging acknowledgement. It deliberately exposes no
/// roster: the count is enough for a durable client outbox to resume pages.
public struct V2ClientGroupAudienceDraft: Equatable, Sendable {
    public let operationID: GroupRoomOperationID
    public let title: String
    public let stagedMemberCount: Int

    public init(operationID: GroupRoomOperationID, title: String, stagedMemberCount: Int) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, stagedMemberCount >= 0 else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
        self.operationID = operationID
        self.title = title
        self.stagedMemberCount = stagedMemberCount
    }
}

/// Authenticated boundary for the atomic group-bootstrap command. The caller
/// owns the durable operation ID and may retry the exact same intent.
public protocol V2ClientGroupMessagingTransport: Sendable {
    func beginGroupRoomCreation(operationID: GroupRoomOperationID, title: String) async throws -> V2ClientGroupAudienceDraft
    func appendGroupRoomCreationMembers(operationID: GroupRoomOperationID, memberUserIDs: [UserID]) async throws -> V2ClientGroupAudienceDraft
    func finalizeGroupRoomCreation(operationID: GroupRoomOperationID) async throws -> V2ClientGroupRoom
    /// Cancels a mutable server-side draft. Clients call this only after their
    /// local durable intent has been removed/cancelled by product policy.
    func cancelGroupRoomCreation(operationID: GroupRoomOperationID) async throws
}

/// Authenticated social command boundary. These calls return canonical server
/// state, but the client still treats the subsequent sync projection as the
/// durable source for multi-device UI convergence.
public protocol V2ClientSocialRelationshipTransport: Sendable {
    func changeRelationship(operationID: RelationshipOperationID, targetUserID: UserID, action: V2RelationshipAction) async throws -> V2ClientRelationshipChange
    func changeUserBlock(operationID: UserBlockOperationID, targetUserID: UserID, action: V2UserBlockAction) async throws -> V2ClientUserBlockChange
}

public struct V2ClientRelationshipChange: Equatable, Sendable {
    public let targetUserID: UserID
    public let action: V2RelationshipAction
    public let resultingState: V2RelationshipState
    public let updatedAt: Date
    public init(targetUserID: UserID, action: V2RelationshipAction, resultingState: V2RelationshipState, updatedAt: Date) { self.targetUserID = targetUserID; self.action = action; self.resultingState = resultingState; self.updatedAt = updatedAt }
}

public struct V2ClientUserBlockChange: Equatable, Sendable {
    public let targetUserID: UserID
    public let action: V2UserBlockAction
    public let isBlocked: Bool
    public let updatedAt: Date
    public init(targetUserID: UserID, action: V2UserBlockAction, isBlocked: Bool, updatedAt: Date) { self.targetUserID = targetUserID; self.action = action; self.isBlocked = isBlocked; self.updatedAt = updatedAt }
}

public struct V2ClientMessageWithdrawal: Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let messageRevision: UInt64
    public let roomSequence: UInt64
    public let createdAt: Date

    public init(roomID: RoomID, messageID: MessageID, messageRevision: UInt64, roomSequence: UInt64, createdAt: Date) {
        self.roomID = roomID
        self.messageID = messageID
        self.messageRevision = messageRevision
        self.roomSequence = roomSequence
        self.createdAt = createdAt
    }
}

public protocol V2ClientMessageWithdrawalTransport: Sendable {
    func withdrawMessage(roomID: RoomID, operationID: MessageWithdrawalOperationID, messageID: MessageID, expectedMessageRevision: UInt64) async throws -> V2ClientMessageWithdrawal
}

public struct V2ClientMessageRedaction: Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let messageRevision: UInt64
    public let roomSequence: UInt64
    public let createdAt: Date

    public init(roomID: RoomID, messageID: MessageID, messageRevision: UInt64, roomSequence: UInt64, createdAt: Date) {
        self.roomID = roomID
        self.messageID = messageID
        self.messageRevision = messageRevision
        self.roomSequence = roomSequence
        self.createdAt = createdAt
    }
}

public protocol V2ClientMessageRedactionTransport: Sendable {
    func redactMessage(roomID: RoomID, operationID: ModerationOperationID, messageID: MessageID, reasonCode: V2ModerationReasonCode) async throws -> V2ClientMessageRedaction
}

public struct V2ClientMemberMute: Equatable, Sendable {
    public let roomID: RoomID
    public let targetUserID: UserID
    public let muteUntil: Date
    public let roomSequence: UInt64
    public let createdAt: Date

    public init(roomID: RoomID, targetUserID: UserID, muteUntil: Date, roomSequence: UInt64, createdAt: Date) {
        self.roomID = roomID
        self.targetUserID = targetUserID
        self.muteUntil = muteUntil
        self.roomSequence = roomSequence
        self.createdAt = createdAt
    }
}

public protocol V2ClientMemberMuteTransport: Sendable {
    func muteMember(roomID: RoomID, operationID: ModerationOperationID, targetUserID: UserID, muteUntil: Date, reasonCode: V2ModerationReasonCode) async throws -> V2ClientMemberMute
}

/// Receipt for the separately auditable moderation removal command.  Ordinary
/// membership administration intentionally has a different durable operation
/// record and transport method.
public struct V2ClientModeratedMemberRemoval: Equatable, Sendable {
    public let roomID: RoomID
    public let targetUserID: UserID
    public let membershipRevision: UInt64
    public let roomSequence: UInt64
    public let createdAt: Date

    public init(roomID: RoomID, targetUserID: UserID, membershipRevision: UInt64, roomSequence: UInt64, createdAt: Date) {
        self.roomID = roomID
        self.targetUserID = targetUserID
        self.membershipRevision = membershipRevision
        self.roomSequence = roomSequence
        self.createdAt = createdAt
    }
}

public protocol V2ClientModeratedMemberRemovalTransport: Sendable {
    func removeMemberByModerator(roomID: RoomID, operationID: ModerationOperationID, targetUserID: UserID, reasonCode: V2ModerationReasonCode) async throws -> V2ClientModeratedMemberRemoval
}

public struct V2ClientMessageEdit: Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let text: String
    public let messageRevision: UInt64
    public let roomSequence: UInt64
    public let createdAt: Date
}

public protocol V2ClientMessageEditTransport: Sendable {
    func editMessage(roomID: RoomID, operationID: MessageEditOperationID, messageID: MessageID, expectedMessageRevision: UInt64, text: String) async throws -> V2ClientMessageEdit
}

public struct V2ClientReadReceipt: Equatable, Sendable {
    public let roomID: RoomID
    public let userID: UserID
    public let readThroughRoomSequence: UInt64
    public let recordedAt: Date
}

public protocol V2ClientReadReceiptTransport: Sendable {
    func recordReadReceipt(roomID: RoomID, operationID: ReadReceiptOperationID, readThroughRoomSequence: UInt64) async throws -> V2ClientReadReceipt
}

public struct V2ClientMessageReactionChange: Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let actorUserID: UserID
    public let reaction: String
    public let action: V2MessageReactionAction
    public let roomSequence: UInt64
    public let createdAt: Date
}

public protocol V2ClientMessageReactionTransport: Sendable {
    func changeMessageReaction(roomID: RoomID, operationID: MessageReactionOperationID, messageID: MessageID, reaction: String, action: V2MessageReactionAction) async throws -> V2ClientMessageReactionChange
}

public protocol V2HeartbeatSender: Sendable {
    func sendHeartbeat(clientTime: Date) async throws
}

public enum V2RealtimeTransportError: Error, Equatable, Sendable {
    case unexpectedResponse
    case invalidSnapshotManifest
    case invalidSnapshotPage
    case snapshotDigestMismatch
    /// `currentRevision` is only meaningful for a revision-conflict response;
    /// it remains optional because protobuf scalar fields have no presence in
    /// this protocol version.
    case server(code: String, retryable: Bool, retryAfterSeconds: UInt32, currentRevision: UInt64?)
}

public protocol V2SnapshotPageDigestVerifier: Sendable {
    func matches(payload: Data, expectedDigest: String) -> Bool
}

/// V2 snapshot manifests use lower-case SHA-256 hexadecimal page digests.
public struct V2SHA256SnapshotPageDigestVerifier: V2SnapshotPageDigestVerifier {
    public init() {}

    public func matches(payload: Data, expectedDigest: String) -> Bool {
        let actual = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return actual == expectedDigest.lowercased()
    }
}

/// Maps protobuf envelopes at the authenticated frame boundary onto the
/// SyncEngine transport protocol. DTO validation happens here; the engine only
/// sees V2 value types suitable for durable local application.
public actor V2ProtobufSyncTransport: V2ClientSyncTransport, V2ClientMessageTransport, V2ClientMembershipTransport, V2ClientMembershipDirectoryTransport, V2ClientDirectMessagingTransport, V2ClientGroupMessagingTransport, V2ClientGroupEventTransport, V2ClientGroupEventSubscriptionTransport, V2ClientSocialRelationshipTransport, V2ClientMessageWithdrawalTransport, V2ClientMessageRedactionTransport, V2ClientMemberMuteTransport, V2ClientModeratedMemberRemovalTransport, V2ClientMessageEditTransport, V2ClientMessageReactionTransport, V2ClientReadReceiptTransport, V2HeartbeatSender {
    private let wire: any V2AuthenticatedFrameTransport
    private let protocolVersion: UInt8
    private let maximumSnapshotPages: Int
    private let pageDigestVerifier: any V2SnapshotPageDigestVerifier
    private var nextRequestID: UInt64 = 1

    public init(
        wire: any V2AuthenticatedFrameTransport,
        protocolVersion: UInt8,
        maximumSnapshotPages: Int = 10_000,
        pageDigestVerifier: any V2SnapshotPageDigestVerifier = V2SHA256SnapshotPageDigestVerifier()
    ) {
        precondition(protocolVersion > 0 && maximumSnapshotPages > 0)
        self.wire = wire
        self.protocolVersion = protocolVersion
        self.maximumSnapshotPages = maximumSnapshotPages
        self.pageDigestVerifier = pageDigestVerifier
    }

    public func pull(syncToken: V2SyncToken?, maxRecords: Int) async throws -> V2ClientPullResult {
        var request = IMV2Envelope()
        request.syncPull = .init()
        request.syncPull.syncToken = syncToken?.rawValue ?? ""
        request.syncPull.maxRecords = UInt32(clamping: maxRecords)
        let response = try await requestEnvelope(request)
        switch response.body {
        case .syncBatch(let batch):
            let records = try batch.records.map {
                try V2ClientSyncRecord(sequence: $0.userSyncSequence, sourceEventID: .init($0.sourceEventID), projectionKind: $0.projectionKind, payload: $0.payload)
            }
            return .ready(try .init(generation: batch.generation, records: records, nextSyncToken: .init(batch.nextSyncToken), receipt: .init(batch.syncReceipt), hasMore: batch.hasMore_p, capabilityProfile: batch.capabilityProfile))
        case .resetRequired(let reset):
            return .resetRequired(try .init(snapshotID: .init(reset.snapshotID), generation: reset.generation, baseSequence: reset.baseUserSyncSequence, manifestDigest: reset.manifestDigest, expiresAt: Date(timeIntervalSince1970: TimeInterval(reset.expiresAtMs) / 1_000)))
        default:
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
    }

    public func acknowledge(generation: UInt64, highestContiguousSequence: UInt64, receipt: V2SyncReceipt) async throws {
        var request = IMV2Envelope()
        request.syncAck = .init()
        request.syncAck.generation = generation
        request.syncAck.highestContiguousSequence = highestContiguousSequence
        request.syncAck.syncReceipt = receipt.rawValue
        let response = try await requestEnvelope(request)
        guard case .acknowledged? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
    }

    public func sendHeartbeat(clientTime: Date = Date()) async throws {
        var request = IMV2Envelope()
        request.heartbeat = .init()
        request.heartbeat.clientTimeMs = UInt64(max(0, clientTime.timeIntervalSince1970 * 1_000))
        let response = try await requestEnvelope(request)
        guard case .heartbeatAck? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
    }

    public func fetchSnapshotManifest(for reset: V2ClientResetRequired) async throws -> V2ClientSnapshotManifest {
        var request = IMV2Envelope()
        request.syncSnapshot = .init()
        request.syncSnapshot.snapshotID = reset.snapshotID.rawValue
        request.syncSnapshot.generation = reset.generation
        let response = try await requestEnvelope(request)
        guard case .snapshotManifest(let manifest)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        guard manifest.snapshotID == reset.snapshotID.rawValue,
              manifest.generation == reset.generation,
              manifest.baseUserSyncSequence == reset.baseSequence,
              manifest.manifestDigest == reset.manifestDigest,
              manifest.schemaVersion == V2SnapshotProjectionCodec.schemaVersion,
              manifest.expiresAtMs > Int64(Date().timeIntervalSince1970 * 1_000),
              !manifest.nextSyncToken.isEmpty,
              !manifest.syncReceipt.isEmpty,
              !manifest.capabilityProfile.isEmpty,
              manifest.pageDigests.count <= maximumSnapshotPages,
              !manifest.pageDigests.isEmpty
        else { throw V2RealtimeTransportError.invalidSnapshotManifest }

        return try .init(reset: reset, pageDigests: manifest.pageDigests, nextSyncToken: .init(manifest.nextSyncToken), receipt: .init(manifest.syncReceipt), capabilityProfile: manifest.capabilityProfile)
    }

    public func fetchSnapshotPage(for manifest: V2ClientSnapshotManifest, index: Int) async throws -> V2ClientSnapshotPage {
        guard manifest.pageDigests.indices.contains(index) else { throw V2RealtimeTransportError.invalidSnapshotPage }
        var request = IMV2Envelope()
        request.snapshotPagePull = .init()
        request.snapshotPagePull.snapshotID = manifest.reset.snapshotID.rawValue
        request.snapshotPagePull.generation = manifest.reset.generation
        request.snapshotPagePull.manifestDigest = manifest.reset.manifestDigest
        request.snapshotPagePull.pageIndex = UInt32(index)
        let response = try await requestEnvelope(request)
        guard case .snapshotPage(let page)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        let expectedDigest = manifest.pageDigests[index]
        guard page.snapshotID == manifest.reset.snapshotID.rawValue,
              page.generation == manifest.reset.generation,
              page.manifestDigest == manifest.reset.manifestDigest,
              page.pageIndex == UInt32(index),
              page.pageDigest == expectedDigest,
              pageDigestVerifier.matches(payload: page.payload, expectedDigest: expectedDigest)
        else { throw V2RealtimeTransportError.snapshotDigestMismatch }
        return .init(index: index, digest: expectedDigest, payload: page.payload)
    }

    public func acknowledgeSnapshot(_ manifest: V2ClientSnapshotManifest) async throws {
        var request = IMV2Envelope()
        request.snapshotAck = .init()
        request.snapshotAck.snapshotID = manifest.reset.snapshotID.rawValue
        request.snapshotAck.generation = manifest.reset.generation
        request.snapshotAck.baseUserSyncSequence = manifest.reset.baseSequence
        request.snapshotAck.snapshotReceipt = manifest.receipt.rawValue
        let response = try await requestEnvelope(request)
        guard case .acknowledged? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
    }

    public func sendMessage(roomID: RoomID, clientMessageID: ClientMessageID, text: String, media: [V2MediaReference], mentions: [V2MentionTarget]) async throws -> V2ClientMessageAcceptance {
        var request = IMV2Envelope()
        request.sendMessage = .init()
        request.sendMessage.roomID = roomID.rawValue
        request.sendMessage.clientMessageID = clientMessageID.rawValue
        request.sendMessage.content = .init()
        request.sendMessage.content.text = text
        request.sendMessage.content.mediaIds = media.map { $0.mediaID.rawValue }
        request.sendMessage.content.mentionedUserIds = mentions.compactMap { if case .user(let userID) = $0 { userID.rawValue } else { nil } }
        request.sendMessage.content.mentionEveryone = mentions.contains(.everyone)
        let response = try await requestEnvelope(request)
        guard case .messageAccepted(let accepted)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        let acceptedMedia = try accepted.mediaIds.map { try V2MediaReference(mediaID: .init($0)) }
        var acceptedMentions = try accepted.mentionedUserIds.map { try V2MentionTarget.user(.init($0)) }
        if accepted.mentionsEveryone { acceptedMentions.append(.everyone) }
        guard acceptedMedia == media, acceptedMentions == mentions else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(messageID: .init(accepted.messageID), roomID: .init(accepted.roomID), roomSequence: accepted.roomSequence, media: acceptedMedia, mentions: acceptedMentions, createdAt: Date(timeIntervalSince1970: TimeInterval(accepted.serverCreatedAtMs) / 1_000))
    }

    public func changeMembership(roomID: RoomID, operationID: MembershipOperationID, targetUserID: UserID, action: V2RoomMembershipAction, expectedMembershipRevision: UInt64) async throws -> V2ClientMembershipChange {
        var request = IMV2Envelope()
        request.changeRoomMembership = .init()
        request.changeRoomMembership.roomID = roomID.rawValue
        request.changeRoomMembership.operationID = operationID.rawValue
        request.changeRoomMembership.targetUserID = targetUserID.rawValue
        request.changeRoomMembership.action = action == .add ? .add : .remove
        request.changeRoomMembership.expectedMembershipRevision = expectedMembershipRevision
        let response = try await requestEnvelope(request)
        guard case .membershipChanged(let changed)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        let returnedAction: V2RoomMembershipAction
        switch changed.action {
        case .add: returnedAction = .add
        case .remove: returnedAction = .remove
        case .unspecified, .UNRECOGNIZED: throw V2RealtimeTransportError.unexpectedResponse
        }
        guard returnedAction == action,
              changed.roomID == roomID.rawValue,
              changed.targetUserID == targetUserID.rawValue
        else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(changed.roomID), targetUserID: .init(changed.targetUserID), action: returnedAction, membershipRevision: changed.membershipRevision, roomSequence: changed.roomSequence, createdAt: Date(timeIntervalSince1970: TimeInterval(changed.serverCreatedAtMs) / 1_000))
    }

    public func listRoomMembers(roomID: RoomID, cursor: String?, pageSize: Int) async throws -> V2ClientRoomMembersPage {
        guard pageSize > 0, pageSize <= V2ClientRoomMembersPageLimits.maximumPageSize else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
        var request = IMV2Envelope(); request.listRoomMembers = .init()
        request.listRoomMembers.roomID = roomID.rawValue
        request.listRoomMembers.cursor = cursor ?? ""
        request.listRoomMembers.pageSize = UInt32(pageSize)
        let response = try await requestEnvelope(request)
        guard case .roomMembersPage(let page)? = response.body else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        guard page.roomID == roomID.rawValue, page.membershipRevision > 0,
              page.members.count <= pageSize,
              page.nextCursor.isEmpty || UUID(uuidString: page.nextCursor) != nil
        else { throw V2RealtimeTransportError.unexpectedResponse }
        let actorRole = try Self.membershipRole(from: page.actorRole)
        let members: [V2ClientRoomMember] = try page.members.map { member in
            let userID: UserID = try .init(member.userID)
            let publicIdentity: V2PublicIdentity?
            switch (member.publicHandle.isEmpty, member.displayName.isEmpty) {
            case (true, true): publicIdentity = nil
            case (false, false): publicIdentity = try .init(userID: userID, handle: .init(member.publicHandle), displayName: member.displayName)
            default: throw V2RealtimeTransportError.unexpectedResponse
            }
            return .init(userID: userID, role: try Self.membershipRole(from: member.role), publicIdentity: publicIdentity)
        }
        guard Set(members.map(\.userID)).count == members.count else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(page.roomID), membershipRevision: page.membershipRevision, actorRole: actorRole, members: members, nextCursor: page.nextCursor.isEmpty ? nil : page.nextCursor)
    }

    private static func membershipRole(from wireRole: IMV2RoomMembershipRole) throws -> V2RoomMembershipRole {
        switch wireRole {
        case .owner: return .owner
        case .admin: return .admin
        case .member: return .member
        case .unspecified, .UNRECOGNIZED: throw V2RealtimeTransportError.unexpectedResponse
        }
    }

    public func openDirectRoom(operationID: DirectRoomOperationID, targetUserID: UserID) async throws -> V2ClientDirectRoom {
        var request = IMV2Envelope(); request.openDirectRoom = .init()
        request.openDirectRoom.operationID = operationID.rawValue
        request.openDirectRoom.targetUserID = targetUserID.rawValue
        let response = try await requestEnvelope(request)
        guard case .directRoomOpened(let opened)? = response.body else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        guard opened.targetUserID == targetUserID.rawValue else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(opened.roomID), targetUserID: .init(opened.targetUserID), createdAt: Date(timeIntervalSince1970: TimeInterval(opened.createdAtMs) / 1_000))
    }

    public func beginGroupRoomCreation(operationID: GroupRoomOperationID, title: String) async throws -> V2ClientGroupAudienceDraft {
        var request = IMV2Envelope(); request.beginGroupRoomCreation = .init()
        request.beginGroupRoomCreation.operationID = operationID.rawValue
        request.beginGroupRoomCreation.title = title
        let response = try await requestEnvelope(request)
        guard case .groupRoomCreationPrepared(let prepared)? = response.body,
              prepared.operationID == operationID.rawValue,
              prepared.stagedMemberCount <= UInt32(V2GroupDeliveryPolicy.largeGroupHybridMaximumMembers - 1)
        else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        return try .init(operationID: .init(prepared.operationID), title: prepared.title, stagedMemberCount: Int(prepared.stagedMemberCount))
    }

    public func appendGroupRoomCreationMembers(operationID: GroupRoomOperationID, memberUserIDs: [UserID]) async throws -> V2ClientGroupAudienceDraft {
        guard !memberUserIDs.isEmpty, memberUserIDs.count <= V2GroupAudienceImportLimits.maximumMembersPerAppend else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
        var request = IMV2Envelope(); request.appendGroupRoomCreationMembers = .init()
        request.appendGroupRoomCreationMembers.operationID = operationID.rawValue
        request.appendGroupRoomCreationMembers.memberUserIds = memberUserIDs.map(\.rawValue)
        let response = try await requestEnvelope(request)
        guard case .groupRoomCreationMembersAppended(let appended)? = response.body,
              appended.operationID == operationID.rawValue,
              appended.stagedMemberCount <= UInt32(V2GroupDeliveryPolicy.largeGroupHybridMaximumMembers - 1)
        else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        return try .init(operationID: operationID, title: "staged", stagedMemberCount: Int(appended.stagedMemberCount))
    }

    public func finalizeGroupRoomCreation(operationID: GroupRoomOperationID) async throws -> V2ClientGroupRoom {
        var request = IMV2Envelope(); request.finalizeGroupRoomCreation = .init()
        request.finalizeGroupRoomCreation.operationID = operationID.rawValue
        let response = try await requestEnvelope(request)
        guard case .groupRoomCreated(let created)? = response.body else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        let returnedDeliveryMode: V2GroupDeliveryMode = switch created.deliveryMode {
        case .standardFanout: .standardFanout
        case .largeGroupHybrid: .largeGroupHybrid
        case .unspecified, .UNRECOGNIZED: throw V2RealtimeTransportError.unexpectedResponse
        }
        let members = try created.memberUserIds.map { try UserID($0) }
        guard !created.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              members.count == Set(members).count,
              created.memberCount > 0,
              members.isEmpty
        else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(created.roomID), title: created.title, deliveryMode: returnedDeliveryMode, memberUserIDs: members, memberCount: created.memberCount, createdAt: Date(timeIntervalSince1970: TimeInterval(created.createdAtMs) / 1_000))
    }

    public func cancelGroupRoomCreation(operationID: GroupRoomOperationID) async throws {
        var request = IMV2Envelope(); request.cancelGroupRoomCreation = .init()
        request.cancelGroupRoomCreation.operationID = operationID.rawValue
        let response = try await requestEnvelope(request)
        guard case .groupRoomCreationCancelled(let cancelled)? = response.body,
              cancelled.operationID == operationID.rawValue
        else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
    }

    public func pullGroupEvents(roomID: RoomID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2ClientGroupEventPage {
        guard pageSize > 0, pageSize <= V2GroupEventLogLimits.maximumPageSize else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
        var request = IMV2Envelope(); request.groupEventPull = .init()
        request.groupEventPull.roomID = roomID.rawValue
        request.groupEventPull.afterRoomSequence = afterRoomSequence
        request.groupEventPull.pageSize = UInt32(pageSize)
        let response = try await requestEnvelope(request)
        guard case .groupEventPage(let page)? = response.body,
              page.roomID == roomID.rawValue,
              page.events.count <= pageSize,
              page.nextRoomSequence >= afterRoomSequence
        else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        let events: [V2ClientGroupEvent] = try page.events.map {
            guard $0.roomSequence > afterRoomSequence,
                  !$0.projectionKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !$0.payload.isEmpty
            else { throw V2RealtimeTransportError.unexpectedResponse }
            return .init(sourceEventID: try .init($0.sourceEventID), roomSequence: $0.roomSequence, projectionKind: $0.projectionKind, payload: $0.payload)
        }
        guard zip(events, events.dropFirst()).allSatisfy({ $0.roomSequence < $1.roomSequence }),
              (events.last.map(\.roomSequence) ?? afterRoomSequence) == page.nextRoomSequence,
              !page.hasMore_p || !events.isEmpty
        else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(page.roomID), events: events, nextRoomSequence: page.nextRoomSequence, hasMore: page.hasMore_p)
    }

    public func subscribeToGroupEvents(roomID: RoomID, afterRoomSequence: UInt64) async throws -> V2ClientGroupEventSubscription {
        var request = IMV2Envelope()
        request.groupEventSubscribe = .init()
        request.groupEventSubscribe.roomID = roomID.rawValue
        request.groupEventSubscribe.afterRoomSequence = afterRoomSequence
        let response = try await requestEnvelope(request)
        guard case .groupEventSubscribed(let subscribed)? = response.body,
              subscribed.roomID == roomID.rawValue
        else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        return .init(roomID: roomID, highWatermark: subscribed.highWatermark)
    }

    public func unsubscribeFromGroupEvents(roomID: RoomID) async throws {
        var request = IMV2Envelope()
        request.groupEventUnsubscribe = .init()
        request.groupEventUnsubscribe.roomID = roomID.rawValue
        let response = try await requestEnvelope(request)
        guard case .acknowledged? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
    }

    public func setStrangerMessagePermission(operationID: StrangerMessagePreferenceOperationID, permission: V2StrangerMessagePermission) async throws -> Date {
        var request = IMV2Envelope(); request.setStrangerMessagePermission = .init()
        request.setStrangerMessagePermission.operationID = operationID.rawValue
        request.setStrangerMessagePermission.permission = permission == .allow ? .allow : .deny
        let response = try await requestEnvelope(request)
        guard case .strangerMessagePermissionSet(let result)? = response.body else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        let returned: V2StrangerMessagePermission
        switch result.permission { case .allow: returned = .allow; case .deny: returned = .deny; case .unspecified, .UNRECOGNIZED: throw V2RealtimeTransportError.unexpectedResponse }
        guard returned == permission else { throw V2RealtimeTransportError.unexpectedResponse }
        return Date(timeIntervalSince1970: TimeInterval(result.updatedAtMs) / 1_000)
    }

    public func changeRelationship(operationID: RelationshipOperationID, targetUserID: UserID, action: V2RelationshipAction) async throws -> V2ClientRelationshipChange {
        var request = IMV2Envelope(); request.changeRelationship = .init()
        request.changeRelationship.operationID = operationID.rawValue
        request.changeRelationship.targetUserID = targetUserID.rawValue
        request.changeRelationship.action = switch action { case .request: .request; case .accept: .accept; case .reject: .reject; case .remove: .remove }
        let response = try await requestEnvelope(request)
        guard case .relationshipChanged(let result)? = response.body else { try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse }
        let returnedAction: V2RelationshipAction
        switch result.action { case .request: returnedAction = .request; case .accept: returnedAction = .accept; case .reject: returnedAction = .reject; case .remove: returnedAction = .remove; case .unspecified, .UNRECOGNIZED: throw V2RealtimeTransportError.unexpectedResponse }
        let state: V2RelationshipState
        switch result.resultingState { case .none: state = .none; case .pending: state = .pending; case .accepted: state = .accepted; case .unspecified, .UNRECOGNIZED: throw V2RealtimeTransportError.unexpectedResponse }
        guard returnedAction == action else { throw V2RealtimeTransportError.unexpectedResponse }
        return .init(targetUserID: try .init(result.targetUserID), action: returnedAction, resultingState: state, updatedAt: Date(timeIntervalSince1970: TimeInterval(result.updatedAtMs) / 1_000))
    }

    public func changeUserBlock(operationID: UserBlockOperationID, targetUserID: UserID, action: V2UserBlockAction) async throws -> V2ClientUserBlockChange {
        var request = IMV2Envelope(); request.changeUserBlock = .init()
        request.changeUserBlock.operationID = operationID.rawValue
        request.changeUserBlock.targetUserID = targetUserID.rawValue
        request.changeUserBlock.action = action == .block ? .block : .unblock
        let response = try await requestEnvelope(request)
        guard case .userBlockChanged(let result)? = response.body else { try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse }
        let returnedAction: V2UserBlockAction
        switch result.action { case .block: returnedAction = .block; case .unblock: returnedAction = .unblock; case .unspecified, .UNRECOGNIZED: throw V2RealtimeTransportError.unexpectedResponse }
        guard returnedAction == action, result.targetUserID == targetUserID.rawValue, result.isBlocked == (action == .block) else { throw V2RealtimeTransportError.unexpectedResponse }
        return .init(targetUserID: targetUserID, action: returnedAction, isBlocked: result.isBlocked, updatedAt: Date(timeIntervalSince1970: TimeInterval(result.updatedAtMs) / 1_000))
    }

    public func withdrawMessage(roomID: RoomID, operationID: MessageWithdrawalOperationID, messageID: MessageID, expectedMessageRevision: UInt64) async throws -> V2ClientMessageWithdrawal {
        var request = IMV2Envelope()
        request.withdrawMessage = .init()
        request.withdrawMessage.roomID = roomID.rawValue
        request.withdrawMessage.operationID = operationID.rawValue
        request.withdrawMessage.messageID = messageID.rawValue
        request.withdrawMessage.expectedMessageRevision = expectedMessageRevision
        let response = try await requestEnvelope(request)
        guard case .messageWithdrawn(let withdrawn)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        guard withdrawn.roomID == roomID.rawValue, withdrawn.messageID == messageID.rawValue,
              withdrawn.messageRevision > expectedMessageRevision
        else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(withdrawn.roomID), messageID: .init(withdrawn.messageID), messageRevision: withdrawn.messageRevision, roomSequence: withdrawn.roomSequence, createdAt: Date(timeIntervalSince1970: TimeInterval(withdrawn.serverCreatedAtMs) / 1_000))
    }

    public func redactMessage(roomID: RoomID, operationID: ModerationOperationID, messageID: MessageID, reasonCode: V2ModerationReasonCode) async throws -> V2ClientMessageRedaction {
        var request = IMV2Envelope()
        request.moderateMessage = .init()
        request.moderateMessage.roomID = roomID.rawValue
        request.moderateMessage.operationID = operationID.rawValue
        request.moderateMessage.messageID = messageID.rawValue
        request.moderateMessage.reasonCode = reasonCode.rawValue
        let response = try await requestEnvelope(request)
        guard case .messageRedacted(let redacted)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        guard redacted.roomID == roomID.rawValue, redacted.messageID == messageID.rawValue,
              redacted.messageRevision > 1, redacted.roomSequence > 0
        else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(redacted.roomID), messageID: .init(redacted.messageID), messageRevision: redacted.messageRevision, roomSequence: redacted.roomSequence, createdAt: Date(timeIntervalSince1970: TimeInterval(redacted.serverCreatedAtMs) / 1_000))
    }

    public func muteMember(roomID: RoomID, operationID: ModerationOperationID, targetUserID: UserID, muteUntil: Date, reasonCode: V2ModerationReasonCode) async throws -> V2ClientMemberMute {
        let muteUntilMilliseconds = Int64(muteUntil.timeIntervalSince1970 * 1_000)
        guard muteUntilMilliseconds > 0 else { throw V2RealtimeTransportError.unexpectedResponse }
        var request = IMV2Envelope(); request.muteMember = .init()
        request.muteMember.roomID = roomID.rawValue
        request.muteMember.operationID = operationID.rawValue
        request.muteMember.targetUserID = targetUserID.rawValue
        request.muteMember.muteUntilMs = muteUntilMilliseconds
        request.muteMember.reasonCode = reasonCode.rawValue
        let response = try await requestEnvelope(request)
        guard case .memberMuted(let muted)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        guard muted.roomID == roomID.rawValue, muted.targetUserID == targetUserID.rawValue,
              muted.muteUntilMs == muteUntilMilliseconds, muted.roomSequence > 0,
              muted.serverCreatedAtMs >= 0
        else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(muted.roomID), targetUserID: .init(muted.targetUserID), muteUntil: Date(timeIntervalSince1970: TimeInterval(muted.muteUntilMs) / 1_000), roomSequence: muted.roomSequence, createdAt: Date(timeIntervalSince1970: TimeInterval(muted.serverCreatedAtMs) / 1_000))
    }

    public func removeMemberByModerator(roomID: RoomID, operationID: ModerationOperationID, targetUserID: UserID, reasonCode: V2ModerationReasonCode) async throws -> V2ClientModeratedMemberRemoval {
        var request = IMV2Envelope(); request.moderateMemberRemoval = .init()
        request.moderateMemberRemoval.roomID = roomID.rawValue
        request.moderateMemberRemoval.operationID = operationID.rawValue
        request.moderateMemberRemoval.targetUserID = targetUserID.rawValue
        request.moderateMemberRemoval.reasonCode = reasonCode.rawValue
        let response = try await requestEnvelope(request)
        guard case .memberRemovedByModerator(let removed)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        guard removed.roomID == roomID.rawValue, removed.targetUserID == targetUserID.rawValue,
              removed.membershipRevision > 0, removed.roomSequence > 0,
              removed.serverCreatedAtMs >= 0
        else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(removed.roomID), targetUserID: .init(removed.targetUserID), membershipRevision: removed.membershipRevision, roomSequence: removed.roomSequence, createdAt: Date(timeIntervalSince1970: TimeInterval(removed.serverCreatedAtMs) / 1_000))
    }

    public func editMessage(roomID: RoomID, operationID: MessageEditOperationID, messageID: MessageID, expectedMessageRevision: UInt64, text: String) async throws -> V2ClientMessageEdit {
        var request = IMV2Envelope()
        request.editMessage = .init()
        request.editMessage.roomID = roomID.rawValue
        request.editMessage.operationID = operationID.rawValue
        request.editMessage.messageID = messageID.rawValue
        request.editMessage.expectedMessageRevision = expectedMessageRevision
        request.editMessage.content = .init()
        request.editMessage.content.text = text
        let response = try await requestEnvelope(request)
        guard case .messageEdited(let edited)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        guard edited.roomID == roomID.rawValue, edited.messageID == messageID.rawValue,
              edited.text == text, edited.messageRevision > expectedMessageRevision,
              edited.roomSequence > 0
        else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(edited.roomID), messageID: .init(edited.messageID), text: edited.text, messageRevision: edited.messageRevision, roomSequence: edited.roomSequence, createdAt: Date(timeIntervalSince1970: TimeInterval(edited.serverCreatedAtMs) / 1_000))
    }

    public func recordReadReceipt(roomID: RoomID, operationID: ReadReceiptOperationID, readThroughRoomSequence: UInt64) async throws -> V2ClientReadReceipt {
        var request = IMV2Envelope(); request.recordReadReceipt = .init()
        request.recordReadReceipt.roomID = roomID.rawValue
        request.recordReadReceipt.operationID = operationID.rawValue
        request.recordReadReceipt.readThroughRoomSequence = readThroughRoomSequence
        let response = try await requestEnvelope(request)
        guard case .readReceiptRecorded(let recorded)? = response.body else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        guard recorded.roomID == roomID.rawValue, recorded.readThroughRoomSequence >= readThroughRoomSequence,
              recorded.readThroughRoomSequence > 0
        else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(recorded.roomID), userID: .init(recorded.userID), readThroughRoomSequence: recorded.readThroughRoomSequence, recordedAt: Date(timeIntervalSince1970: TimeInterval(recorded.recordedAtMs) / 1_000))
    }

    public func changeMessageReaction(roomID: RoomID, operationID: MessageReactionOperationID, messageID: MessageID, reaction: String, action: V2MessageReactionAction) async throws -> V2ClientMessageReactionChange {
        var request = IMV2Envelope(); request.changeMessageReaction = .init()
        request.changeMessageReaction.roomID = roomID.rawValue
        request.changeMessageReaction.operationID = operationID.rawValue
        request.changeMessageReaction.messageID = messageID.rawValue
        request.changeMessageReaction.reaction = reaction
        request.changeMessageReaction.action = action == .add ? .add : .remove
        let response = try await requestEnvelope(request)
        guard case .messageReactionChanged(let changed)? = response.body else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        let returnedAction: V2MessageReactionAction
        switch changed.action { case .add: returnedAction = .add; case .remove: returnedAction = .remove; case .unspecified, .UNRECOGNIZED: throw V2RealtimeTransportError.unexpectedResponse }
        guard changed.roomID == roomID.rawValue, changed.messageID == messageID.rawValue,
              changed.reaction == reaction, returnedAction == action, changed.roomSequence > 0
        else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(changed.roomID), messageID: .init(changed.messageID), actorUserID: .init(changed.actorUserID), reaction: changed.reaction, action: returnedAction, roomSequence: changed.roomSequence, createdAt: Date(timeIntervalSince1970: TimeInterval(changed.serverCreatedAtMs) / 1_000))
    }

    private func requestEnvelope(_ envelope: IMV2Envelope) async throws -> IMV2Envelope {
        var outbound = envelope
        let requestID = nextRequestID
        nextRequestID &+= 1
        if nextRequestID == 0 { nextRequestID = 1 }
        outbound.requestID = requestID
        outbound.protocolVersion = UInt32(protocolVersion)
        let response = try await wire.request(try V2ProtobufFrameCodec.encode(outbound, frameVersion: protocolVersion))
        let decoded = try V2ProtobufFrameCodec.decode(response)
        guard decoded.requestID == requestID else { throw V2RealtimeTransportError.unexpectedResponse }
        return decoded
    }

    private func throwServerErrorIfPresent(_ envelope: IMV2Envelope) throws {
        if case .error(let error)? = envelope.body {
            throw V2RealtimeTransportError.server(
                code: error.code,
                retryable: error.retryable,
                retryAfterSeconds: error.retryAfterSeconds,
                currentRevision: error.code == "REVISION_CONFLICT" ? error.currentRevision : nil
            )
        }
    }
}

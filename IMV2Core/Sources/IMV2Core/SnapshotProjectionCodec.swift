import Foundation

/// Canonical state carried by a V2 snapshot page. Snapshot pages contain
/// projections, not a replay of arbitrary live reads, so a client can replace
/// its local state atomically at the manifest base watermark.
public struct V2SnapshotMessageReaction: Equatable, Sendable, Comparable {
    public let actorUserID: UserID
    public let reaction: String

    public init(actorUserID: UserID, reaction: String) throws {
        guard !reaction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reaction.utf8.count <= 64
        else { throw V2SnapshotProjectionError.invalidPage }
        self.actorUserID = actorUserID
        self.reaction = reaction
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.reaction, lhs.actorUserID.rawValue) < (rhs.reaction, rhs.actorUserID.rawValue)
    }
}

public struct V2SnapshotMessageProjection: Equatable, Sendable {
    public let sourceEventID: EventID
    public let messageID: MessageID
    public let roomID: RoomID
    public let roomSequence: UInt64
    public let messageRevision: UInt64
    public let senderUserID: UserID
    public let text: String
    public let media: [V2MediaReference]
    public let mentions: [V2MentionTarget]
    public let createdAt: Date
    public let isWithdrawn: Bool
    public let reactions: [V2SnapshotMessageReaction]

    public init(sourceEventID: EventID, messageID: MessageID, roomID: RoomID, roomSequence: UInt64, messageRevision: UInt64 = 1, senderUserID: UserID, text: String, media: [V2MediaReference] = [], mentions: [V2MentionTarget] = [], createdAt: Date, isWithdrawn: Bool = false, reactions: [V2SnapshotMessageReaction] = []) throws {
        guard roomSequence > 0, messageRevision > 0, (!text.isEmpty || !media.isEmpty),
              media.count <= V2MessageCommandLimits.maxMediaAttachments,
              Set(media).count == media.count,
              mentions.count <= V2MessageCommandLimits.maxMentions,
              Set(mentions).count == mentions.count,
              !isWithdrawn || messageRevision > 1,
              Set(reactions.map { "\($0.actorUserID.rawValue):\($0.reaction)" }).count == reactions.count
        else { throw V2SnapshotProjectionError.invalidPage }
        self.sourceEventID = sourceEventID
        self.messageID = messageID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.messageRevision = messageRevision
        self.senderUserID = senderUserID
        self.text = text
        self.media = media
        self.mentions = mentions
        self.createdAt = createdAt
        self.isWithdrawn = isWithdrawn
        self.reactions = reactions.sorted()
    }
}

/// Social state is part of the reset baseline. A reset must never rebuild the
/// message timeline while retaining relationship/privacy values from an older
/// generation.
public struct V2SnapshotRelationshipProjection: Equatable, Sendable {
    public let targetUserID: UserID
    public let state: V2RelationshipState
    public let requestedByUserID: UserID?
    public let updatedAt: Date
    public init(targetUserID: UserID, state: V2RelationshipState, requestedByUserID: UserID?, updatedAt: Date) throws {
        guard (state == .pending) == (requestedByUserID != nil) else { throw V2SnapshotProjectionError.invalidPage }
        self.targetUserID = targetUserID; self.state = state; self.requestedByUserID = requestedByUserID; self.updatedAt = updatedAt
    }
}

public struct V2SnapshotUserBlockProjection: Equatable, Sendable {
    public let targetUserID: UserID
    public let isBlocked: Bool
    public let updatedAt: Date
    public init(targetUserID: UserID, isBlocked: Bool, updatedAt: Date) { self.targetUserID = targetUserID; self.isBlocked = isBlocked; self.updatedAt = updatedAt }
}

public struct V2SnapshotStrangerMessagePreference: Equatable, Sendable {
    public let allowsStrangerMessages: Bool
    public let updatedAt: Date
    public init(allowsStrangerMessages: Bool, updatedAt: Date) { self.allowsStrangerMessages = allowsStrangerMessages; self.updatedAt = updatedAt }
}

/// A moderation fact that remains visible after a reset. Audit reason text is
/// deliberately absent: snapshots carry only the client-visible event shape.
public struct V2SnapshotModerationProjection: Equatable, Sendable {
    public let sourceEventID: EventID
    public let roomID: RoomID
    public let roomSequence: UInt64
    public let actorUserID: UserID
    public let targetUserID: UserID
    public let muteUntil: Date
    public let createdAt: Date

    public init(sourceEventID: EventID, roomID: RoomID, roomSequence: UInt64, actorUserID: UserID, targetUserID: UserID, muteUntil: Date, createdAt: Date) throws {
        guard roomSequence > 0, muteUntil > createdAt, createdAt.timeIntervalSince1970 >= 0 else {
            throw V2SnapshotProjectionError.invalidPage
        }
        self.sourceEventID = sourceEventID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.actorUserID = actorUserID
        self.targetUserID = targetUserID
        self.muteUntil = muteUntil
        self.createdAt = createdAt
    }
}

/// The authoritative current room-control fact at a snapshot watermark. It
/// does not expose the protected safety-service reason code.
public struct V2SnapshotRoomControlProjection: Equatable, Sendable {
    public let sourceEventID: EventID
    public let roomID: RoomID
    public let roomSequence: UInt64
    public let actorUserID: UserID
    public let isFrozen: Bool
    public let createdAt: Date

    public init(sourceEventID: EventID, roomID: RoomID, roomSequence: UInt64, actorUserID: UserID, isFrozen: Bool, createdAt: Date) throws {
        guard roomSequence > 0, createdAt.timeIntervalSince1970 >= 0 else { throw V2SnapshotProjectionError.invalidPage }
        self.sourceEventID = sourceEventID; self.roomID = roomID; self.roomSequence = roomSequence
        self.actorUserID = actorUserID; self.isFrozen = isFrozen; self.createdAt = createdAt
    }
}

/// Group-room identity available to a member at the snapshot watermark. It is
/// sourced from the member's delivered history, never from a global room list.
public struct V2SnapshotRoomProfileProjection: Equatable, Sendable {
    public let sourceEventID: EventID
    public let roomID: RoomID
    public let title: String
    public let ownerUserID: UserID
    public let membershipRevision: UInt64
    public let createdAt: Date

    public init(sourceEventID: EventID, roomID: RoomID, title: String, ownerUserID: UserID, membershipRevision: UInt64, createdAt: Date) throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty,
              normalizedTitle.utf8.count <= V2CreateGroupRoomCommand.maximumTitleUTF8Bytes,
              !normalizedTitle.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              membershipRevision > 0,
              createdAt.timeIntervalSince1970 >= 0
        else { throw V2SnapshotProjectionError.invalidPage }
        self.sourceEventID = sourceEventID; self.roomID = roomID; self.title = normalizedTitle; self.ownerUserID = ownerUserID; self.membershipRevision = membershipRevision; self.createdAt = createdAt
    }
}

public struct V2SnapshotProjectionPage: Equatable, Sendable {
    public let messages: [V2SnapshotMessageProjection]
    public let relationships: [V2SnapshotRelationshipProjection]
    public let userBlocks: [V2SnapshotUserBlockProjection]
    public let strangerMessagePreference: V2SnapshotStrangerMessagePreference?
    public let moderationActions: [V2SnapshotModerationProjection]
    public let roomControls: [V2SnapshotRoomControlProjection]
    public let roomProfiles: [V2SnapshotRoomProfileProjection]
    /// Compatibility overload retained for incremental build products compiled
    /// against snapshot schema v7. New callers may provide room controls.
    public init(messages: [V2SnapshotMessageProjection], relationships: [V2SnapshotRelationshipProjection] = [], userBlocks: [V2SnapshotUserBlockProjection] = [], strangerMessagePreference: V2SnapshotStrangerMessagePreference? = nil, moderationActions: [V2SnapshotModerationProjection] = []) throws {
        try self.init(messages: messages, relationships: relationships, userBlocks: userBlocks, strangerMessagePreference: strangerMessagePreference, moderationActions: moderationActions, roomControls: [], roomProfiles: [])
    }

    public init(messages: [V2SnapshotMessageProjection], relationships: [V2SnapshotRelationshipProjection], userBlocks: [V2SnapshotUserBlockProjection], strangerMessagePreference: V2SnapshotStrangerMessagePreference?, moderationActions: [V2SnapshotModerationProjection], roomControls: [V2SnapshotRoomControlProjection], roomProfiles: [V2SnapshotRoomProfileProjection] = []) throws {
        guard Set(relationships.map(\.targetUserID)).count == relationships.count,
              Set(userBlocks.map(\.targetUserID)).count == userBlocks.count,
              Set(moderationActions.map(\.sourceEventID)).count == moderationActions.count,
              Set(roomControls.map(\.roomID)).count == roomControls.count,
              Set(roomProfiles.map(\.roomID)).count == roomProfiles.count
        else { throw V2SnapshotProjectionError.invalidPage }
        self.messages = messages; self.relationships = relationships; self.userBlocks = userBlocks; self.strangerMessagePreference = strangerMessagePreference; self.moderationActions = moderationActions; self.roomControls = roomControls; self.roomProfiles = roomProfiles
    }
}

/// Shared deterministic JSON codec for snapshot pages. The source service
/// calculates page digests from these emitted bytes; clients validate their
/// supplied digest before decoding and atomically applying the projections.
public enum V2SnapshotProjectionCodec {
    /// V2 snapshot schema. There is deliberately no reader for the earlier
    /// draft page shape: this product has no released data to migrate.
    public static let schemaVersion: UInt32 = 10

    public static func encode(messages: [V2SnapshotMessageProjection]) throws -> Data {
        try encode(.init(messages: messages))
    }

    public static func encode(_ page: V2SnapshotProjectionPage) throws -> Data {
        let wire = Page(schemaVersion: schemaVersion, messages: page.messages.map(Message.init), relationships: page.relationships.map(Relationship.init), userBlocks: page.userBlocks.map(UserBlock.init), strangerMessagePreference: page.strangerMessagePreference.map(StrangerMessagePreference.init), moderationActions: page.moderationActions.map(Moderation.init), roomControls: page.roomControls.map(RoomControl.init), roomProfiles: page.roomProfiles.map(RoomProfile.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(wire)
    }

    public static func decode(_ payload: Data) throws -> [V2SnapshotMessageProjection] {
        try decodePage(payload).messages
    }

    public static func decodePage(_ payload: Data) throws -> V2SnapshotProjectionPage {
        let page: Page
        do { page = try JSONDecoder().decode(Page.self, from: payload) }
        catch { throw V2SnapshotProjectionError.invalidPage }
        guard page.schemaVersion == schemaVersion else { throw V2SnapshotProjectionError.unsupportedSchemaVersion }
        do { return try .init(messages: page.messages.map { try $0.projection() }, relationships: page.relationships.map { try $0.projection() }, userBlocks: page.userBlocks.map { try $0.projection() }, strangerMessagePreference: try page.strangerMessagePreference?.projection(), moderationActions: page.moderationActions.map { try $0.projection() }, roomControls: page.roomControls.map { try $0.projection() }, roomProfiles: page.roomProfiles.map { try $0.projection() }) }
        catch let error as V2SnapshotProjectionError { throw error }
        catch { throw V2SnapshotProjectionError.invalidPage }
    }

    private struct Page: Codable {
        let schemaVersion: UInt32
        let messages: [Message]
        let relationships: [Relationship]
        let userBlocks: [UserBlock]
        let strangerMessagePreference: StrangerMessagePreference?
        let moderationActions: [Moderation]
        let roomControls: [RoomControl]
        let roomProfiles: [RoomProfile]
        enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version"; case messages; case relationships; case userBlocks = "user_blocks"; case strangerMessagePreference = "stranger_message_preference"; case moderationActions = "moderation_actions"; case roomControls = "room_controls"; case roomProfiles = "room_profiles" }
    }

    private struct Message: Codable {
        let sourceEventID: String
        let messageID: String
        let roomID: String
        let roomSequence: UInt64
        let messageRevision: UInt64
        let senderUserID: String
        let text: String
        let mediaIDs: [String]
        let mentionedUserIDs: [String]
        let mentionsEveryone: Bool
        let serverCreatedAtMilliseconds: Int64
        let isWithdrawn: Bool
        let reactions: [Reaction]

        init(_ projection: V2SnapshotMessageProjection) {
            sourceEventID = projection.sourceEventID.rawValue
            messageID = projection.messageID.rawValue
            roomID = projection.roomID.rawValue
            roomSequence = projection.roomSequence
            messageRevision = projection.messageRevision
            senderUserID = projection.senderUserID.rawValue
            text = projection.text
            mediaIDs = projection.media.map { $0.mediaID.rawValue }
            mentionedUserIDs = projection.mentions.compactMap {
                guard case .user(let userID) = $0 else { return nil }
                return userID.rawValue
            }
            mentionsEveryone = projection.mentions.contains(.everyone)
            serverCreatedAtMilliseconds = Int64(projection.createdAt.timeIntervalSince1970 * 1_000)
            isWithdrawn = projection.isWithdrawn
            reactions = projection.reactions.map(Reaction.init)
        }

        func projection() throws -> V2SnapshotMessageProjection {
            guard serverCreatedAtMilliseconds >= 0 else { throw V2SnapshotProjectionError.invalidPage }
            let mentions = try mentionedUserIDs.map { try V2MentionTarget.user(.init($0)) }
                + (mentionsEveryone ? [.everyone] : [])
            return try .init(sourceEventID: .init(sourceEventID), messageID: .init(messageID), roomID: .init(roomID), roomSequence: roomSequence, messageRevision: messageRevision, senderUserID: .init(senderUserID), text: text, media: try mediaIDs.map { try .init(mediaID: .init($0)) }, mentions: mentions, createdAt: Date(timeIntervalSince1970: TimeInterval(serverCreatedAtMilliseconds) / 1_000), isWithdrawn: isWithdrawn, reactions: try reactions.map { try $0.projection() })
        }

        enum CodingKeys: String, CodingKey {
            case sourceEventID = "source_event_id"
            case messageID = "message_id"
            case roomID = "room_id"
            case roomSequence = "room_sequence"
            case messageRevision = "message_revision"
            case senderUserID = "sender_user_id"
            case text
            case mediaIDs = "media_ids"
            case mentionedUserIDs = "mentioned_user_ids"
            case mentionsEveryone = "mentions_everyone"
            case serverCreatedAtMilliseconds = "server_created_at_ms"
            case isWithdrawn = "is_withdrawn"
            case reactions
        }

        struct Reaction: Codable {
            let actorUserID: String
            let reaction: String
            init(_ value: V2SnapshotMessageReaction) { actorUserID = value.actorUserID.rawValue; reaction = value.reaction }
            func projection() throws -> V2SnapshotMessageReaction { try .init(actorUserID: .init(actorUserID), reaction: reaction) }
            enum CodingKeys: String, CodingKey { case actorUserID = "actor_user_id"; case reaction }
        }
    }

    private struct Relationship: Codable {
        let targetUserID: String; let state: String; let requestedByUserID: String?; let updatedAtMilliseconds: Int64
        init(_ value: V2SnapshotRelationshipProjection) { targetUserID = value.targetUserID.rawValue; state = value.state.rawValue; requestedByUserID = value.requestedByUserID?.rawValue; updatedAtMilliseconds = Int64(value.updatedAt.timeIntervalSince1970 * 1_000) }
        func projection() throws -> V2SnapshotRelationshipProjection { guard updatedAtMilliseconds >= 0, let state = V2RelationshipState(rawValue: state) else { throw V2SnapshotProjectionError.invalidPage }; return try .init(targetUserID: .init(targetUserID), state: state, requestedByUserID: try requestedByUserID.map(UserID.init), updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAtMilliseconds) / 1_000)) }
        enum CodingKeys: String, CodingKey { case targetUserID = "target_user_id"; case state; case requestedByUserID = "requested_by_user_id"; case updatedAtMilliseconds = "updated_at_ms" }
    }

    private struct UserBlock: Codable {
        let targetUserID: String; let isBlocked: Bool; let updatedAtMilliseconds: Int64
        init(_ value: V2SnapshotUserBlockProjection) { targetUserID = value.targetUserID.rawValue; isBlocked = value.isBlocked; updatedAtMilliseconds = Int64(value.updatedAt.timeIntervalSince1970 * 1_000) }
        func projection() throws -> V2SnapshotUserBlockProjection { guard updatedAtMilliseconds >= 0 else { throw V2SnapshotProjectionError.invalidPage }; return try .init(targetUserID: .init(targetUserID), isBlocked: isBlocked, updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAtMilliseconds) / 1_000)) }
        enum CodingKeys: String, CodingKey { case targetUserID = "target_user_id"; case isBlocked = "is_blocked"; case updatedAtMilliseconds = "updated_at_ms" }
    }

    private struct StrangerMessagePreference: Codable {
        let allowsStrangerMessages: Bool; let updatedAtMilliseconds: Int64
        init(_ value: V2SnapshotStrangerMessagePreference) { allowsStrangerMessages = value.allowsStrangerMessages; updatedAtMilliseconds = Int64(value.updatedAt.timeIntervalSince1970 * 1_000) }
        func projection() throws -> V2SnapshotStrangerMessagePreference { guard updatedAtMilliseconds >= 0 else { throw V2SnapshotProjectionError.invalidPage }; return .init(allowsStrangerMessages: allowsStrangerMessages, updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAtMilliseconds) / 1_000)) }
        enum CodingKeys: String, CodingKey { case allowsStrangerMessages = "allows_stranger_messages"; case updatedAtMilliseconds = "updated_at_ms" }
    }

    private struct Moderation: Codable {
        let sourceEventID: String
        let roomID: String
        let roomSequence: UInt64
        let actorUserID: String
        let targetUserID: String
        let muteUntilMilliseconds: Int64
        let serverCreatedAtMilliseconds: Int64

        init(_ value: V2SnapshotModerationProjection) {
            sourceEventID = value.sourceEventID.rawValue
            roomID = value.roomID.rawValue
            roomSequence = value.roomSequence
            actorUserID = value.actorUserID.rawValue
            targetUserID = value.targetUserID.rawValue
            muteUntilMilliseconds = Int64(value.muteUntil.timeIntervalSince1970 * 1_000)
            serverCreatedAtMilliseconds = Int64(value.createdAt.timeIntervalSince1970 * 1_000)
        }

        func projection() throws -> V2SnapshotModerationProjection {
            guard muteUntilMilliseconds > serverCreatedAtMilliseconds, serverCreatedAtMilliseconds >= 0 else {
                throw V2SnapshotProjectionError.invalidPage
            }
            return try .init(sourceEventID: .init(sourceEventID), roomID: .init(roomID), roomSequence: roomSequence, actorUserID: .init(actorUserID), targetUserID: .init(targetUserID), muteUntil: Date(timeIntervalSince1970: TimeInterval(muteUntilMilliseconds) / 1_000), createdAt: Date(timeIntervalSince1970: TimeInterval(serverCreatedAtMilliseconds) / 1_000))
        }

        enum CodingKeys: String, CodingKey {
            case sourceEventID = "source_event_id"
            case roomID = "room_id"
            case roomSequence = "room_sequence"
            case actorUserID = "actor_user_id"
            case targetUserID = "target_user_id"
            case muteUntilMilliseconds = "mute_until_ms"
            case serverCreatedAtMilliseconds = "server_created_at_ms"
        }
    }

    private struct RoomControl: Codable {
        let sourceEventID: String; let roomID: String; let roomSequence: UInt64; let actorUserID: String; let isFrozen: Bool; let serverCreatedAtMilliseconds: Int64
        init(_ value: V2SnapshotRoomControlProjection) { sourceEventID = value.sourceEventID.rawValue; roomID = value.roomID.rawValue; roomSequence = value.roomSequence; actorUserID = value.actorUserID.rawValue; isFrozen = value.isFrozen; serverCreatedAtMilliseconds = Int64(value.createdAt.timeIntervalSince1970 * 1_000) }
        func projection() throws -> V2SnapshotRoomControlProjection { guard serverCreatedAtMilliseconds >= 0 else { throw V2SnapshotProjectionError.invalidPage }; return try .init(sourceEventID: .init(sourceEventID), roomID: .init(roomID), roomSequence: roomSequence, actorUserID: .init(actorUserID), isFrozen: isFrozen, createdAt: Date(timeIntervalSince1970: TimeInterval(serverCreatedAtMilliseconds) / 1_000)) }
        enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id"; case roomID = "room_id"; case roomSequence = "room_sequence"; case actorUserID = "actor_user_id"; case isFrozen = "is_frozen"; case serverCreatedAtMilliseconds = "server_created_at_ms" }
    }

    private struct RoomProfile: Codable {
        let sourceEventID: String; let roomID: String; let title: String; let ownerUserID: String; let membershipRevision: UInt64; let createdAtMilliseconds: Int64
        init(_ value: V2SnapshotRoomProfileProjection) { sourceEventID = value.sourceEventID.rawValue; roomID = value.roomID.rawValue; title = value.title; ownerUserID = value.ownerUserID.rawValue; membershipRevision = value.membershipRevision; createdAtMilliseconds = Int64(value.createdAt.timeIntervalSince1970 * 1_000) }
        func projection() throws -> V2SnapshotRoomProfileProjection { guard createdAtMilliseconds >= 0 else { throw V2SnapshotProjectionError.invalidPage }; return try .init(sourceEventID: .init(sourceEventID), roomID: .init(roomID), title: title, ownerUserID: .init(ownerUserID), membershipRevision: membershipRevision, createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtMilliseconds) / 1_000)) }
        enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id"; case roomID = "room_id"; case title; case ownerUserID = "owner_user_id"; case membershipRevision = "membership_revision"; case createdAtMilliseconds = "created_at_ms" }
    }
}

public enum V2SnapshotProjectionError: Error, Equatable, Sendable {
    case invalidPage
    case unsupportedSchemaVersion
}

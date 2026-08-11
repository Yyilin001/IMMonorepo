import Crypto
import Fluent
import Foundation
import IMV2Core
import SQLKit

/// A complete client-visible projection baseline reconstructed at one
/// repeatable-read PostgreSQL snapshot. Message state is replayed from this
/// user's *delivered* sync log, never inferred from current membership or the
/// mutable messages table. That preserves the visibility boundary for a user
/// who left a room before a later edit, reaction, or withdrawal.
public struct V2AuthoritativeSnapshotProjection: Equatable, Sendable {
    public let baseSequence: UInt64
    public let pages: [V2SnapshotPageStage]

    public init(baseSequence: UInt64, pages: [V2SnapshotPageStage]) {
        self.baseSequence = baseSequence
        self.pages = pages
    }
}

public struct PostgresV2SnapshotProjectionMaterializer: Sendable {
    private let database: any Database
    private let pageItemLimit: Int
    private let schema: String

    public init(database: any Database, pageItemLimit: Int = 500, schema: String = "im_v2") {
        precondition(pageItemLimit > 0)
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database
        self.pageItemLimit = pageItemLimit
        self.schema = schema
    }

    public func materialize(userID: UserID, now: Date) async throws -> V2AuthoritativeSnapshotProjection {
        let userUUID = try snapshotProjectionUUID(userID)
        let source = try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2SnapshotProjectionMaterializerError.corruptPersistenceState }
            try await sql.raw("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY").run()
            let watermark = try await sql.raw("""
                SELECT COALESCE((SELECT next_sequence FROM \(unsafeRaw: table("user_sync_sequences"))
                                 WHERE user_id = \(bind: userUUID)), 0) AS value
                """).first(decoding: SnapshotProjectionWatermarkRow.self)?.value ?? 0
            let log = try await sql.raw("""
                SELECT log.user_sync_sequence, log.source_event_id, log.projection_kind,
                       CASE WHEN log.payload_storage = 'inline' THEN log.payload ELSE shared.payload END::text AS payload_json
                FROM \(unsafeRaw: table("user_sync_log")) AS log
                LEFT JOIN \(unsafeRaw: table("fanout_sync_payloads")) AS shared
                  ON shared.source_event_id = log.source_event_id
                 AND shared.projection_kind = log.projection_kind
                WHERE log.user_id = \(bind: userUUID)
                ORDER BY log.user_sync_sequence
                """).all(decoding: SnapshotProjectionSyncLogRow.self)
            let relationships = try await sql.raw("""
                SELECT CASE WHEN lower_user_id = \(bind: userUUID) THEN higher_user_id ELSE lower_user_id END AS target_user_id,
                       state,
                       CASE WHEN state = 'pending' THEN requested_by_user_id ELSE NULL END AS requested_by_user_id,
                       updated_at
                FROM \(unsafeRaw: table("user_relationships"))
                WHERE lower_user_id = \(bind: userUUID) OR higher_user_id = \(bind: userUUID)
                ORDER BY target_user_id
                """).all(decoding: SnapshotProjectionRelationshipRow.self)
            let blocks = try await sql.raw("""
                SELECT blocked_user_id AS target_user_id, created_at AS updated_at
                FROM \(unsafeRaw: table("user_blocks"))
                WHERE blocker_user_id = \(bind: userUUID)
                ORDER BY blocked_user_id
                """).all(decoding: SnapshotProjectionBlockRow.self)
            let preference = try await sql.raw("""
                SELECT allows_stranger_messages, updated_at
                FROM \(unsafeRaw: table("user_stranger_message_preferences"))
                WHERE user_id = \(bind: userUUID)
                """).first(decoding: SnapshotProjectionPreferenceRow.self)
            let userAddPreference = try await sql.raw("""
                SELECT allows_being_added, updated_at
                FROM \(unsafeRaw: table("user_add_preferences"))
                WHERE user_id = \(bind: userUUID)
                """).first(decoding: SnapshotProjectionUserAddPreferenceRow.self)
            let readReceiptPreference = try await sql.raw("SELECT allows_direct_read_receipts, allows_group_read_receipts, updated_at FROM \(unsafeRaw: table("user_read_receipt_preferences")) WHERE user_id = \(bind: userUUID)").first(decoding: SnapshotProjectionReadReceiptPreferenceRow.self)
            // Direct rooms have exactly one counterpart. Their public profile
            // is therefore constant-size per active room and may be rebuilt
            // from authority during a reset; group rosters deliberately do
            // not take this path.
            let directRoomProfiles = try await sql.raw("""
                SELECT pair.room_id,
                       CASE WHEN pair.lower_user_id = \(bind: userUUID)
                            THEN pair.higher_user_id ELSE pair.lower_user_id END AS target_user_id,
                       profile.public_handle, profile.display_name, profile.account_kind,
                       profile.revision, profile.updated_at
                FROM \(unsafeRaw: table("direct_room_pairs")) AS pair
                INNER JOIN \(unsafeRaw: table("rooms")) AS room
                    ON room.room_id = pair.room_id AND room.room_kind = 'direct'
                INNER JOIN \(unsafeRaw: table("room_memberships")) AS actor_membership
                    ON actor_membership.room_id = pair.room_id
                   AND actor_membership.user_id = \(bind: userUUID)
                   AND actor_membership.joined_revision <= room.membership_revision
                   AND (actor_membership.left_revision IS NULL OR actor_membership.left_revision > room.membership_revision)
                INNER JOIN \(unsafeRaw: table("public_user_profiles")) AS profile
                    ON profile.user_id = CASE WHEN pair.lower_user_id = \(bind: userUUID)
                                              THEN pair.higher_user_id ELSE pair.lower_user_id END
                WHERE pair.lower_user_id = \(bind: userUUID) OR pair.higher_user_id = \(bind: userUUID)
                  AND EXISTS (SELECT 1 FROM \(unsafeRaw: table("messages")) WHERE room_id = pair.room_id)
                ORDER BY pair.room_id
                """).all(decoding: SnapshotProjectionDirectRoomProfileRow.self)
            let directReadReceipts = try await sql.raw("""
                SELECT pair.room_id, receipt.user_id AS reader_user_id,
                       receipt.read_through_room_sequence, receipt.updated_at
                FROM \(unsafeRaw: table("direct_room_pairs")) AS pair
                INNER JOIN \(unsafeRaw: table("room_read_receipts")) AS receipt ON receipt.room_id = pair.room_id
                LEFT JOIN \(unsafeRaw: table("user_read_receipt_preferences")) AS reader_preference
                    ON reader_preference.user_id = receipt.user_id
                LEFT JOIN \(unsafeRaw: table("user_read_receipt_preferences")) AS viewer_preference
                    ON viewer_preference.user_id = \(bind: userUUID)
                WHERE (pair.lower_user_id = \(bind: userUUID) OR pair.higher_user_id = \(bind: userUUID))
                  AND receipt.user_id <> \(bind: userUUID)
                  AND COALESCE(reader_preference.allows_direct_read_receipts, TRUE)
                  AND COALESCE(viewer_preference.allows_direct_read_receipts, TRUE)
                ORDER BY pair.room_id
                """).all(decoding: SnapshotProjectionDirectReadReceiptRow.self)
            let conversationStates = try await sql.raw("SELECT room_id, pinned_at IS NOT NULL AS is_pinned, archived_at IS NOT NULL AS is_archived, mute_until, updated_at FROM \(unsafeRaw: table("user_room_preferences")) WHERE user_id = \(bind: userUUID) ORDER BY room_id").all(decoding: SnapshotProjectionConversationStateRow.self)
            let messageFavorites = try await sql.raw("SELECT room_id, message_id, TRUE AS is_favorited, created_at AS updated_at FROM \(unsafeRaw: table("user_message_favorites")) WHERE user_id = \(bind: userUUID) ORDER BY message_id").all(decoding: SnapshotProjectionMessageFavoriteRow.self)
            return (watermark, log, relationships, blocks, preference, userAddPreference, readReceiptPreference, directRoomProfiles, directReadReceipts, conversationStates, messageFavorites)
        }
        guard source.0 >= 0 else { throw V2SnapshotProjectionMaterializerError.corruptPersistenceState }
        let replay = try replayDeliveredHistory(source.1)
        let relationships = try source.2.map { row -> V2SnapshotRelationshipProjection in
            guard let state = V2RelationshipState(rawValue: row.state) else { throw V2SnapshotProjectionMaterializerError.corruptPersistenceState }
            return try .init(targetUserID: .init(row.targetUserID.uuidString), state: state, requestedByUserID: try row.requestedByUserID.map { try .init($0.uuidString) }, updatedAt: row.updatedAt)
        }
        let blocks = try source.3.map { row in
            V2SnapshotUserBlockProjection(targetUserID: try .init(row.targetUserID.uuidString), isBlocked: true, updatedAt: row.updatedAt)
        }
        let preference = V2SnapshotStrangerMessagePreference(
            allowsStrangerMessages: source.4?.allowsStrangerMessages ?? true,
            updatedAt: source.4?.updatedAt ?? now
        )
        let userAddPreference = V2SnapshotUserAddPreference(
            allowsBeingAdded: source.5?.allowsBeingAdded ?? true,
            updatedAt: source.5?.updatedAt ?? now
        )
        let readReceiptPreference = V2SnapshotReadReceiptPreference(allowsDirectReadReceipts: source.6?.allowsDirectReadReceipts ?? true, allowsGroupReadReceipts: source.6?.allowsGroupReadReceipts ?? true, updatedAt: source.6?.updatedAt ?? now)
        let directRoomProfiles = try source.7.map { row -> V2SnapshotDirectRoomProfileProjection in
            let publicIdentity = try V2PublicIdentity(
                userID: .init(row.targetUserID.uuidString),
                handle: .init(row.publicHandle),
                displayName: row.displayName,
                accountKind: try snapshotAccountKind(row.accountKind)
            )
            guard row.revision > 0 else { throw V2SnapshotProjectionMaterializerError.corruptPersistenceState }
            return try .init(
                sourceEventID: .init(row.roomID.uuidString),
                roomID: .init(row.roomID.uuidString),
                publicIdentity: publicIdentity,
                revision: UInt64(row.revision),
                updatedAt: row.updatedAt
            )
        }
        let directReadReceipts = try source.8.map { row -> V2SnapshotDirectReadReceiptProjection in
            try .init(roomID: .init(row.roomID.uuidString), readerUserID: .init(row.readerUserID.uuidString), readThroughRoomSequence: snapshotProjectionUnsigned(row.readThroughRoomSequence), recordedAt: row.updatedAt)
        }
        let conversationStates = try source.9.map { row in try V2SnapshotConversationState(roomID: .init(row.roomID.uuidString), isPinned: row.isPinned, isArchived: row.isArchived, muteUntil: row.muteUntil, updatedAt: row.updatedAt) }
        let messageFavorites = try source.10.map { row in try V2SnapshotMessageFavorite(roomID: .init(row.roomID.uuidString), messageID: .init(row.messageID.uuidString), isFavorited: row.isFavorited, updatedAt: row.updatedAt) }
        let payloads = try makePages(
            messages: replay.messages,
            relationships: relationships,
            blocks: blocks,
            moderationActions: replay.moderationActions,
            roomControls: replay.roomControls,
            roomProfiles: replay.roomProfiles,
            directRoomProfiles: directRoomProfiles,
            preference: preference,
            userAddPreference: userAddPreference,
            readReceiptPreference: readReceiptPreference,
            directReadReceipts: directReadReceipts,
            conversationStates: conversationStates,
            messageFavorites: messageFavorites,
            timelineActivities: replay.timelineActivities,
            directSendingCapabilities: replay.directSendingCapabilities
        )
        return .init(baseSequence: UInt64(source.0), pages: payloads.map { .init(digest: snapshotProjectionSHA256($0), payload: $0) })
    }

    private func table(_ name: String) -> String { "\(schema).\(name)" }

    private func makePages(
        messages: [V2SnapshotMessageProjection],
        relationships: [V2SnapshotRelationshipProjection],
        blocks: [V2SnapshotUserBlockProjection],
        moderationActions: [V2SnapshotModerationProjection],
        roomControls: [V2SnapshotRoomControlProjection],
        roomProfiles: [V2SnapshotRoomProfileProjection],
        directRoomProfiles: [V2SnapshotDirectRoomProfileProjection],
        preference: V2SnapshotStrangerMessagePreference,
        userAddPreference: V2SnapshotUserAddPreference,
        readReceiptPreference: V2SnapshotReadReceiptPreference,
        directReadReceipts: [V2SnapshotDirectReadReceiptProjection],
        conversationStates: [V2SnapshotConversationState],
        messageFavorites: [V2SnapshotMessageFavorite],
        timelineActivities: [V2SnapshotTimelineActivity],
        directSendingCapabilities: [V2SnapshotDirectSendingCapability]
    ) throws -> [Data] {
        let items = messages.sorted { ($0.roomID.rawValue, $0.roomSequence) < ($1.roomID.rawValue, $1.roomSequence) }.map(SnapshotProjectionItem.message)
            + relationships.map(SnapshotProjectionItem.relationship)
            + blocks.map(SnapshotProjectionItem.block)
            + moderationActions.sorted { ($0.roomID.rawValue, $0.roomSequence) < ($1.roomID.rawValue, $1.roomSequence) }.map(SnapshotProjectionItem.moderation)
            + roomControls.sorted { ($0.roomID.rawValue, $0.roomSequence) < ($1.roomID.rawValue, $1.roomSequence) }.map(SnapshotProjectionItem.roomControl)
            + roomProfiles.sorted { $0.roomID.rawValue < $1.roomID.rawValue }.map(SnapshotProjectionItem.roomProfile)
            + directRoomProfiles.sorted { $0.roomID.rawValue < $1.roomID.rawValue }.map(SnapshotProjectionItem.directRoomProfile)
            + directReadReceipts.sorted { $0.roomID.rawValue < $1.roomID.rawValue }.map(SnapshotProjectionItem.directReadReceipt)
            + conversationStates.sorted { $0.roomID.rawValue < $1.roomID.rawValue }.map(SnapshotProjectionItem.conversationState)
            + messageFavorites.sorted { $0.messageID.rawValue < $1.messageID.rawValue }.map(SnapshotProjectionItem.messageFavorite)
            + timelineActivities.sorted { ($0.roomID.rawValue, $0.timelineSequence) < ($1.roomID.rawValue, $1.timelineSequence) }.map(SnapshotProjectionItem.timelineActivity)
            + directSendingCapabilities.sorted { $0.roomID.rawValue < $1.roomID.rawValue }.map(SnapshotProjectionItem.directSendingCapability)
        var offset = 0
        var pages: [Data] = []
        repeat {
            let end = min(items.count, offset + pageItemLimit)
            let slice = items[offset..<end]
            var pageMessages: [V2SnapshotMessageProjection] = []
            var pageRelationships: [V2SnapshotRelationshipProjection] = []
            var pageBlocks: [V2SnapshotUserBlockProjection] = []
            var pageModeration: [V2SnapshotModerationProjection] = []
            var pageControls: [V2SnapshotRoomControlProjection] = []
            var pageProfiles: [V2SnapshotRoomProfileProjection] = []
            var pageDirectProfiles: [V2SnapshotDirectRoomProfileProjection] = []
            var pageDirectReadReceipts: [V2SnapshotDirectReadReceiptProjection] = []
            var pageConversationStates: [V2SnapshotConversationState] = []
            var pageMessageFavorites: [V2SnapshotMessageFavorite] = []
            var pageTimelineActivities: [V2SnapshotTimelineActivity] = []
            var pageDirectSendingCapabilities: [V2SnapshotDirectSendingCapability] = []
            for item in slice {
                switch item {
                case .message(let value): pageMessages.append(value)
                case .relationship(let value): pageRelationships.append(value)
                case .block(let value): pageBlocks.append(value)
                case .moderation(let value): pageModeration.append(value)
                case .roomControl(let value): pageControls.append(value)
                case .roomProfile(let value): pageProfiles.append(value)
                case .directRoomProfile(let value): pageDirectProfiles.append(value)
                case .directReadReceipt(let value): pageDirectReadReceipts.append(value)
                case .conversationState(let value): pageConversationStates.append(value)
                case .messageFavorite(let value): pageMessageFavorites.append(value)
                case .timelineActivity(let value): pageTimelineActivities.append(value)
                case .directSendingCapability(let value): pageDirectSendingCapabilities.append(value)
                }
            }
            pages.append(try V2SnapshotProjectionCodec.encode(.init(
                messages: pageMessages,
                relationships: pageRelationships,
                userBlocks: pageBlocks,
                strangerMessagePreference: pages.isEmpty ? preference : nil,
                moderationActions: pageModeration,
                roomControls: pageControls,
                roomProfiles: pageProfiles,
                directRoomProfiles: pageDirectProfiles,
                userAddPreference: pages.isEmpty ? userAddPreference : nil,
                readReceiptPreference: pages.isEmpty ? readReceiptPreference : nil,
                directReadReceipts: pageDirectReadReceipts,
                conversationStates: pageConversationStates,
                messageFavorites: pageMessageFavorites,
                timelineActivities: pageTimelineActivities,
                directSendingCapabilities: pageDirectSendingCapabilities
            )))
            offset = end
        } while offset < items.count
        return pages
    }
}

/// Internal reset orchestration. It turns a complete projection baseline into
/// the existing device-bound staged snapshot protocol; no gateway caller can
/// submit pages or choose a watermark. Records committed after the materializer
/// transaction's base sequence are deliberately replayed through normal sync
/// after the snapshot ACK.
public struct V2ServerSnapshotResetStager: Sendable {
    private let materializer: PostgresV2SnapshotProjectionMaterializer
    private let sync: V2SyncService
    private let makeUUID: @Sendable () -> UUID
    private let capabilityLifetime: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        materializer: PostgresV2SnapshotProjectionMaterializer,
        sync: V2SyncService,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        capabilityLifetime: TimeInterval = 86_400,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(capabilityLifetime > 0)
        self.materializer = materializer
        self.sync = sync
        self.makeUUID = makeUUID
        self.capabilityLifetime = capabilityLifetime
        self.now = now
    }

    public func stageReset(
        userID: UserID,
        deviceID: DeviceID,
        capabilityProfile: String,
        snapshotID: SnapshotID? = nil
    ) async throws -> UInt64 {
        guard !capabilityProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw V2SnapshotProjectionMaterializerError.invalidCapabilityProfile
        }
        let currentTime = now()
        let projection = try await materializer.materialize(userID: userID, now: currentTime)
        let pageDigests = projection.pages.map(\.digest)
        let snapshot = try V2SnapshotStage(
            snapshotID: snapshotID ?? .init(makeUUID().uuidString),
            baseSequence: projection.baseSequence,
            manifestDigest: try snapshotProjectionManifestDigest(
                baseSequence: projection.baseSequence,
                capabilityProfile: capabilityProfile,
                pageDigests: pageDigests
            ),
            nextSyncToken: .init(makeUUID().uuidString),
            receipt: .init(makeUUID().uuidString),
            expiresAt: currentTime.addingTimeInterval(capabilityLifetime),
            schemaVersion: V2SnapshotProjectionCodec.schemaVersion,
            capabilityProfile: capabilityProfile,
            pages: projection.pages
        )
        return try await sync.stageReset(userID: userID, deviceID: deviceID, snapshot: snapshot)
    }
}

public enum V2SnapshotProjectionMaterializerError: Error, Equatable, Sendable {
    case corruptPersistenceState
    case invalidDeliveredHistory
    case invalidCapabilityProfile
}

private enum SnapshotProjectionItem {
    case message(V2SnapshotMessageProjection)
    case relationship(V2SnapshotRelationshipProjection)
    case block(V2SnapshotUserBlockProjection)
    case moderation(V2SnapshotModerationProjection)
    case roomControl(V2SnapshotRoomControlProjection)
    case roomProfile(V2SnapshotRoomProfileProjection)
    case directRoomProfile(V2SnapshotDirectRoomProfileProjection)
    case directReadReceipt(V2SnapshotDirectReadReceiptProjection)
    case conversationState(V2SnapshotConversationState)
    case messageFavorite(V2SnapshotMessageFavorite)
    case timelineActivity(V2SnapshotTimelineActivity)
    case directSendingCapability(V2SnapshotDirectSendingCapability)
}

private struct SnapshotProjectionReplay {
    let messages: [V2SnapshotMessageProjection]
    let moderationActions: [V2SnapshotModerationProjection]
    let roomControls: [V2SnapshotRoomControlProjection]
    let roomProfiles: [V2SnapshotRoomProfileProjection]
    let timelineActivities: [V2SnapshotTimelineActivity]
    let directSendingCapabilities: [V2SnapshotDirectSendingCapability]
}

private func replayDeliveredHistory(_ rows: [SnapshotProjectionSyncLogRow]) throws -> SnapshotProjectionReplay {
    var expectedSequence: Int64 = 1
    var messages: [MessageID: ReplayedMessage] = [:]
    var tombstones: [MessageID: ReplayedTombstone] = [:]
    var moderationActions: [V2SnapshotModerationProjection] = []
    var roomControls: [RoomID: V2SnapshotRoomControlProjection] = [:]
    var roomProfiles: [RoomID: V2SnapshotRoomProfileProjection] = [:]
    var timelineActivities: [EventID: V2SnapshotTimelineActivity] = [:]
    var directSendingCapabilities: [RoomID: V2SnapshotDirectSendingCapability] = [:]
    let decoder = JSONDecoder()
    for row in rows {
        guard row.sequence == expectedSequence, let payload = row.payloadJSON.data(using: .utf8) else {
            throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory
        }
        expectedSequence += 1
        switch row.projectionKind {
        case "message":
            let event = try decoder.decode(SnapshotProjectionMessageWire.self, from: payload)
            let sourceEventID = try EventID(row.sourceEventID.uuidString)
            try replayMessage(event, sourceEventID: sourceEventID, messages: &messages, tombstones: &tombstones)
        case "moderation":
            let event = try decoder.decode(SnapshotProjectionModerationWire.self, from: payload)
            let sourceEventID = try EventID(row.sourceEventID.uuidString)
            switch event.eventType {
            case "member.muted":
                moderationActions.append(try event.muteProjection(sourceEventID: sourceEventID))
            case "room.frozen", "room.unfrozen":
                let control = try event.roomControlProjection(sourceEventID: sourceEventID)
                if let existing = roomControls[control.roomID], existing.roomSequence >= control.roomSequence {
                    throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory
                }
                roomControls[control.roomID] = control
            default:
                throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory
            }
        case "room", "membership":
            let event = try decoder.decode(SnapshotProjectionRoomWire.self, from: payload)
            let sourceEventID = try EventID(row.sourceEventID.uuidString)
            let profile = try event.profile(sourceEventID: sourceEventID)
            if let existing = roomProfiles[profile.roomID] {
                guard existing.membershipRevision < profile.membershipRevision else {
                    throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory
                }
            }
            roomProfiles[profile.roomID] = profile
        case "timeline_activity":
            let event = try decoder.decode(SnapshotProjectionTimelineActivityWire.self, from: payload)
            let activity = try event.projection(sourceEventID: .init(row.sourceEventID.uuidString))
            guard timelineActivities[activity.sourceEventID] == nil else { throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory }
            timelineActivities[activity.sourceEventID] = activity
        case "direct_sending_capability":
            let event = try decoder.decode(SnapshotProjectionDirectSendingCapabilityWire.self, from: payload)
            let capability = try event.projection()
            if let existing = directSendingCapabilities[capability.roomID], existing.updatedAt > capability.updatedAt {
                throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory
            }
            directSendingCapabilities[capability.roomID] = capability
        case "relationship", "user_block", "stranger_message_permission", "user_add_permission", "read_receipt_preferences", "direct_room_profile", "direct_read_receipt":
            // Social state is rebuilt from its authoritative tables. ClientKit
            // intentionally stores membership records only as sync history.
            // Direct-room public identities are similarly rebuilt from active
            // direct pairs, rather than replaying a potentially stale profile
            // record from history.
            continue
        default:
            throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory
        }
    }
    return .init(
        messages: try messages.values.map { try $0.projection() },
        moderationActions: moderationActions,
        roomControls: Array(roomControls.values),
        roomProfiles: Array(roomProfiles.values),
        timelineActivities: Array(timelineActivities.values),
        directSendingCapabilities: Array(directSendingCapabilities.values)
    )
}

private func replayMessage(
    _ event: SnapshotProjectionMessageWire,
    sourceEventID: EventID,
    messages: inout [MessageID: ReplayedMessage],
    tombstones: inout [MessageID: ReplayedTombstone]
) throws {
    switch event.eventType {
    case "message.accepted":
        let accepted = try ReplayedMessage(accepted: event, sourceEventID: sourceEventID)
        guard messages[accepted.messageID] == nil else { throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory }
        if let tombstone = tombstones[accepted.messageID] {
            guard tombstone.roomID == accepted.roomID, tombstone.revision > accepted.revision else { throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory }
            var withdrawn = accepted
            withdrawn.revision = tombstone.revision
            withdrawn.isWithdrawn = true
            messages[accepted.messageID] = withdrawn
        } else {
            messages[accepted.messageID] = accepted
        }
    case "message.edited":
        let messageID = try event.requiredMessageID()
        guard var message = messages[messageID], !message.isWithdrawn,
              event.roomID == message.roomID.rawValue,
              let revision = event.messageRevision,
              revision == message.revision + 1,
              let text = event.text, !text.isEmpty
        else { throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory }
        message.text = text
        message.entities = event.entities ?? []
        message.revision = revision
        messages[messageID] = message
    case "message.reaction_changed":
        let messageID = try event.requiredMessageID()
        guard var message = messages[messageID], event.roomID == message.roomID.rawValue,
              let actor = event.actorUserID, let reaction = event.reaction,
              let action = event.action, reaction.utf8.count <= 64, !reaction.isEmpty
        else { throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory }
        let key = "\(actor)|\(reaction)"
        switch action {
        case "add": message.reactions[key] = try .init(actorUserID: .init(actor), reaction: reaction)
        case "remove": message.reactions.removeValue(forKey: key)
        default: throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory
        }
        messages[messageID] = message
    case "message.withdrawn", "message.redacted":
        let messageID = try event.requiredMessageID()
        let roomID = try RoomID(event.roomID)
        guard let revision = event.messageRevision, revision > 1 else { throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory }
        let tombstone = ReplayedTombstone(roomID: roomID, revision: revision)
        if let message = messages[messageID] {
            guard message.roomID == roomID, revision > message.revision else { throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory }
            var withdrawn = message
            withdrawn.revision = revision
            withdrawn.isWithdrawn = true
            messages[messageID] = withdrawn
        } else if let existing = tombstones[messageID] {
            guard existing == tombstone else { throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory }
        } else {
            tombstones[messageID] = tombstone
        }
    default:
        throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory
    }
}

private struct ReplayedMessage {
    let sourceEventID: EventID
    let messageID: MessageID
    let roomID: RoomID
    let roomSequence: UInt64
    let timelineSequence: UInt64
    var revision: UInt64
    let senderUserID: UserID
    var text: String
    let media: [V2MediaReference]
    let mediaPresentations: [V2MediaPresentation]
    let mentions: [V2MentionTarget]
    var entities: [V2MessageEntity]
    let replyTo: V2MessageReplyReference?
    let forwardedFrom: V2ForwardedMessageAttribution?
    let createdAt: Date
    var isWithdrawn = false
    var reactions: [String: V2SnapshotMessageReaction] = [:]

    init(accepted event: SnapshotProjectionMessageWire, sourceEventID: EventID) throws {
        guard event.roomSequence > 0, (event.timelineSequence ?? event.roomSequence) > 0, let revision = event.messageRevision, revision == 1,
              event.serverCreatedAtMilliseconds >= 0,
              let messageID = event.messageID, let senderUserID = event.senderUserID,
              let text = event.text, !text.isEmpty || !(event.mediaIDs ?? []).isEmpty
        else { throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory }
        let media = try (event.mediaIDs ?? []).map { try V2MediaReference(mediaID: .init($0)) }
        let mediaPresentations = try (event.mediaPresentations ?? []).map { try $0.presentation() }
        let mentions = try (event.mentionUserIDs ?? []).map { try V2MentionTarget.user(.init($0)) }
            + ((event.mentionsEveryone ?? false) ? [.everyone] : [])
        let entities = event.entities ?? []
        let replyTo = try event.replyToMessageID.map { V2MessageReplyReference(messageID: try .init($0)) }
        let forwardedFrom: V2ForwardedMessageAttribution?
        switch (event.forwardedFromMessageID, event.forwardedFromUserID) {
        case (nil, nil):
            forwardedFrom = nil
        case let (.some(messageID), .some(userID)) where !messageID.isEmpty && !userID.isEmpty:
            forwardedFrom = try .init(messageID: .init(messageID), senderUserID: .init(userID))
        default:
            throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory
        }
        guard Set(media).count == media.count, media.count <= V2MessageCommandLimits.maxMediaAttachments,
              mediaPresentations.map(\.mediaID) == media.map(\.mediaID),
              Set(mentions).count == mentions.count, mentions.count <= V2MessageCommandLimits.maxMentions
        else { throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory }
        try V2RichMessageContent.validate(text: text, entities: entities)
        self.sourceEventID = sourceEventID
        self.messageID = try .init(messageID)
        self.roomID = try .init(event.roomID)
        self.roomSequence = event.roomSequence
        self.timelineSequence = event.timelineSequence ?? event.roomSequence
        self.revision = revision
        self.senderUserID = try .init(senderUserID)
        self.text = text
        self.media = media
        self.mediaPresentations = mediaPresentations
        self.mentions = mentions
        self.entities = entities
        self.replyTo = replyTo
        self.forwardedFrom = forwardedFrom
        self.createdAt = Date(timeIntervalSince1970: TimeInterval(event.serverCreatedAtMilliseconds) / 1_000)
    }

    func projection() throws -> V2SnapshotMessageProjection {
        try .init(sourceEventID: sourceEventID, messageID: messageID, roomID: roomID, roomSequence: roomSequence, timelineSequence: timelineSequence, messageRevision: revision, senderUserID: senderUserID, text: text, media: media, mediaPresentations: mediaPresentations, mentions: mentions, entities: entities, replyTo: replyTo, forwardedFrom: forwardedFrom, createdAt: createdAt, isWithdrawn: isWithdrawn, reactions: reactions.values.sorted())
    }
}

private struct ReplayedTombstone: Equatable {
    let roomID: RoomID
    let revision: UInt64
}

private struct SnapshotProjectionMessageWire: Decodable {
    let eventType: String
    let messageID: String?
    let roomID: String
    let roomSequence: UInt64
    let timelineSequence: UInt64?
    let messageRevision: UInt64?
    let senderUserID: String?
    let text: String?
    let mediaIDs: [String]?
    let mediaPresentations: [MediaPresentation]?
    let mentionUserIDs: [String]?
    let mentionsEveryone: Bool?
    let entities: [V2MessageEntity]?
    let replyToMessageID: String?
    let forwardedFromMessageID: String?
    let forwardedFromUserID: String?
    let serverCreatedAtMilliseconds: Int64
    let actorUserID: String?
    let reaction: String?
    let action: String?
    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"; case messageID = "message_id"; case roomID = "room_id"; case roomSequence = "room_sequence"; case timelineSequence = "timeline_sequence"; case messageRevision = "message_revision"; case senderUserID = "sender_user_id"; case text; case mediaIDs = "media_ids"; case mediaPresentations = "media_presentations"; case mentionUserIDs = "mention_user_ids"; case mentionsEveryone = "mentions_everyone"; case entities; case replyToMessageID = "reply_to_message_id"; case forwardedFromMessageID = "forwarded_from_message_id"; case forwardedFromUserID = "forwarded_from_user_id"; case serverCreatedAtMilliseconds = "server_created_at_ms"; case actorUserID = "actor_user_id"; case reaction; case action
    }
    func requiredMessageID() throws -> MessageID {
        guard let messageID else { throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory }
        return try .init(messageID)
    }

    struct MediaPresentation: Decodable {
        let mediaID: String
        let kind: V2MediaPresentation.Kind
        let contentType: String
        let byteCount: Int64

        func presentation() throws -> V2MediaPresentation {
            try .init(mediaID: .init(mediaID), kind: kind, contentType: contentType, byteCount: byteCount)
        }

        enum CodingKeys: String, CodingKey {
            case mediaID = "media_id"
            case kind
            case contentType = "content_type"
            case byteCount = "byte_count"
        }
    }
}

private struct SnapshotProjectionTimelineActivityWire: Decodable {
    let eventType: String
    let roomID: String
    let timelineSequence: UInt64
    let serverCreatedAtMilliseconds: Int64
    enum CodingKeys: String, CodingKey { case eventType = "event_type", roomID = "room_id", timelineSequence = "timeline_sequence", serverCreatedAtMilliseconds = "server_created_at_ms" }
    func projection(sourceEventID: EventID) throws -> V2SnapshotTimelineActivity {
        guard let kind = V2SnapshotTimelineActivity.Kind(rawValue: eventType), serverCreatedAtMilliseconds >= 0 else { throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory }
        return try .init(sourceEventID: sourceEventID, roomID: .init(roomID), timelineSequence: timelineSequence, kind: kind, createdAt: Date(timeIntervalSince1970: TimeInterval(serverCreatedAtMilliseconds) / 1_000))
    }
}

private struct SnapshotProjectionDirectSendingCapabilityWire: Decodable {
    let roomID: String
    let canSend: Bool
    let updatedAtMilliseconds: Int64
    enum CodingKeys: String, CodingKey { case roomID = "room_id", canSend = "can_send", updatedAtMilliseconds = "updated_at_ms" }
    func projection() throws -> V2SnapshotDirectSendingCapability {
        try .init(roomID: .init(roomID), canSend: canSend, updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAtMilliseconds) / 1_000))
    }
}

private struct SnapshotProjectionModerationWire: Decodable {
    let eventType: String
    let roomID: String
    let roomSequence: UInt64
    let actorUserID: String
    let targetUserID: String?
    let muteUntilMilliseconds: Int64?
    let serverCreatedAtMilliseconds: Int64
    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"; case roomID = "room_id"; case roomSequence = "room_sequence"; case actorUserID = "actor_user_id"; case targetUserID = "target_user_id"; case muteUntilMilliseconds = "mute_until_ms"; case serverCreatedAtMilliseconds = "server_created_at_ms"
    }
    func muteProjection(sourceEventID: EventID) throws -> V2SnapshotModerationProjection {
        guard eventType == "member.muted", let targetUserID, let muteUntilMilliseconds,
              roomSequence > 0, serverCreatedAtMilliseconds >= 0, muteUntilMilliseconds > serverCreatedAtMilliseconds
        else { throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory }
        return try .init(sourceEventID: sourceEventID, roomID: .init(roomID), roomSequence: roomSequence, actorUserID: .init(actorUserID), targetUserID: .init(targetUserID), muteUntil: Date(timeIntervalSince1970: TimeInterval(muteUntilMilliseconds) / 1_000), createdAt: Date(timeIntervalSince1970: TimeInterval(serverCreatedAtMilliseconds) / 1_000))
    }
    func roomControlProjection(sourceEventID: EventID) throws -> V2SnapshotRoomControlProjection {
        guard eventType == "room.frozen" || eventType == "room.unfrozen", roomSequence > 0, serverCreatedAtMilliseconds >= 0 else { throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory }
        return try .init(sourceEventID: sourceEventID, roomID: .init(roomID), roomSequence: roomSequence, actorUserID: .init(actorUserID), isFrozen: eventType == "room.frozen", createdAt: Date(timeIntervalSince1970: TimeInterval(serverCreatedAtMilliseconds) / 1_000))
    }
}

private struct SnapshotProjectionRoomWire: Decodable {
    let eventType: String
    let roomID: String
    let title: String
    let ownerUserID: String
    let membershipRevision: UInt64
    let createdAtMilliseconds: Int64
    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"; case roomID = "room_id"; case title
        case ownerUserID = "owner_user_id"; case membershipRevision = "membership_revision"; case createdAtMilliseconds = "created_at_ms"
    }
    func profile(sourceEventID: EventID) throws -> V2SnapshotRoomProfileProjection {
        guard eventType == "room.created" || eventType == "membership_changed", createdAtMilliseconds >= 0 else { throw V2SnapshotProjectionMaterializerError.invalidDeliveredHistory }
        return try .init(sourceEventID: sourceEventID, roomID: .init(roomID), title: title, ownerUserID: .init(ownerUserID), membershipRevision: membershipRevision, createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtMilliseconds) / 1_000))
    }
}

private struct SnapshotProjectionWatermarkRow: Decodable { let value: Int64 }
private struct SnapshotProjectionSyncLogRow: Decodable {
    let sequence: Int64
    let sourceEventID: UUID
    let projectionKind: String
    let payloadJSON: String
    enum CodingKeys: String, CodingKey { case sequence = "user_sync_sequence"; case sourceEventID = "source_event_id"; case projectionKind = "projection_kind"; case payloadJSON = "payload_json" }
}
private struct SnapshotProjectionRelationshipRow: Decodable {
    let targetUserID: UUID; let state: String; let requestedByUserID: UUID?; let updatedAt: Date
    enum CodingKeys: String, CodingKey { case targetUserID = "target_user_id"; case state; case requestedByUserID = "requested_by_user_id"; case updatedAt = "updated_at" }
}
private struct SnapshotProjectionBlockRow: Decodable {
    let targetUserID: UUID; let updatedAt: Date
    enum CodingKeys: String, CodingKey { case targetUserID = "target_user_id"; case updatedAt = "updated_at" }
}
private struct SnapshotProjectionPreferenceRow: Decodable {
    let allowsStrangerMessages: Bool; let updatedAt: Date
    enum CodingKeys: String, CodingKey { case allowsStrangerMessages = "allows_stranger_messages"; case updatedAt = "updated_at" }
}
private struct SnapshotProjectionUserAddPreferenceRow: Decodable {
    let allowsBeingAdded: Bool
    let updatedAt: Date
    enum CodingKeys: String, CodingKey { case allowsBeingAdded = "allows_being_added", updatedAt = "updated_at" }
}
private struct SnapshotProjectionReadReceiptPreferenceRow: Decodable {
    let allowsDirectReadReceipts: Bool; let allowsGroupReadReceipts: Bool; let updatedAt: Date
    enum CodingKeys: String, CodingKey { case allowsDirectReadReceipts = "allows_direct_read_receipts", allowsGroupReadReceipts = "allows_group_read_receipts", updatedAt = "updated_at" }
}
private struct SnapshotProjectionDirectRoomProfileRow: Decodable {
    let roomID: UUID
    let targetUserID: UUID
    let publicHandle: String
    let displayName: String
    let accountKind: String
    let revision: Int64
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case targetUserID = "target_user_id"
        case publicHandle = "public_handle"
        case displayName = "display_name"
        case accountKind = "account_kind"
        case revision
        case updatedAt = "updated_at"
    }
}
private struct SnapshotProjectionDirectReadReceiptRow: Decodable {
    let roomID: UUID
    let readerUserID: UUID
    let readThroughRoomSequence: Int64
    let updatedAt: Date
    enum CodingKeys: String, CodingKey { case roomID = "room_id", readerUserID = "reader_user_id", readThroughRoomSequence = "read_through_room_sequence", updatedAt = "updated_at" }
}
private struct SnapshotProjectionConversationStateRow: Decodable {
    let roomID: UUID; let isPinned: Bool; let isArchived: Bool; let muteUntil: Date?; let updatedAt: Date
    enum CodingKeys: String, CodingKey { case roomID = "room_id"; case isPinned = "is_pinned"; case isArchived = "is_archived"; case muteUntil = "mute_until"; case updatedAt = "updated_at" }
}
private struct SnapshotProjectionMessageFavoriteRow: Decodable {
    let roomID: UUID; let messageID: UUID; let isFavorited: Bool; let updatedAt: Date
    enum CodingKeys: String, CodingKey { case roomID = "room_id"; case messageID = "message_id"; case isFavorited = "is_favorited"; case updatedAt = "updated_at" }
}
private func snapshotProjectionUnsigned(_ value: Int64) throws -> UInt64 {
    guard value > 0 else { throw V2SnapshotProjectionMaterializerError.corruptPersistenceState }
    return UInt64(value)
}

private func snapshotAccountKind(_ value: String) throws -> V2AccountKind {
    guard let kind = V2AccountKind(rawValue: value) else {
        throw V2SnapshotProjectionMaterializerError.corruptPersistenceState
    }
    return kind
}

private func snapshotProjectionUUID<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let result = UUID(uuidString: value.rawValue) else { throw V2SnapshotProjectionMaterializerError.corruptPersistenceState }
    return result
}

private func snapshotProjectionSHA256(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

private struct SnapshotProjectionManifestDigestInput: Encodable {
    let schemaVersion: UInt32
    let baseSequence: UInt64
    let capabilityProfile: String
    let pageDigests: [String]
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case baseSequence = "base_sequence"
        case capabilityProfile = "capability_profile"
        case pageDigests = "page_digests"
    }
}

private func snapshotProjectionManifestDigest(baseSequence: UInt64, capabilityProfile: String, pageDigests: [String]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return snapshotProjectionSHA256(try encoder.encode(SnapshotProjectionManifestDigestInput(
        schemaVersion: V2SnapshotProjectionCodec.schemaVersion,
        baseSequence: baseSequence,
        capabilityProfile: capabilityProfile,
        pageDigests: pageDigests
    )))
}

import Fluent
import Foundation

enum ConversationRouteLifecycleState: String, Codable, Sendable {
    case pending
    case active
    case abandoned
}

/// Lifecycle for a physical conversation-shard migration. The active
/// `conversation_directory` route stays unchanged until the fenced cutover
/// phase independently verifies the copied canonical state.
enum ConversationShardMigrationStatus: String, Codable, Sendable {
    case prepared
    case copying
    case copied
    case verifying
    case readyToCutover = "ready_to_cutover"
    case cutoverPreparing = "cutover_preparing"
    case cutover
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .cutover, .failed, .cancelled:
            true
        case .prepared, .copying, .copied, .verifying, .readyToCutover, .cutoverPreparing:
            false
        }
    }
}

enum ConversationWriteFenceState: String, Codable, Sendable {
    case writable
    case blocked
}

/// Per-conversation source-shard fence used to drain transactions before a
/// physical move. Every canonical write must lock this row in its own shard
/// transaction before mutating conversation data.
final class ConversationWriteFence: Model, @unchecked Sendable {
    static let schema = "conversation_write_fences"

    @ID(custom: "conversation_id", generatedBy: .user)
    var id: UUID?

    @Field(key: "state")
    var state: String

    @Field(key: "epoch")
    var epoch: Int

    @Field(key: "updated_at")
    var updatedAt: Date

    init() { }

    init(
        conversationID: UUID,
        state: ConversationWriteFenceState = .writable,
        epoch: Int = 1,
        updatedAt: Date = Date()
    ) {
        id = conversationID
        self.state = state.rawValue
        self.epoch = epoch
        self.updatedAt = updatedAt
    }

    var stateEnum: ConversationWriteFenceState {
        get { ConversationWriteFenceState(rawValue: state) ?? .blocked }
        set { state = newValue.rawValue }
    }
}

enum IMRealtimeCellRegistryStatus: String, Codable, Sendable {
    case active
    case draining
    case disabled
}

/// Authoritative Cell endpoint registry used when
/// `IM_CELL_INGRESS_REGISTRY_MODE=database`. It is intentionally separate
/// from conversation routing: directory entries choose a Cell, while this
/// registry resolves the Cell's role-specific private ingress address.
final class IMRealtimeCellRegistryEntry: Model, @unchecked Sendable {
    static let schema = "im_realtime_cell_registry"

    @ID(custom: "cell_id", generatedBy: .user)
    var id: String?

    @Field(key: "status")
    var status: String

    @Field(key: "command_endpoint")
    var commandEndpoint: String

    @Field(key: "query_endpoint")
    var queryEndpoint: String

    @Field(key: "realtime_endpoint")
    var realtimeEndpoint: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        cellID: String,
        status: IMRealtimeCellRegistryStatus = .active,
        commandEndpoint: String,
        queryEndpoint: String,
        realtimeEndpoint: String
    ) {
        id = cellID
        self.status = status.rawValue
        self.commandEndpoint = commandEndpoint
        self.queryEndpoint = queryEndpoint
        self.realtimeEndpoint = realtimeEndpoint
    }

    var statusEnum: IMRealtimeCellRegistryStatus {
        get { IMRealtimeCellRegistryStatus(rawValue: status) ?? .disabled }
        set { status = newValue.rawValue }
    }

    func endpoint(for purpose: IMCellIngressEndpointPurpose) -> String {
        switch purpose {
        case .command: commandEndpoint
        case .query: queryEndpoint
        case .realtime: realtimeEndpoint
        }
    }
}

final class ConversationDirectoryEntry: Model, @unchecked Sendable {
    static let schema = "conversation_directory"

    @ID(custom: "conversation_id", generatedBy: .user)
    var id: UUID?

    @Field(key: "shard_id")
    var shardID: String

    @Field(key: "cell_id")
    var cellID: String

    @Field(key: "route_state")
    var routeState: String

    @Field(key: "route_version")
    var routeVersion: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    @OptionalField(key: "activated_at")
    var activatedAt: Date?

    init() { }

    init(
        conversationID: UUID,
        shardID: String,
        cellID: String = IMRealtimeCellConfiguration.defaultCellID,
        lifecycleState: ConversationRouteLifecycleState = .active,
        routeVersion: Int = 1
    ) {
        self.id = conversationID
        self.shardID = shardID
        self.cellID = cellID
        routeState = lifecycleState.rawValue
        self.routeVersion = routeVersion
        if lifecycleState == .active {
            activatedAt = Date()
        }
    }

    var lifecycleState: ConversationRouteLifecycleState {
        get { ConversationRouteLifecycleState(rawValue: routeState) ?? .active }
        set { routeState = newValue.rawValue }
    }
}

final class DirectConversationIndexEntry: Model, @unchecked Sendable {
    static let schema = "direct_conversation_index"

    @ID(custom: "pair_hash", generatedBy: .user)
    var id: String?

    @Field(key: "conversation_id")
    var conversationID: UUID

    @Field(key: "shard_id")
    var shardID: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(pairHash: String, conversationID: UUID, shardID: String) {
        self.id = pairHash
        self.conversationID = conversationID
        self.shardID = shardID
    }
}

/// Primary-database control record for a single conversation's physical shard
/// migration. `conversation_id` is intentionally the primary key: concurrent
/// operators cannot create two independent migrations for the same timeline.
final class ConversationShardMigration: Model, @unchecked Sendable {
    static let schema = "conversation_shard_migrations"

    @ID(custom: "conversation_id", generatedBy: .user)
    var id: UUID?

    @Field(key: "source_cell_id")
    var sourceCellID: String

    @Field(key: "source_shard_id")
    var sourceShardID: String

    @Field(key: "source_route_version")
    var sourceRouteVersion: Int

    @Field(key: "target_cell_id")
    var targetCellID: String

    @Field(key: "target_shard_id")
    var targetShardID: String

    @Field(key: "status")
    var status: String

    @Field(key: "source_member_count")
    var sourceMemberCount: Int

    @Field(key: "source_message_count")
    var sourceMessageCount: Int

    @Field(key: "source_domain_event_count")
    var sourceDomainEventCount: Int

    @Field(key: "source_domain_event_sequence_count")
    var sourceDomainEventSequenceCount: Int

    @Field(key: "source_timeline_notice_count")
    var sourceTimelineNoticeCount: Int

    @Field(key: "source_media_reference_count")
    var sourceMediaReferenceCount: Int

    @Field(key: "source_recipient_snapshot_count")
    var sourceRecipientSnapshotCount: Int

    // These are durable source-row offsets, not destination insert counts.
    // A crashed page may be replayed; target writes are idempotent by primary
    // key, then the watermark advances only after that page commits.
    @Field(key: "copy_conversation_watermark")
    var copyConversationWatermark: Int

    @Field(key: "copy_member_watermark")
    var copyMemberWatermark: Int

    @Field(key: "copy_message_watermark")
    var copyMessageWatermark: Int

    @Field(key: "copy_domain_event_watermark")
    var copyDomainEventWatermark: Int

    @Field(key: "copy_domain_event_sequence_watermark")
    var copyDomainEventSequenceWatermark: Int

    @Field(key: "copy_timeline_notice_watermark")
    var copyTimelineNoticeWatermark: Int

    @Field(key: "copy_media_reference_watermark")
    var copyMediaReferenceWatermark: Int

    @Field(key: "copy_recipient_snapshot_watermark")
    var copyRecipientSnapshotWatermark: Int

    @OptionalField(key: "source_fingerprint")
    var sourceFingerprint: String?

    @OptionalField(key: "target_fingerprint")
    var targetFingerprint: String?

    @OptionalField(key: "last_error_code")
    var lastErrorCode: String?

    @Field(key: "prepared_at")
    var preparedAt: Date

    @Field(key: "updated_at")
    var updatedAt: Date

    @OptionalField(key: "copy_started_at")
    var copyStartedAt: Date?

    @OptionalField(key: "copied_at")
    var copiedAt: Date?

    @OptionalField(key: "verified_at")
    var verifiedAt: Date?

    @OptionalField(key: "cutover_at")
    var cutoverAt: Date?

    /// A short-lived ownership record prevents two operators from attempting
    /// the same source fence and directory CAS concurrently.
    @OptionalField(key: "cutover_lease_token")
    var cutoverLeaseToken: String?

    @OptionalField(key: "cutover_lease_expires_at")
    var cutoverLeaseExpiresAt: Date?

    /// Per-migration capability used only by the source Cell when it uploads
    /// canonical pages to a remote target. It prevents the shared ingress
    /// credential from being sufficient to write into an arbitrary migration.
    @OptionalField(key: "transfer_token")
    var transferToken: String?

    @OptionalField(key: "transfer_token_expires_at")
    var transferTokenExpiresAt: Date?

    init() { }

    init(
        conversationID: UUID,
        sourceRoute: ConversationRoute,
        targetCellID: String,
        targetShardID: String,
        source: ConversationShardMigrationPreflight.CanonicalDataSnapshot,
        now: Date = Date(),
        transferToken: String = UUID().uuidString.lowercased(),
        transferTokenExpiresAt: Date? = Date().addingTimeInterval(24 * 60 * 60)
    ) {
        id = conversationID
        sourceCellID = sourceRoute.cellID
        sourceShardID = sourceRoute.shardID
        sourceRouteVersion = sourceRoute.version
        self.targetCellID = targetCellID
        self.targetShardID = targetShardID
        status = ConversationShardMigrationStatus.prepared.rawValue
        sourceMemberCount = source.memberCount
        sourceMessageCount = source.messageCount
        sourceDomainEventCount = source.domainEventCount
        sourceDomainEventSequenceCount = source.domainEventSequenceCount
        sourceTimelineNoticeCount = source.timelineNoticeCount
        sourceMediaReferenceCount = source.mediaReferenceCount
        sourceRecipientSnapshotCount = source.recipientSnapshotCount
        copyConversationWatermark = 0
        copyMemberWatermark = 0
        copyMessageWatermark = 0
        copyDomainEventWatermark = 0
        copyDomainEventSequenceWatermark = 0
        copyTimelineNoticeWatermark = 0
        copyMediaReferenceWatermark = 0
        copyRecipientSnapshotWatermark = 0
        self.transferToken = transferToken
        self.transferTokenExpiresAt = transferTokenExpiresAt
        preparedAt = now
        updatedAt = now
    }

    var statusEnum: ConversationShardMigrationStatus {
        get { ConversationShardMigrationStatus(rawValue: status) ?? .failed }
        set { status = newValue.rawValue }
    }
}

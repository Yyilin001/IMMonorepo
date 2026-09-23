import FluentKit
import Foundation
import IMV2Core
import Synchronization
@testable import IMV2Server

final class V2TelemetryTestClock: Sendable {
    private let wall = Mutex(Date(timeIntervalSince1970: 1_750_000_000))
    private let instant = Mutex(ContinuousClock.now)
    func now() -> Date { wall.withLock { $0 } }
    func monotonicNow() -> ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(by duration: Duration, wallShift: Double) {
        instant.withLock { $0 = $0.advanced(by: duration) }
        wall.withLock { $0 = $0.addingTimeInterval(wallShift) }
    }
}

struct V2DictionaryRuntimeEnvironment: V2RuntimeEnvironment, Sendable {
    private let values: [String: String]

    init(_ values: [String: String]) {
        self.values = values
    }

    func value(for key: String) -> String? {
        values[key]
    }
}

struct V2SingleUserShardRouter: V2UserShardRouter {
    private let route: V2UserShardRoute

    init(route: V2UserShardRoute) {
        self.route = route
    }

    func routes(for users: [UserID]) async throws -> [V2UserShardRoute] {
        Array(repeating: route, count: users.count)
    }
}

actor V2InMemoryTelemetrySink: V2TelemetrySink {
    private var recordedEvents: [V2TelemetryEvent] = []

    func record(_ event: V2TelemetryEvent) {
        recordedEvents.append(event)
    }

    func events() -> [V2TelemetryEvent] {
        recordedEvents
    }
}

struct V2DiscardingTelemetrySink: V2TelemetrySink {
    func record(_: V2TelemetryEvent) async {}
}

struct V2DiscardingForegroundGroupEventHintPublisher: V2ForegroundGroupEventHintSubmitting {
    func submitForegroundHint(_: V2GroupEventWake) {}
    func submitForegroundDirectMessage(_: V2AcceptedMessage) {}
}

private struct V2UnsupportedGatewayTestDependency: Error,
    V2GatewayRoomMembershipHandling,
    V2GatewayMessageWithdrawalHandling,
    V2GatewayMessageReactionHandling,
    V2GatewayMessageEditHandling,
    V2GatewayReadReceiptHandling,
    V2GatewayLiveActivityHandling,
    V2GatewayDirectMessagingHandling,
    V2GatewayGroupAudienceImportHandling,
    V2GatewayGroupEventLogHandling,
    V2GatewayRoomMembershipDirectoryHandling,
    V2RoomRecoveryCommandHandling,
    V2AccountRoomChangesStarting,
    V2GatewaySocialRelationshipHandling,
    V2GatewayModerationHandling,
    V2GatewayConversationCapabilitiesHandling,
    V2GatewayGroupCapabilitiesHandling,
    V2GroupRolePolicyBaselineReading,
    V2GatewayForwardMessagesHandling
{
    func startAccountRoomChanges(connectionID _: UUID, userID _: UserID) async throws -> String { throw self }
    func list(_: IMV2UserRoomDirectoryList, actorUserID _: UserID) async throws -> IMV2Envelope { throw self }
    func batch(_: IMV2RoomLatestVisibleBatch, actorUserID _: UserID) async throws -> IMV2Envelope { throw self }
    func batch(_: IMV2RoomSyncStateBatch, actorUserID _: UserID) async throws -> IMV2Envelope { throw self }
    func change(_: V2AuthenticatedMembershipChange) async throws -> V2RoomMembershipChangeOutcome { throw self }
    func withdraw(_: V2AuthenticatedMessageWithdrawal) async throws -> V2MessageWithdrawalOutcome { throw self }
    func change(_: V2AuthenticatedMessageReaction) async throws -> V2MessageReactionOutcome { throw self }
    func edit(_: V2AuthenticatedMessageEdit) async throws -> V2MessageEditOutcome { throw self }
    func record(_: V2AuthenticatedReadReceipt) async throws -> V2ReadReceiptOutcome { throw self }
    func setPreferences(actorUserID _: UserID, operationID _: ReadReceiptPreferenceOperationID, allowsDirectReadReceipts _: Bool, allowsGroupReadReceipts _: Bool) async throws -> V2SetReadReceiptPreferencesOutcome { throw self }
    func readers(roomID _: RoomID, messageID _: MessageID, actorUserID _: UserID, cursor _: String?, pageSize _: Int) async throws -> V2ReadReceiptReadersPage { throw self }
    func setPreferences(_: V2SetLiveActivityPreferencesCommand, now _: Date) async throws -> V2SetLiveActivityPreferencesOutcome { throw self }
    func preferences(userID _: UserID, now _: Date) async throws -> V2LiveActivityPreferences { throw self }
    func presence(roomID _: RoomID, viewerUserID _: UserID, now _: Date) async throws -> V2PresenceState { throw self }
    func authorizeTyping(roomID _: RoomID, actorUserID _: UserID, now _: Date) async throws { throw self }
    func open(actorUserID _: UserID, operationID _: DirectRoomOperationID, targetUserID _: UserID) async throws -> V2OpenDirectRoomOutcome { throw self }
    func setStrangerMessagePermission(actorUserID _: UserID, operationID _: StrangerMessagePreferenceOperationID, permission _: V2StrangerMessagePermission) async throws -> V2SetStrangerMessagePermissionOutcome { throw self }
    func setUserAddPermission(actorUserID _: UserID, operationID _: UserAddPreferenceOperationID, permission _: V2UserAddPermission) async throws -> V2SetUserAddPermissionOutcome { throw self }
    func begin(actorUserID _: UserID, operationID _: GroupRoomOperationID, title _: String) async throws -> V2GroupAudienceDraft { throw self }
    func append(actorUserID _: UserID, operationID _: GroupRoomOperationID, memberUserIDs _: [UserID]) async throws -> V2GroupAudienceDraft { throw self }
    func finalize(actorUserID _: UserID, operationID _: GroupRoomOperationID) async throws -> V2CreateGroupRoomOutcome { throw self }
    func cancel(actorUserID _: UserID, operationID _: GroupRoomOperationID) async throws { throw self }
    func pull(roomID _: RoomID, actorUserID _: UserID, afterRoomSequence _: UInt64, pageSize _: Int) async throws -> V2GroupEventLogPage { throw self }
    func subscribe(roomID _: RoomID, actorUserID _: UserID) async throws -> V2GroupEventSubscription { throw self }
    func list(_: V2RoomMembershipDirectoryRequest) async throws -> V2RoomMembershipDirectoryPage { throw self }
    func changeRelationship(actorUserID _: UserID, operationID _: RelationshipOperationID, targetUserID _: UserID, action _: V2RelationshipAction) async throws -> V2RelationshipOutcome { throw self }
    func changeUserBlock(actorUserID _: UserID, operationID _: UserBlockOperationID, targetUserID _: UserID, action _: V2UserBlockAction) async throws -> V2UserBlockOutcome { throw self }
    func apply(_: V2AuthenticatedModeration) async throws -> V2ModerationOutcome { throw self }
    func setConversationState(actorUserID _: UserID, command _: V2ConversationStateCommand) async throws -> V2ConversationCapabilitiesOutcome<V2ConversationState> { throw self }
    func setMessageFavorite(actorUserID _: UserID, command _: V2MessageFavoriteCommand) async throws -> V2ConversationCapabilitiesOutcome<V2MessageFavorite> { throw self }
    func setPinnedMessage(actorUserID _: UserID, command _: V2PinnedMessageCommand) async throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage> { throw self }
    func setAnnouncement(actorUserID _: UserID, command _: V2GroupAnnouncementCommand) async throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement> { throw self }
    func setRolePermissions(actorUserID _: UserID, command _: V2GroupRolePermissionsCommand) async throws -> V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange> { throw self }
    func changeMemberRole(actorUserID _: UserID, command _: V2GroupMemberRoleCommand) async throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange> { throw self }
    func readRolePolicyBaseline(roomID _: RoomID, actorUserID _: UserID) async throws -> V2GroupRolePolicyBaseline { throw self }
    func forward(actorUserID _: UserID, command _: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult] { throw self }
}

func makeGatewayDomainCommandHandler(
    sendMessage: V2SendMessageService,
    membership: V2RoomMembershipService? = nil,
    withdrawal: V2MessageWithdrawalService? = nil,
    reaction: V2MessageReactionService? = nil,
    edit: V2MessageEditService? = nil,
    readReceipt: V2ReadReceiptService? = nil,
    liveActivity: V2LiveActivityService? = nil,
    directMessaging: V2DirectMessagingService? = nil,
    groupAudienceImports: V2GroupAudienceImportService? = nil,
    groupEventLog: V2GroupEventLogService? = nil,
    foregroundGroupEventHints: any V2ForegroundGroupEventHintSubmitting = V2DiscardingForegroundGroupEventHintPublisher(),
    membershipDirectory: V2RoomMembershipDirectoryService? = nil,
    roomRecovery: (any V2RoomRecoveryCommandHandling)? = nil,
    accountChanges: (any V2AccountRoomChangesStarting)? = nil,
    socialRelationships: V2SocialRelationshipService? = nil,
    moderation: V2ModerationService? = nil,
    conversationCapabilities: V2ConversationCapabilitiesService? = nil,
    groupCapabilities: V2GroupCapabilitiesService? = nil,
    groupRolePolicyBaseline: (any V2GroupRolePolicyBaselineReading)? = nil,
    forwardMessages: (any V2ForwardMessagesHandling)? = nil,
    sync: V2SyncService,
    telemetry: any V2TelemetrySink = V2DiscardingTelemetrySink(),
    databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil,
    maximumGroupEventPagePayloadBytes: Int = 48 * 1_024,
    now: @escaping @Sendable () -> Date = Date.init,
    monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
) -> V2GatewayDomainCommandHandler {
    let unsupported = V2UnsupportedGatewayTestDependency()
    return V2GatewayDomainCommandHandler(
        sendMessage: sendMessage,
        membershipHandler: membership.map { $0 as any V2GatewayRoomMembershipHandling } ?? unsupported,
        withdrawalHandler: withdrawal.map { $0 as any V2GatewayMessageWithdrawalHandling } ?? unsupported,
        reactionHandler: reaction.map { $0 as any V2GatewayMessageReactionHandling } ?? unsupported,
        editHandler: edit.map { $0 as any V2GatewayMessageEditHandling } ?? unsupported,
        readReceiptHandler: readReceipt.map { $0 as any V2GatewayReadReceiptHandling } ?? unsupported,
        liveActivityHandler: liveActivity.map { $0 as any V2GatewayLiveActivityHandling } ?? unsupported,
        directMessagingHandler: directMessaging.map { $0 as any V2GatewayDirectMessagingHandling } ?? unsupported,
        groupAudienceImportHandler: groupAudienceImports.map { $0 as any V2GatewayGroupAudienceImportHandling } ?? unsupported,
        groupEventLogHandler: groupEventLog.map { $0 as any V2GatewayGroupEventLogHandling } ?? unsupported,
        foregroundGroupEventHints: foregroundGroupEventHints,
        membershipDirectoryHandler: membershipDirectory.map { $0 as any V2GatewayRoomMembershipDirectoryHandling } ?? unsupported,
        roomRecovery: roomRecovery ?? unsupported,
        accountChanges: accountChanges ?? unsupported,
        socialRelationshipHandler: socialRelationships.map { $0 as any V2GatewaySocialRelationshipHandling } ?? unsupported,
        moderationHandler: moderation.map { $0 as any V2GatewayModerationHandling } ?? unsupported,
        conversationCapabilitiesHandler: conversationCapabilities.map { $0 as any V2GatewayConversationCapabilitiesHandling } ?? unsupported,
        groupCapabilitiesHandler: groupCapabilities.map { $0 as any V2GatewayGroupCapabilitiesHandling } ?? unsupported,
        groupRolePolicyBaseline: groupRolePolicyBaseline ?? unsupported,
        forwardMessagesHandler: forwardMessages.map { $0 as any V2GatewayForwardMessagesHandling } ?? unsupported,
        sync: sync,
        telemetry: telemetry,
        databaseWorkAdmission: databaseWorkAdmission,
        maximumGroupEventPagePayloadBytes: maximumGroupEventPagePayloadBytes,
        now: now,
        monotonicNow: monotonicNow
    )
}

struct V2AllowingGatewayCommandAdmission: V2AuthenticatedGatewayCommandAdmitting {
    func admit(identity _: V2AuthenticatedConnection, cost _: Int, now _: Date) -> Bool {
        true
    }
}

struct V2FixedUserShardRouteFence: V2UserShardRouteFencing {
    let route: V2UserShardRoute
    let database: any Database

    func withCurrentRoute<Result: Sendable>(
        for _: UserID,
        _ operation: @escaping @Sendable (V2UserShardRoute, any Database) async throws -> Result
    ) async throws -> Result {
        try await operation(route, database)
    }
}

private struct V2DiscardingUserShardProjectionShadower: V2UserShardProjectionShadowing {
    func shadowIfForwarding(
        userID _: UserID,
        sourceEventID _: EventID,
        projectionKinds _: Set<String>
    ) async throws -> UInt64? {
        nil
    }
}

extension PostgresV2RoomWriteStore {
    init(database: any Database) {
        self.init(
            database: database,
            strangerMessagePolicy: try! .init(maximumMessagesPerWindow: 3, window: 86_400),
            contentReviewMode: .enabled)
    }

    init(database: any Database, contentReviewMode: V2ContentReviewMode) {
        self.init(
            database: database,
            strangerMessagePolicy: try! .init(maximumMessagesPerWindow: 3, window: 86_400),
            contentReviewMode: contentReviewMode)
    }

    init(database: any Database, strangerMessagePolicy: V2StrangerMessagePolicy) {
        self.init(
            database: database,
            strangerMessagePolicy: strangerMessagePolicy,
            contentReviewMode: .enabled)
    }

}

extension PostgresV2MessageEditStore {
    init(database: any Database) {
        self.init(database: database, contentReviewMode: .enabled)
    }
}

extension PostgresV2ReadReceiptStore {
    init(database: any Database) {
        self.init(database: database, shadowForwarder: V2DiscardingUserShardProjectionShadower())
    }
}

extension PostgresV2DirectMessagingStore {
    init(database: any Database) {
        self.init(database: database, shadowForwarder: V2DiscardingUserShardProjectionShadower())
    }
}

extension PostgresV2SocialRelationshipStore {
    init(database: any Database) {
        self.init(database: database, shadowForwarder: V2DiscardingUserShardProjectionShadower())
    }
}

extension PostgresV2ConversationCapabilitiesStore {
    init(database: any Database) {
        self.init(database: database, shadowForwarder: V2DiscardingUserShardProjectionShadower())
    }
}

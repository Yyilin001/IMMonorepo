@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import IMV2ActorContracts
import Synchronization
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
@testable import IMV2ServerGateway

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
    func submitForegroundDirectEvent(_: V2DirectRoomLiveEvent) {}
    func submitForegroundDirectMessage(_: V2AcceptedMessage) {}
    func submitForegroundDirectMessage(_: V2AcceptedMessage, excludingConnectionID _: UUID?) {}
}

private struct V2UnsupportedGatewayTestDependency: Error,
    V2GatewayMessageSendOperationHandling,
    V2GatewayReadReceiptHandling,
    V2GatewayLiveActivityHandling,
    V2GatewayGroupEventLogHandling,
    V2GatewayRoomMembershipDirectoryHandling,
    V2RoomRecoveryCommandHandling,
    V2AccountRoomChangesStarting,
    V2GatewayConversationCapabilitiesHandling,
    V2GroupRolePolicyBaselineReading
{
    var managesForegroundWriteAdmission: Bool { false }
    func sendOperation(_: V2MessageSendOperationCommand) async throws -> V2MessageSendOperationRecoveryResult { throw self }
    func recoverSendOperation(_: V2MessageSendOperationRecoveryRequest) async throws -> V2MessageSendOperationRecoveryResult { throw self }
    func startAccountRoomChanges(connectionID _: UUID, userID _: UserID) async throws -> String { throw self }
    func list(_: IMV2UserRoomDirectoryList, actorUserID _: UserID) async throws -> IMV2Envelope { throw self }
    func batch(_: IMV2RoomLatestVisibleBatch, actorUserID _: UserID) async throws -> IMV2Envelope { throw self }
    func batch(_: IMV2RoomSyncStateBatch, actorUserID _: UserID) async throws -> IMV2Envelope { throw self }
    func record(_: V2AuthenticatedReadReceipt) async throws -> V2ReadReceiptOutcome { throw self }
    func setPreferences(actorUserID _: UserID, operationID _: ReadReceiptPreferenceOperationID, allowsDirectReadReceipts _: Bool, allowsGroupReadReceipts _: Bool) async throws -> V2SetReadReceiptPreferencesOutcome { throw self }
    func readers(roomID _: RoomID, messageID _: MessageID, actorUserID _: UserID, cursor _: String?, pageSize _: Int) async throws -> V2ReadReceiptReadersPage { throw self }
    func setPreferences(_: V2SetLiveActivityPreferencesCommand, now _: Date) async throws -> V2SetLiveActivityPreferencesOutcome { throw self }
    func preferences(userID _: UserID, now _: Date) async throws -> V2LiveActivityPreferences { throw self }
    func presence(roomID _: RoomID, viewerUserID _: UserID, now _: Date) async throws -> V2PresenceState { throw self }
    func authorizeTyping(roomID _: RoomID, actorUserID _: UserID, now _: Date) async throws { throw self }
    func pull(roomID _: RoomID, actorUserID _: UserID, afterRoomSequence _: UInt64, pageSize _: Int) async throws -> V2GroupEventLogPage { throw self }
    func subscribe(roomID _: RoomID, actorUserID _: UserID) async throws -> V2GroupEventSubscription { throw self }
    func list(_: V2RoomMembershipDirectoryRequest) async throws -> V2RoomMembershipDirectoryPage { throw self }
    func setConversationState(actorUserID _: UserID, command _: V2ConversationStateCommand) async throws -> V2PersonalPreferenceReceipt { throw self }
    func setMessageFavorite(actorUserID _: UserID, command _: V2MessageFavoriteCommand) async throws -> V2PersonalPreferenceReceipt { throw self }
    func readRolePolicyBaseline(roomID _: RoomID, actorUserID _: UserID) async throws -> V2GroupRolePolicyBaseline { throw self }
}

func makeGatewayDomainCommandHandler(
    messageSendOperations: (any V2GatewayMessageSendOperationHandling)? = nil,
    readReceipt: V2ReadReceiptService? = nil,
    liveActivity: V2LiveActivityService? = nil,
    groupEventLog: V2GroupEventLogService? = nil,
    foregroundGroupEventHints: any V2ForegroundGroupEventHintSubmitting = V2DiscardingForegroundGroupEventHintPublisher(),
    membershipDirectory: V2RoomMembershipDirectoryService? = nil,
    roomRecovery: (any V2RoomRecoveryCommandHandling)? = nil,
    accountChanges: (any V2AccountRoomChangesStarting)? = nil,
    conversationCapabilities: V2ConversationCapabilitiesService? = nil,
    groupRolePolicyBaseline: (any V2GroupRolePolicyBaselineReading)? = nil,
    sync: V2SyncService,
    telemetry: any V2TelemetrySink = V2DiscardingTelemetrySink(),
    databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil,
    roomCommandsHostAdmitted: Bool = false,
    maximumGroupEventPagePayloadBytes: Int = 48 * 1_024,
    now: @escaping @Sendable () -> Date = Date.init,
    monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
) -> V2GatewayDomainCommandHandler {
    let unsupported = V2UnsupportedGatewayTestDependency()
    return V2GatewayDomainCommandHandler(
        readReceiptHandler: readReceipt.map { $0 as any V2GatewayReadReceiptHandling } ?? unsupported,
        messageSendOperations: messageSendOperations ?? unsupported,
        liveActivityHandler: liveActivity.map { $0 as any V2GatewayLiveActivityHandling } ?? unsupported,
        groupEventLogHandler: groupEventLog.map { $0 as any V2GatewayGroupEventLogHandling } ?? unsupported,
        foregroundGroupEventHints: foregroundGroupEventHints,
        membershipDirectoryHandler: membershipDirectory.map { $0 as any V2GatewayRoomMembershipDirectoryHandling } ?? unsupported,
        roomRecovery: roomRecovery ?? unsupported,
        accountChanges: accountChanges ?? unsupported,
        conversationCapabilitiesHandler: conversationCapabilities.map { $0 as any V2GatewayConversationCapabilitiesHandling } ?? unsupported,
        groupRolePolicyBaseline: groupRolePolicyBaseline ?? unsupported,
        sync: sync,
        telemetry: telemetry,
        databaseWorkAdmission: databaseWorkAdmission,
        roomCommandsHostAdmitted: roomCommandsHostAdmitted,
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

struct V2DiscardingUserShardProjectionDelivery: V2UserShardProjectionDelivering {
    func deliverToCurrentShard(
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
        self.init(database: database, projectionDelivery: V2DiscardingUserShardProjectionDelivery())
    }
}

extension PostgresV2DirectMessagingStore {
    /// Explicitly co-located fixture only. Split fixtures supply their control
    /// identity reader through the production initializer instead.
    init(database: any Database) {
        self.init(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database),
            projectionDelivery: V2DiscardingUserShardProjectionDelivery())
    }
    init(database: any Database, projectionDelivery: any V2UserShardProjectionDelivering,
         authorizationCoordinator: V2DirectAuthorizationCoordinator? = nil) {
        self.init(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database),
            projectionDelivery: projectionDelivery, authorizationCoordinator: authorizationCoordinator)
    }
}

extension PostgresV2SocialRelationshipStore {
    init(database: any Database) {
        self.init(database: database, projectionDelivery: V2DiscardingUserShardProjectionDelivery())
    }
}

// Existing presentation tests assert domain values; this accessor explicitly checks
// the new immutable terminal receipt before exposing its committed payload.
extension V2ContactAliasUpdateReceipt {
    var committedValue:V2ContactAlias { get throws { switch outcome {
        case .committed(let value):return value
        case .rejected(.revisionConflict(let current)):throw V2ProfilePresentationError.revisionConflict(current)
        case .rejected(.permissionDenied):throw V2ProfilePresentationError.forbidden
        default:throw V2ProfilePresentationError.corruptPersistenceState
    } } }
}
extension V2GroupNicknameUpdateReceipt {
    var committedValue:V2GroupMemberPresentation { get throws { switch outcome {
        case .committed(let value):return value
        case .rejected(.revisionConflict(let current)):throw V2ProfilePresentationError.revisionConflict(current)
        case .rejected(.permissionDenied):throw V2ProfilePresentationError.forbidden
        default:throw V2ProfilePresentationError.corruptPersistenceState
    } } }
}
extension V2ActorGroupNicknameUpdateWire {
    init(roomID:RoomID,actorUserID:UserID,operationID:GroupNicknameOperationID,expectedRevision:V2ProfileRevision?,nickname:String?) {
        self.init(command:try! .init(actorUserID:actorUserID,roomID:roomID,operationID:operationID,expectedRevision:expectedRevision,nickname:nickname,firstSubmissionDeadlineMilliseconds:UInt64(Int64.max)))
    }
}

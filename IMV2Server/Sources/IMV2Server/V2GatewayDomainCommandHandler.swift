import Foundation
import IMV2Core

private func v2MessageEntity(_ wire: IMV2MessageEntity) throws -> V2MessageEntity {
    let kind: V2MessageEntity.Kind
    switch wire.kind {
    case .bold: kind = .bold
    case .italic: kind = .italic
    case .underline: kind = .underline
    case .strikethrough: kind = .strikethrough
    case .spoiler: kind = .spoiler
    case .code: kind = .code
    case .preformatted: kind = .preformatted
    case .link: kind = .link
    case .unspecified, .UNRECOGNIZED: throw V2RichMessageContentError.invalidEntity
    }
    return try .init(offsetUTF16: Int(wire.offsetUtf16), lengthUTF16: Int(wire.lengthUtf16), kind: kind, linkURL: wire.linkURL.isEmpty ? nil : URL(string: wire.linkURL))
}

private enum V2GatewayResponseValueError: Error {
    case invalidCount
}

private func v2GatewayCount(_ value: Int) throws -> UInt32 {
    guard let count = UInt32(exactly: value) else { throw V2GatewayResponseValueError.invalidCount }
    return count
}

/// Exact protobuf payload size for the gateway's `GroupEventPage` envelope.
///
/// The handler used to append one event, serialize the whole candidate page,
/// then repeat. That makes a full page quadratic in both protobuf work and
/// temporary allocations. Keeping the estimator beside the wire mapping makes
/// the size fence linear while the final gateway encode remains authoritative.
private func v2GroupEventPageEnvelopeBytes(
    roomID: String,
    eventFieldBytes: Int,
    nextRoomSequence: UInt64,
    hasMore: Bool
) -> Int {
    let pageBytes =
        v2ProtobufLengthDelimitedFieldBytes(fieldNumber: 1, payloadBytes: roomID.utf8.count)
        + eventFieldBytes
        + v2ProtobufVarintFieldBytes(fieldNumber: 3, value: nextRoomSequence)
        + (hasMore ? v2ProtobufVarintFieldBytes(fieldNumber: 4, value: 1) : 0)

    return v2ProtobufVarintFieldBytes(fieldNumber: 1, value: .max)
        + v2ProtobufVarintFieldBytes(fieldNumber: 2, value: UInt64(IMV2ProtocolVersion.current))
        + v2ProtobufLengthDelimitedFieldBytes(fieldNumber: 62, payloadBytes: pageBytes)
}

private func v2GroupEventRepeatedFieldBytes(_ entry: V2GroupEventLogEntry) -> Int {
    let eventBytes =
        v2ProtobufLengthDelimitedFieldBytes(fieldNumber: 1, payloadBytes: entry.sourceEventID.rawValue.utf8.count)
        + v2ProtobufVarintFieldBytes(fieldNumber: 2, value: entry.roomSequence)
        + v2ProtobufLengthDelimitedFieldBytes(fieldNumber: 3, payloadBytes: entry.projectionKind.utf8.count)
        + v2ProtobufLengthDelimitedFieldBytes(fieldNumber: 4, payloadBytes: entry.payload.count)
    return v2ProtobufLengthDelimitedFieldBytes(fieldNumber: 2, payloadBytes: eventBytes)
}

private func v2ProtobufLengthDelimitedFieldBytes(fieldNumber: Int, payloadBytes: Int) -> Int {
    v2ProtobufTagBytes(fieldNumber: fieldNumber, wireType: 2)
        + v2ProtobufVarintByteCount(UInt64(payloadBytes))
        + payloadBytes
}

private func v2ProtobufVarintFieldBytes(fieldNumber: Int, value: UInt64) -> Int {
    guard value != 0 else { return 0 }
    return v2ProtobufTagBytes(fieldNumber: fieldNumber, wireType: 0)
        + v2ProtobufVarintByteCount(value)
}

private func v2ProtobufTagBytes(fieldNumber: Int, wireType: UInt64) -> Int {
    v2ProtobufVarintByteCount((UInt64(fieldNumber) << 3) | wireType)
}

private func v2ProtobufVarintByteCount(_ value: UInt64) -> Int {
    var remaining = value
    var count = 1
    while remaining >= 0x80 {
        remaining >>= 7
        count += 1
    }
    return count
}

protocol V2GatewayRoomMembershipHandling: Sendable {
    func change(_ request: V2AuthenticatedMembershipChange) async throws -> V2RoomMembershipChangeOutcome
}

protocol V2GatewayMessageWithdrawalHandling: Sendable {
    func withdraw(_ request: V2AuthenticatedMessageWithdrawal) async throws -> V2MessageWithdrawalOutcome
}

protocol V2GatewayMessageReactionHandling: Sendable {
    func change(_ request: V2AuthenticatedMessageReaction) async throws -> V2MessageReactionOutcome
}

protocol V2GatewayMessageEditHandling: Sendable {
    func edit(_ request: V2AuthenticatedMessageEdit) async throws -> V2MessageEditOutcome
}

protocol V2GatewayReadReceiptHandling: Sendable {
    var managesForegroundWriteAdmission: Bool { get }
    func record(_ request: V2AuthenticatedReadReceipt) async throws -> V2ReadReceiptOutcome
    func setPreferences(actorUserID: UserID, operationID: ReadReceiptPreferenceOperationID, allowsDirectReadReceipts: Bool, allowsGroupReadReceipts: Bool) async throws -> V2SetReadReceiptPreferencesOutcome
    func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID, cursor: String?, pageSize: Int) async throws -> V2ReadReceiptReadersPage
}

extension V2GatewayReadReceiptHandling {
    var managesForegroundWriteAdmission: Bool { false }
}

protocol V2GatewayLiveActivityHandling: Sendable {
    func setPreferences(_ command: V2SetLiveActivityPreferencesCommand, now: Date) async throws -> V2SetLiveActivityPreferencesOutcome
    func preferences(userID: UserID, now: Date) async throws -> V2LiveActivityPreferences
    func presence(roomID: RoomID, viewerUserID: UserID, now: Date) async throws -> V2PresenceState
    func authorizeTyping(roomID: RoomID, actorUserID: UserID, now: Date) async throws
}

protocol V2GatewayDirectMessagingHandling: Sendable {
    func open(actorUserID: UserID, operationID: DirectRoomOperationID, targetUserID: UserID) async throws -> V2OpenDirectRoomOutcome
    func setStrangerMessagePermission(actorUserID: UserID, operationID: StrangerMessagePreferenceOperationID, permission: V2StrangerMessagePermission) async throws -> V2SetStrangerMessagePermissionOutcome
    func setUserAddPermission(actorUserID: UserID, operationID: UserAddPreferenceOperationID, permission: V2UserAddPermission) async throws -> V2SetUserAddPermissionOutcome
}

protocol V2GatewayGroupAudienceImportHandling: Sendable {
    func begin(actorUserID: UserID, operationID: GroupRoomOperationID, title: String) async throws -> V2GroupAudienceDraft
    func append(actorUserID: UserID, operationID: GroupRoomOperationID, memberUserIDs: [UserID]) async throws -> V2GroupAudienceDraft
    func finalize(actorUserID: UserID, operationID: GroupRoomOperationID) async throws -> V2CreateGroupRoomOutcome
    func cancel(actorUserID: UserID, operationID: GroupRoomOperationID) async throws
}

protocol V2GatewayGroupEventLogHandling: Sendable {
    func pull(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2GroupEventLogPage
    func pullPrepared(
        roomID: RoomID,
        actorUserID: UserID,
        afterRoomSequence: UInt64,
        pageSize: Int,
        context: V2PreparedGroupEventPageEncodingContext
    ) async throws -> V2PreparedGroupEventPullResult
    func subscribe(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupEventSubscription
    func recordCommittedDirectRoomLogMessage(_ message: V2AcceptedMessage) async
    func recordCommittedDirectRoomLogEvent(_ event: V2DirectRoomLiveEvent) async
}

extension V2GatewayGroupEventLogHandling {
    func pullPrepared(
        roomID: RoomID,
        actorUserID: UserID,
        afterRoomSequence: UInt64,
        pageSize: Int,
        context _: V2PreparedGroupEventPageEncodingContext
    ) async throws -> V2PreparedGroupEventPullResult {
        .page(try await pull(
            roomID: roomID,
            actorUserID: actorUserID,
            afterRoomSequence: afterRoomSequence,
            pageSize: pageSize
        ))
    }

    func recordCommittedDirectRoomLogMessage(_: V2AcceptedMessage) async {}
    func recordCommittedDirectRoomLogEvent(_: V2DirectRoomLiveEvent) async {}
}

protocol V2GatewayRoomMembershipDirectoryHandling: Sendable {
    func list(_ request: V2RoomMembershipDirectoryRequest) async throws -> V2RoomMembershipDirectoryPage
}

protocol V2GatewaySocialRelationshipHandling: Sendable {
    func changeRelationship(actorUserID: UserID, operationID: RelationshipOperationID, targetUserID: UserID, action: V2RelationshipAction) async throws -> V2RelationshipOutcome
    func changeUserBlock(actorUserID: UserID, operationID: UserBlockOperationID, targetUserID: UserID, action: V2UserBlockAction) async throws -> V2UserBlockOutcome
}

protocol V2GatewayModerationHandling: Sendable {
    func apply(_ request: V2AuthenticatedModeration) async throws -> V2ModerationOutcome
}

protocol V2GatewayConversationCapabilitiesHandling: Sendable {
    func setConversationState(actorUserID: UserID, command: V2ConversationStateCommand) async throws -> V2ConversationCapabilitiesOutcome<V2ConversationState>
    func setMessageFavorite(actorUserID: UserID, command: V2MessageFavoriteCommand) async throws -> V2ConversationCapabilitiesOutcome<V2MessageFavorite>
}

protocol V2GatewayGroupCapabilitiesHandling: Sendable {
    func setPinnedMessage(actorUserID: UserID, command: V2PinnedMessageCommand) async throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage>
    func setAnnouncement(actorUserID: UserID, command: V2GroupAnnouncementCommand) async throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement>
    func setRolePermissions(actorUserID: UserID, command: V2GroupRolePermissionsCommand) async throws -> V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange>
    func changeMemberRole(actorUserID: UserID, command: V2GroupMemberRoleCommand) async throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange>
}

typealias V2GatewayForwardMessagesHandling = V2ForwardMessagesHandling

extension V2RoomMembershipService: V2GatewayRoomMembershipHandling {}
extension V2MessageWithdrawalService: V2GatewayMessageWithdrawalHandling {}
extension V2MessageReactionService: V2GatewayMessageReactionHandling {}
extension V2MessageEditService: V2GatewayMessageEditHandling {}
extension V2ReadReceiptService: V2GatewayReadReceiptHandling {}
extension V2LiveActivityService: V2GatewayLiveActivityHandling {}
extension V2DirectMessagingService: V2GatewayDirectMessagingHandling {}
extension V2GroupAudienceImportService: V2GatewayGroupAudienceImportHandling {}
extension V2GroupEventLogService: V2GatewayGroupEventLogHandling {}
extension V2RoomMembershipDirectoryService: V2GatewayRoomMembershipDirectoryHandling {}
extension V2SocialRelationshipService: V2GatewaySocialRelationshipHandling {}
extension V2ModerationService: V2GatewayModerationHandling {}
extension V2ConversationCapabilitiesService: V2GatewayConversationCapabilitiesHandling {}
extension V2GroupCapabilitiesService: V2GatewayGroupCapabilitiesHandling {}

/// Routes validated authenticated protobuf commands to the V2 domain services.
public struct V2GatewayDomainCommandHandler:
    V2GatewayCommandHandler,
    V2PreparedGroupEventCommandHandling {
    private let sendMessage: V2SendMessageService
    private let membership: any V2GatewayRoomMembershipHandling
    private let withdrawal: any V2GatewayMessageWithdrawalHandling
    private let reaction: any V2GatewayMessageReactionHandling
    private let edit: any V2GatewayMessageEditHandling
    private let readReceipt: any V2GatewayReadReceiptHandling
    private let liveActivity: any V2GatewayLiveActivityHandling
    private let directMessaging: any V2GatewayDirectMessagingHandling
    private let groupAudienceImports: any V2GatewayGroupAudienceImportHandling
    private let groupEventLog: any V2GatewayGroupEventLogHandling
    private let foregroundGroupEventHints: any V2ForegroundGroupEventHintSubmitting
    private let membershipDirectory: any V2GatewayRoomMembershipDirectoryHandling
    private let socialRelationships: any V2GatewaySocialRelationshipHandling
    private let moderation: any V2GatewayModerationHandling
    private let conversationCapabilities: any V2GatewayConversationCapabilitiesHandling
    private let groupCapabilities: any V2GatewayGroupCapabilitiesHandling
    private let groupRolePolicyBaseline: any V2GroupRolePolicyBaselineReading
    private let forwardMessages: any V2GatewayForwardMessagesHandling
    private let sync: V2SyncService
    private let telemetry: any V2TelemetrySink
    private let databaseWorkAdmission: V2DatabaseWorkAdmissionController?
    private let controlWriteAdmissionEnabled: Bool
    /// A room-log page shares the ordinary gateway-frame payload budget with
    /// its envelope headers. The final wire encoder remains authoritative;
    /// this budget prevents a valid durable backlog from becoming a transport
    /// disconnect before it reaches that boundary.
    private let maximumGroupEventPagePayloadBytes: Int
    private let now: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant

    public init(sendMessage: V2SendMessageService, membership: V2RoomMembershipService, withdrawal: V2MessageWithdrawalService, reaction: V2MessageReactionService, edit: V2MessageEditService, readReceipt: V2ReadReceiptService, liveActivity: V2LiveActivityService, directMessaging: V2DirectMessagingService, groupAudienceImports: V2GroupAudienceImportService, groupEventLog: V2GroupEventLogService, foregroundGroupEventHints: any V2ForegroundGroupEventHintSubmitting, membershipDirectory: V2RoomMembershipDirectoryService, socialRelationships: V2SocialRelationshipService, moderation: V2ModerationService, conversationCapabilities: V2ConversationCapabilitiesService, groupCapabilities: V2GroupCapabilitiesService, groupRolePolicyBaseline: any V2GroupRolePolicyBaselineReading, forwardMessages: any V2ForwardMessagesHandling, sync: V2SyncService, telemetry: any V2TelemetrySink, databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil, controlWriteAdmissionEnabled: Bool = false, maximumGroupEventPagePayloadBytes: Int = 48 * 1_024, now: @escaping @Sendable () -> Date = Date.init, monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        precondition(maximumGroupEventPagePayloadBytes > 0)
        self.sendMessage = sendMessage
        self.membership = membership
        self.withdrawal = withdrawal
        self.reaction = reaction
        self.edit = edit
        self.readReceipt = readReceipt
        self.liveActivity = liveActivity
        self.directMessaging = directMessaging
        self.groupAudienceImports = groupAudienceImports
        self.groupEventLog = groupEventLog
        self.foregroundGroupEventHints = foregroundGroupEventHints
        self.membershipDirectory = membershipDirectory
        self.socialRelationships = socialRelationships
        self.moderation = moderation
        self.conversationCapabilities = conversationCapabilities
        self.groupCapabilities = groupCapabilities
        self.groupRolePolicyBaseline = groupRolePolicyBaseline
        self.forwardMessages = forwardMessages
        self.sync = sync
        self.telemetry = telemetry
        self.databaseWorkAdmission = databaseWorkAdmission
        self.controlWriteAdmissionEnabled = controlWriteAdmissionEnabled
        self.maximumGroupEventPagePayloadBytes = maximumGroupEventPagePayloadBytes
        self.now = now
        self.monotonicNow = monotonicNow
    }

    init(
        sendMessage: V2SendMessageService,
        membershipHandler: any V2GatewayRoomMembershipHandling,
        withdrawalHandler: any V2GatewayMessageWithdrawalHandling,
        reactionHandler: any V2GatewayMessageReactionHandling,
        editHandler: any V2GatewayMessageEditHandling,
        readReceiptHandler: any V2GatewayReadReceiptHandling,
        liveActivityHandler: any V2GatewayLiveActivityHandling,
        directMessagingHandler: any V2GatewayDirectMessagingHandling,
        groupAudienceImportHandler: any V2GatewayGroupAudienceImportHandling,
        groupEventLogHandler: any V2GatewayGroupEventLogHandling,
        foregroundGroupEventHints: any V2ForegroundGroupEventHintSubmitting,
        membershipDirectoryHandler: any V2GatewayRoomMembershipDirectoryHandling,
        socialRelationshipHandler: any V2GatewaySocialRelationshipHandling,
        moderationHandler: any V2GatewayModerationHandling,
        conversationCapabilitiesHandler: any V2GatewayConversationCapabilitiesHandling,
        groupCapabilitiesHandler: any V2GatewayGroupCapabilitiesHandling,
        groupRolePolicyBaseline: any V2GroupRolePolicyBaselineReading,
        forwardMessagesHandler: any V2GatewayForwardMessagesHandling,
        sync: V2SyncService,
        telemetry: any V2TelemetrySink,
        databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil,
        controlWriteAdmissionEnabled: Bool = false,
        maximumGroupEventPagePayloadBytes: Int = 48 * 1_024,
        now: @escaping @Sendable () -> Date = Date.init,
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        precondition(maximumGroupEventPagePayloadBytes > 0)
        self.sendMessage = sendMessage
        membership = membershipHandler
        withdrawal = withdrawalHandler
        reaction = reactionHandler
        edit = editHandler
        readReceipt = readReceiptHandler
        liveActivity = liveActivityHandler
        directMessaging = directMessagingHandler
        groupAudienceImports = groupAudienceImportHandler
        groupEventLog = groupEventLogHandler
        self.foregroundGroupEventHints = foregroundGroupEventHints
        membershipDirectory = membershipDirectoryHandler
        socialRelationships = socialRelationshipHandler
        moderation = moderationHandler
        conversationCapabilities = conversationCapabilitiesHandler
        groupCapabilities = groupCapabilitiesHandler
        self.groupRolePolicyBaseline = groupRolePolicyBaseline
        forwardMessages = forwardMessagesHandler
        self.sync = sync
        self.telemetry = telemetry
        self.databaseWorkAdmission = databaseWorkAdmission
        self.controlWriteAdmissionEnabled = controlWriteAdmissionEnabled
        self.maximumGroupEventPagePayloadBytes = maximumGroupEventPagePayloadBytes
        self.now = now
        self.monotonicNow = monotonicNow
    }

    public func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        try await handle(
            envelope: envelope,
            identity: identity,
            originatingConnectionID: nil
        )
    }

    public func handle(
        envelope: IMV2Envelope,
        identity: V2AuthenticatedConnection,
        originatingConnectionID: UUID?
    ) async throws -> IMV2Envelope {
        let traceID = V2SecureProcessUUIDGenerator.shared.makeOne()
        let command = v2TelemetryCommand(for: envelope)
        let startedAt = monotonicNow()
        do {
            let response: IMV2Envelope
            if let databaseWorkAdmission,
               let workClass = databaseWorkClass(for: envelope),
               !commandManagesDatabaseAdmission(for: envelope) {
                switch await databaseWorkAdmission.acquire(workClass) {
                case .admitted:
                    break
                case .rejected:
                    response = errorEnvelope(code: "SERVER_BUSY", retryable: true)
                    return await recordAndReturn(
                        response, traceID: traceID, command: command, startedAt: startedAt
                    )
                case .cancelled:
                    throw CancellationError()
                }
                guard !Task.isCancelled else {
                    await databaseWorkAdmission.release(workClass)
                    throw CancellationError()
                }
                do {
                    response = try await handleWithoutTelemetry(
                        envelope: envelope,
                        identity: identity,
                        originatingConnectionID: originatingConnectionID
                    )
                    await databaseWorkAdmission.release(workClass)
                } catch {
                    await databaseWorkAdmission.release(workClass)
                    throw error
                }
            } else {
                response = try await handleWithoutTelemetry(
                    envelope: envelope,
                    identity: identity,
                    originatingConnectionID: originatingConnectionID
                )
            }
            return await recordAndReturn(
                response, traceID: traceID, command: command, startedAt: startedAt
            )
        } catch {
            await telemetry.record(.gatewayCommand(
                traceID: traceID,
                command: command,
                outcome: .failed,
                rejection: nil,
                elapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: monotonicNow())
            ))
            throw error
        }
    }

    func handlePreparedGroupEventPull(
        _ request: IMV2GroupEventPull,
        identity: V2AuthenticatedConnection,
        originatingConnectionID _: UUID?,
        context: V2PreparedGroupEventCommandContext
    ) async throws -> V2PreparedGroupEventGatewayResponse {
        let traceID = V2SecureProcessUUIDGenerator.shared.makeOne()
        var telemetryEnvelope = IMV2Envelope()
        telemetryEnvelope.groupEventPull = request
        let command = v2TelemetryCommand(for: telemetryEnvelope)
        let startedAt = monotonicNow()
        do {
            let result: V2PreparedGroupEventPullResult
            if let databaseWorkAdmission {
                switch await databaseWorkAdmission.acquire(.interactiveRead) {
                case .admitted:
                    break
                case .rejected:
                    let response = errorEnvelope(code: "SERVER_BUSY", retryable: true)
                    return .envelope(await recordAndReturn(
                        response,
                        traceID: traceID,
                        command: command,
                        startedAt: startedAt
                    ))
                case .cancelled:
                    throw CancellationError()
                }
                guard !Task.isCancelled else {
                    await databaseWorkAdmission.release(.interactiveRead)
                    throw CancellationError()
                }
                do {
                    result = try await pullPreparedGroupEventPage(
                        request,
                        identity: identity,
                        context: context
                    )
                    await databaseWorkAdmission.release(.interactiveRead)
                } catch {
                    await databaseWorkAdmission.release(.interactiveRead)
                    throw error
                }
            } else {
                result = try await pullPreparedGroupEventPage(
                    request,
                    identity: identity,
                    context: context
                )
            }

            switch result {
            case .prepared(let prepared):
                await telemetry.record(.gatewayCommand(
                    traceID: traceID,
                    command: command,
                    outcome: .accepted,
                    rejection: nil,
                    elapsedMilliseconds:
                        v2ElapsedMilliseconds(since: startedAt, now: monotonicNow())
                ))
                return .prepared(prepared)
            case .page(let page):
                return .envelope(await recordAndReturn(
                    groupEventPageEnvelope(page),
                    traceID: traceID,
                    command: command,
                    startedAt: startedAt
                ))
            case .eventTooLarge:
                return .envelope(await recordAndReturn(
                    errorEnvelope(code: "GROUP_EVENT_TOO_LARGE", retryable: false),
                    traceID: traceID,
                    command: command,
                    startedAt: startedAt
                ))
            }
        } catch V2RevisionValidationError.outOfRange, V2CoreError.invalidIdentifier, V2CoreError.invalidPositiveValue,
                V2GroupEventLogError.invalidRequest {
            return .envelope(await recordAndReturn(
                errorEnvelope(code: "INVALID_ARGUMENT", retryable: false),
                traceID: traceID,
                command: command,
                startedAt: startedAt
            ))
        } catch V2GroupEventLogError.actorNotMember {
            return .envelope(await recordAndReturn(
                errorEnvelope(code: "FORBIDDEN", retryable: false),
                traceID: traceID,
                command: command,
                startedAt: startedAt
            ))
        } catch V2GroupEventLogError.roomNotFound {
            return .envelope(await recordAndReturn(
                errorEnvelope(code: "NOT_FOUND", retryable: false),
                traceID: traceID,
                command: command,
                startedAt: startedAt
            ))
        } catch V2GroupEventLogError.corruptPersistenceState {
            return .envelope(await recordAndReturn(
                errorEnvelope(code: "UNAVAILABLE", retryable: true),
                traceID: traceID,
                command: command,
                startedAt: startedAt
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error where v2PostgresFailureDisposition(error) != .other {
            return .envelope(await recordAndReturn(
                errorEnvelope(code: "UNAVAILABLE", retryable: true),
                traceID: traceID,
                command: command,
                startedAt: startedAt
            ))
        } catch {
            await telemetry.record(.gatewayCommand(
                traceID: traceID,
                command: command,
                outcome: .failed,
                rejection: nil,
                elapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: monotonicNow())
            ))
            throw error
        }
    }

    private func pullPreparedGroupEventPage(
        _ request: IMV2GroupEventPull,
        identity: V2AuthenticatedConnection,
        context: V2PreparedGroupEventCommandContext
    ) async throws -> V2PreparedGroupEventPullResult {
        try await groupEventLog.pullPrepared(
            roomID: try .init(request.roomID),
            actorUserID: identity.userID,
            afterRoomSequence: request.afterRoomSequence,
            pageSize: Int(request.pageSize),
            context: .init(
                requestID: context.requestID,
                frameVersion: context.frameVersion,
                compression: context.compression,
                maximumUncompressedPayloadBytes:
                    context.maximumUncompressedPayloadBytes,
                compressionThresholdBytes: context.compressionThresholdBytes,
                maximumExpansionRatio: context.maximumExpansionRatio,
                maximumGroupEventPagePayloadBytes:
                    maximumGroupEventPagePayloadBytes,
                cache: context.cache
            )
        )
    }

    private func recordAndReturn(
        _ response: IMV2Envelope,
        traceID: UUID,
        command: V2GatewayTelemetryCommand,
        startedAt: ContinuousClock.Instant
    ) async -> IMV2Envelope {
            let hasProtocolError: Bool
            let rejection: V2GatewayTelemetryRejection?
            if case .error(let error) = response.body {
                hasProtocolError = true
                rejection = .init(protocolCode: error.code)
            } else {
                hasProtocolError = false
                rejection = nil
            }
            await telemetry.record(.gatewayCommand(
                traceID: traceID,
                command: command,
                // A future protocol error may intentionally have no metric
                // label until it is reviewed. It is still a rejection, never
                // an accepted command merely because it is unclassified.
                outcome: hasProtocolError ? .rejected : .accepted,
                rejection: rejection,
                elapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: monotonicNow())
            ))
            return response
    }

    private func databaseWorkClass(
        for envelope: IMV2Envelope
    ) -> V2DatabaseWorkClass? {
        guard envelope.body != nil else { return nil }
        switch envelope.body {
        case .syncPull, .syncAck, .syncSnapshot, .snapshotPagePull, .snapshotAck:
            return .sync
        case .openDirectRoom where controlWriteAdmissionEnabled:
            // Opening a relationship/room is a durable control-plane write,
            // not an event append. It must never exhaust the reservation used
            // by sends in conversations that are already open.
            return .foregroundControlWrite
        case .getGroupRolePolicyBaseline,
             .listRoomMembers,
             .groupEventPull,
             .groupEventSubscribe,
             .listReadReceiptReaders,
             .getLiveActivityPreferences,
             .subscribePresence,
             .subscribeTyping:
            // These commands authoritatively read persisted state, but they
            // never mutate it. Keep their bounded waiting separate from
            // writes so an active room-log catch-up cannot starve message
            // acceptance. Authorization remains in each domain service.
            return .interactiveRead
        case .groupEventUnsubscribe, .unsubscribePresence, .unsubscribeTyping:
            // These commands only release process-local subscription state or
            // return a static success envelope. They must remain available to
            // shed resources while PostgreSQL is overloaded.
            return nil
        default:
            return .foregroundWrite
        }
    }

    private func commandManagesDatabaseAdmission(for envelope: IMV2Envelope) -> Bool {
        switch envelope.body {
        case .sendMessage:
            return sendMessage.managesForegroundWriteAdmission
        case .recordReadReceipt:
            return readReceipt.managesForegroundWriteAdmission
        default:
            return false
        }
    }

    private func handleWithoutTelemetry(
        envelope: IMV2Envelope,
        identity: V2AuthenticatedConnection,
        originatingConnectionID: UUID?
    ) async throws -> IMV2Envelope {
        do {
            switch envelope.body {
            case .sendMessage(let request):
                return try await handleSend(
                    request,
                    identity: identity,
                    originatingConnectionID: originatingConnectionID
                )
            case .changeRoomMembership(let request): return try await handleMembership(request, identity: identity)
            case .withdrawMessage(let request): return try await handleWithdrawal(request, identity: identity)
            case .changeMessageReaction(let request): return try await handleReaction(request, identity: identity)
            case .editMessage(let request): return try await handleEdit(request, identity: identity)
            case .recordReadReceipt(let request): return try await handleReadReceipt(request, identity: identity)
            case .openDirectRoom(let request): return try await handleOpenDirectRoom(request, identity: identity)
            case .beginGroupRoomCreation(let request): return try await handleBeginGroupRoomCreation(request, identity: identity)
            case .appendGroupRoomCreationMembers(let request): return try await handleAppendGroupRoomCreationMembers(request, identity: identity)
            case .finalizeGroupRoomCreation(let request): return try await handleFinalizeGroupRoomCreation(request, identity: identity)
            case .cancelGroupRoomCreation(let request): return try await handleCancelGroupRoomCreation(request, identity: identity)
            case .getGroupRolePolicyBaseline(let request): return try await handleGroupRolePolicyBaseline(request, identity: identity)
            case .listRoomMembers(let request): return try await handleListRoomMembers(request, identity: identity)
            case .groupEventPull(let request): return try await handleGroupEventPull(request, identity: identity)
            case .groupEventSubscribe(let request): return try await handleGroupEventSubscribe(request, identity: identity)
            case .groupEventUnsubscribe(let request):
                _ = try RoomID(request.roomID)
                return successEnvelope()
            case .setStrangerMessagePermission(let request): return try await handleStrangerMessagePermission(request, identity: identity)
            case .setUserAddPermission(let request): return try await handleUserAddPermission(request, identity: identity)
            case .setReadReceiptPreferences(let request): return try await handleReadReceiptPreferences(request, identity: identity)
            case .listReadReceiptReaders(let request): return try await handleReadReceiptReaders(request, identity: identity)
            case .setLiveActivityPreferences(let request): return try await handleLiveActivityPreferences(request, identity: identity)
            case .getLiveActivityPreferences: return try await handleGetLiveActivityPreferences(identity: identity)
            case .subscribePresence(let request): return try await handleSubscribePresence(request, identity: identity)
            case .unsubscribePresence(let request):
                _ = try RoomID(request.roomID)
                return successEnvelope()
            case .subscribeTyping(let request): return try await handleSubscribeTyping(request, identity: identity)
            case .unsubscribeTyping(let request):
                _ = try RoomID(request.roomID)
                return successEnvelope()
            case .setTypingState(let request): return try await handleTypingState(request, identity: identity)
            case .changeRelationship(let request): return try await handleRelationship(request, identity: identity)
            case .changeUserBlock(let request): return try await handleUserBlock(request, identity: identity)
            case .moderateMessage(let request): return try await handleModerateMessage(request, identity: identity)
            case .muteMember(let request): return try await handleMuteMember(request, identity: identity)
            case .moderateMemberRemoval(let request): return try await handleModerateMemberRemoval(request, identity: identity)
            case .setConversationState(let request): return try await handleConversationState(request, identity: identity)
            case .setMessageFavorite(let request): return try await handleMessageFavorite(request, identity: identity)
            case .setPinnedMessage(let request): return try await handlePinnedMessage(request, identity: identity)
            case .setGroupAnnouncement(let request): return try await handleGroupAnnouncement(request, identity: identity)
            case .setGroupRolePermissions(let request): return try await handleGroupRolePermissions(request, identity: identity)
            case .changeGroupMemberRole(let request): return try await handleGroupMemberRole(request, identity: identity)
            case .forwardMessages(let request): return try await handleForwardMessages(request, identity: identity)
            case .syncPull(let request): return try await handlePull(request, identity: identity)
            case .syncAck(let request):
                try await sync.acknowledge(userID: identity.userID, deviceID: identity.deviceID, generation: request.generation, highestContiguousSequence: request.highestContiguousSequence, receipt: try .init(request.syncReceipt))
                return successEnvelope()
            case .syncSnapshot(let request): return try await handleSnapshotManifest(request, identity: identity)
            case .snapshotPagePull(let request): return try await handleSnapshotPage(request, identity: identity)
            case .snapshotAck(let request):
                try await sync.acknowledgeSnapshot(userID: identity.userID, deviceID: identity.deviceID, snapshotID: try .init(request.snapshotID), generation: request.generation, baseSequence: request.baseUserSyncSequence, receipt: try .init(request.snapshotReceipt))
                return successEnvelope()
            default: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
            }
        } catch V2GatewayTimestampError.unrepresentable, V2GatewayResponseValueError.invalidCount, V2GroupMessagingValidationError.invalidMemberCount,
                V2AcceptanceIdentifierError.invalidTimestamp {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch V2SyncServiceError.invalidRequest {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        } catch V2ForwardPendingError.pending {
            return errorEnvelope(code: "FORWARD_PENDING", retryable: true, retryAfter: 1)
        } catch V2ForwardPendingError.paused {
            return errorEnvelope(code: "FORWARD_PAUSED", retryable: true, retryAfter: 30)
        } catch V2RoomMembershipDirectoryError.revisionConflict(let currentRevision) {
            return errorEnvelope(code: "REVISION_CONFLICT", retryable: false, currentRevision: currentRevision)
        } catch V2RevisionValidationError.outOfRange, V2CoreError.invalidIdentifier, V2CoreError.invalidPositiveValue, V2SendMessageValidationError.invalidTextLength, V2MediaStoreError.invalidReferenceSet, V2MentionValidationError.invalidLimits, V2MentionValidationError.invalidTargetSet, V2ModerationValidationError.invalidReasonCode, V2ModerationValidationError.invalidActionShape, V2ModerationValidationError.invalidMuteExpiry, V2RoomMembershipValidationError.selfTargetingNotAllowed, V2DirectMessagingValidationError.selfTargetingNotAllowed, V2SocialRelationshipValidationError.selfTargetingNotAllowed, V2MessageReactionValidationError.invalidReaction, V2MessageEditValidationError.invalidText, V2ReadReceiptValidationError.invalidRoomSequence, V2GroupMessagingValidationError.invalidTitle, V2GroupMessagingValidationError.invalidInitialMembers, V2GroupAudienceImportError.invalidInput, V2RoomMembershipDirectoryError.invalidRequest, V2RoomMembershipDirectoryError.invalidCursor, V2GroupEventLogError.invalidRequest {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        } catch V2GroupAudienceImportError.memberLimitReached, V2GroupAudienceImportError.activeDraftLimitReached {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        } catch V2GroupAudienceImportError.missingDraft {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2GroupAudienceImportError.draftFrozen {
            return errorEnvelope(code: "GROUP_CREATION_FROZEN", retryable: false)
        } catch V2GroupAudienceImportError.idempotencyConflict {
            return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        } catch V2GroupAudienceImportError.corruptPersistenceState {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch V2RoomMembershipStoreError.ownerChanged, V2RoomOwnerFenceError.ownerChanged, V2ReadReceiptStoreError.ownerChanged {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch V2RoomMembershipStoreError.actorNotOwner {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2RoomMembershipStoreError.targetUnavailable {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2ConversationCapabilitiesStoreError.invalidTimestamp {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        } catch V2ConversationCapabilitiesStoreError.actorNotMember {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2ConversationCapabilitiesStoreError.roomNotFound, V2ConversationCapabilitiesStoreError.messageNotFound {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2ConversationCapabilitiesStoreError.corruptPersistenceState {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch V2GroupPermissionValidationError.emptyAnnouncement, V2GroupPermissionValidationError.announcementTooLarge, V2GroupPermissionValidationError.ownerPolicyIsImmutable, V2GroupPermissionValidationError.memberRoleCannotBeOwner {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        } catch V2GroupCapabilitiesStoreError.actorNotMember, V2GroupCapabilitiesStoreError.actorNotAuthorized {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2GroupCapabilitiesStoreError.roomNotFound, V2GroupCapabilitiesStoreError.messageNotFound, V2GroupCapabilitiesStoreError.targetNotMember {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2GroupCapabilitiesStoreError.notGroupRoom, V2GroupCapabilitiesStoreError.messageWithdrawn {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        } catch V2GroupCapabilitiesStoreError.corruptPersistenceState {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch V2RoomMembershipDirectoryError.actorNotMember {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2LiveActivityStoreError.actorNotMember, V2LiveActivityStoreError.typingNotAllowed, V2LiveActivityStoreError.interactionBlocked {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2LiveActivityStoreError.notDirectRoom {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        } catch V2LiveActivityStoreError.roomNotFound {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2LiveActivityStoreError.corruptPersistenceState {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch V2GroupEventLogError.actorNotMember {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2SocialRelationshipStoreError.actorInactive {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2SocialRelationshipStoreError.corruptPersistenceState {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch V2RoomWriteStoreError.actorNotEligible, V2RoomWriteStoreError.actorMuted, V2RoomWriteStoreError.roomFrozen, V2RoomWriteStoreError.directMessageBlocked, V2RoomWriteStoreError.strangerMessagePermissionDenied {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2RoomWriteStoreError.roomNotFound, V2RoomWriteStoreError.replyTargetNotFound {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2RoomWriteStoreError.capacityProfileMismatch, V2RoomWriteStoreError.corruptPersistenceState {
            // Capacity profiles are immutable room contracts. A deployment
            // using another profile, or a broken persisted admission
            // invariant, is an operational availability failure—not a wire
            // or authentication failure. Keep the authenticated connection
            // alive and expose only the stable protocol vocabulary.
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch V2MentionValidationError.notAuthorized {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2ModerationAuthorizationError.notAuthorized {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2MediaStoreError.mediaUnavailable, V2MediaStoreError.mediaExpired, V2MediaStoreError.invalidStateTransition {
            return errorEnvelope(code: "MEDIA_UNAVAILABLE", retryable: false)
        } catch V2RoomWriteStoreError.strangerMessageLimitReached {
            return errorEnvelope(code: "RATE_LIMITED", retryable: true)
        } catch V2RoomMembershipStoreError.roomNotFound {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2RoomMembershipDirectoryError.roomNotFound {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2GroupEventLogError.roomNotFound {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2MessageWithdrawalStoreError.roomNotFound, V2MessageWithdrawalStoreError.messageNotFound {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2MessageWithdrawalStoreError.actorNotAuthor {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2ModerationStoreError.roomNotFound, V2ModerationStoreError.messageNotFound {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2ModerationStoreError.actorNotAuthorized {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2ModerationStoreError.unsupportedAction {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch V2MessageEditStoreError.roomNotFound, V2MessageEditStoreError.messageNotFound {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2MessageEditStoreError.actorNotAuthor {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2ReadReceiptStoreError.roomNotFound, V2ReadReceiptStoreError.roomSequenceNotFound {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        } catch V2ReadReceiptStoreError.messageNotFound {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2ReadReceiptStoreError.actorNotMember {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2ReadReceiptStoreError.invalidRequest {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        } catch V2MessageReactionStoreError.roomNotFound, V2MessageReactionStoreError.messageNotFound {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2MessageReactionStoreError.actorNotMember {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2MessageReactionStoreError.messageWithdrawn,
                V2MessageReactionStoreError.reactionLimitReached {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        } catch V2SyncStoreError.invalidOrExpiredSyncToken {
            // A token is only an opaque continuation capability.  Its expiry
            // is not a transport failure: the client can restart its pull
            // from its durable cursor without reconnecting.
            return errorEnvelope(code: "SYNC_TOKEN_INVALID", retryable: false)
        } catch V2SyncStoreError.invalidOrExpiredSyncReceipt {
            // ACK receipts fence an individual pull range.  Do not let a
            // stale receipt advance a cursor, and make the retry path
            // explicit to the client rather than surfacing a store error.
            return errorEnvelope(code: "SYNC_RECEIPT_INVALID", retryable: false)
        } catch V2SyncStoreError.deviceRevoked {
            // The durable shard tombstone can win the race before every
            // replica has closed its already-authenticated socket. Fail the
            // in-flight request without exposing any projection data.
            return errorEnvelope(code: "UNAUTHENTICATED", retryable: false)
        } catch V2SyncStoreError.resetRequired, V2SyncStoreError.generationMismatch {
            return errorEnvelope(code: "RESET_REQUIRED", retryable: false)
        } catch V2SyncStoreError.snapshotExpiredOrInvalid, V2SyncStoreError.snapshotFenceMismatch, V2SyncStoreError.noResetPending {
            return errorEnvelope(code: "RESET_REQUIRED", retryable: false)
        } catch V2SyncStoreError.acknowledgementBeyondWatermark {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        } catch V2SyncStoreError.syncLogSequenceGap, V2SyncStoreError.snapshotCheckpointUnavailable {
            // The server cannot produce a complete sync response yet. Keep
            // the request retryable without issuing partial capabilities or
            // presenting an unassigned snapshot as ready for the client.
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch V2SyncStoreError.syncRecordTooLarge {
            // Persisted state must never force a transport-level disconnect.
            // The non-retryable code also prevents an oversized head record
            // from becoming an infinite client retry loop.
            return errorEnvelope(code: "SYNC_RECORD_TOO_LARGE", retryable: false)
        } catch V2RoomMembershipStoreError.corruptPersistenceState,
                V2MessageWithdrawalStoreError.corruptPersistenceState,
                V2MessageEditStoreError.corruptPersistenceState,
                V2MessageReactionStoreError.corruptPersistenceState,
                V2ModerationStoreError.corruptPersistenceState,
                V2ReadReceiptStoreError.corruptPersistenceState,
                V2DirectMessagingStoreError.corruptPersistenceState,
                V2GroupRoomCreationIntentStoreError.corruptPersistenceState,
                V2GroupMessagingStoreError.corruptPersistenceState {
            // Domain stores use this closed error for failed persistence
            // invariants. None of these failures invalidates an authenticated
            // transport session, and leaking the underlying database shape
            // would expose internal state.
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch is V2ForwardMessageResultValidationError {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error where v2PostgresFailureDisposition(error) != .other {
            // A request-scoped database shortage or an exhausted transaction
            // retry is not a transport failure. Return a sanitized retryable
            // response and keep the authenticated connection alive.
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func handleSend(
        _ request: IMV2SendMessage,
        identity: V2AuthenticatedConnection,
        originatingConnectionID: UUID?
    ) async throws -> IMV2Envelope {
        guard request.hasContent,
              let roomUUID = UUID(uuidString: request.roomID),
              let clientMessageUUID = UUID(uuidString: request.clientMessageID)
        else { return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false) }
        let text: String
        switch request.content.body {
        case .text(let value): text = value
        case nil: text = ""
        }
        let media = try request.content.mediaIds.map { try V2MediaReference(mediaID: .init($0)) }
        var mentions = try request.content.mentionedUserIds.map { try V2MentionTarget.user(.init($0)) }
        if request.content.mentionEveryone { mentions.append(.everyone) }
        let entities = try request.content.entities.map(v2MessageEntity)
        let replyTo = try request.content.replyToMessageID.isEmpty ? nil : V2MessageReplyReference(messageID: .init(request.content.replyToMessageID))
        let outcome: V2SendMessageOutcome
        do {
            outcome = try await sendMessage.send(.init(
                roomID: .init(uuid: roomUUID),
                actorUserID: identity.userID,
                clientMessageID: .init(uuid: clientMessageUUID),
                text: text,
                media: media,
                mentions: mentions,
                entities: entities,
                replyTo: replyTo
            ))
        } catch V2SendMessageAdmissionBatcherError.serverBusy {
            return errorEnvelope(code: "SERVER_BUSY", retryable: true)
        }
        switch outcome {
        case .accepted(let message):
            let response = try acceptedMessageEnvelope(message.receipt)
            if let directEvent = V2DirectRoomLiveEventDraft(
                message,
                excludingConnectionID: originatingConnectionID
            )?.materialized() {
                await groupEventLog.recordCommittedDirectRoomLogEvent(directEvent)
                // Best effort and post-commit only. The dispatcher validates
                // and queues one immutable payload shared with the local
                // room-log acceleration cache.
                foregroundGroupEventHints.submitForegroundDirectEvent(directEvent)
            } else if let groupEventDraft = V2GroupRoomLiveEventDraft(message) {
                // The append batcher invokes its committed observer before
                // resuming this request. In that configuration the observer
                // has already materialized and submitted this exact Hybrid
                // event. Keep the cheap eligibility draft so the richer-event
                // fallback below remains unchanged, but do not JSON-encode a
                // second payload merely to discard it here.
                if !sendMessage.publishesCommittedGroupEvents,
                   let groupEvent = groupEventDraft.materialized() {
                    await groupEventLog.recordCommittedDirectRoomLogEvent(groupEvent)
                    foregroundGroupEventHints.submitForegroundDirectEvent(groupEvent)
                }
            } else if message.groupDeliveryMode != nil || message.usesRoomEventLog {
                await groupEventLog.recordCommittedDirectRoomLogMessage(message)
                foregroundGroupEventHints.submitForegroundHint(.init(
                    roomID: message.roomID,
                    highWatermark: message.roomSequence
                ))
            }
            return response
        case .idempotent(let message):
            return try acceptedMessageEnvelope(message)
        case .denied:
            // The durable, private activity and composer capability are
            // synced separately. Do not disclose which counterpart policy
            // caused this rejection on the realtime response.
            return errorEnvelope(code: "DIRECT_MESSAGE_RESTRICTED", retryable: false)
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func acceptedMessageEnvelope(_ message: V2MessageAcceptanceReceipt) throws -> IMV2Envelope {
            var response = IMV2Envelope(); response.messageAccepted = .init()
            response.messageAccepted.messageID = message.messageID.rawValue
            response.messageAccepted.roomID = message.roomID.rawValue
            response.messageAccepted.roomSequence = message.roomSequence
            response.messageAccepted.serverCreatedAtMs = try v2GatewayMilliseconds(message.createdAt)
            return response
    }

    private func handleMembership(_ request: IMV2ChangeRoomMembership, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let action: V2RoomMembershipAction
        switch request.action {
        case .add: action = .add
        case .remove: action = .remove
        case .unspecified, .UNRECOGNIZED: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        }
        let outcome = try await membership.change(.init(
            roomID: try .init(request.roomID),
            actorUserID: identity.userID,
            operationID: try .init(request.operationID),
            targetUserID: try .init(request.targetUserID),
            action: action,
            expectedMembershipRevision: request.expectedMembershipRevision
        ))
        switch outcome {
        case .changed(let change), .idempotent(let change):
            var response = IMV2Envelope(); response.membershipChanged = .init()
            response.membershipChanged.roomID = change.roomID.rawValue
            response.membershipChanged.targetUserID = change.targetUserID.rawValue
            response.membershipChanged.action = change.action == .add ? .add : .remove
            response.membershipChanged.membershipRevision = change.membershipRevision
            response.membershipChanged.roomSequence = change.roomSequence
            response.membershipChanged.serverCreatedAtMs = try v2GatewayMilliseconds(change.createdAt)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .revisionConflict(let current): return errorEnvelope(code: "REVISION_CONFLICT", retryable: false, currentRevision: current)
        case .targetAlreadyMember, .targetNotMember, .memberLimitReached: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func handleWithdrawal(_ request: IMV2WithdrawMessage, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let outcome = try await withdrawal.withdraw(.init(roomID: try .init(request.roomID), actorUserID: identity.userID, operationID: try .init(request.operationID), messageID: try .init(request.messageID), expectedMessageRevision: request.expectedMessageRevision))
        switch outcome {
        case .withdrawn(let result), .idempotent(let result):
            var response = IMV2Envelope(); response.messageWithdrawn = .init()
            response.messageWithdrawn.roomID = result.roomID.rawValue
            response.messageWithdrawn.messageID = result.messageID.rawValue
            response.messageWithdrawn.messageRevision = result.messageRevision
            response.messageWithdrawn.roomSequence = result.roomSequence
            response.messageWithdrawn.serverCreatedAtMs = try v2GatewayMilliseconds(result.createdAt)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .revisionConflict(let current): return errorEnvelope(code: "REVISION_CONFLICT", retryable: false, currentRevision: current)
        case .alreadyWithdrawn: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func handleModerateMessage(_ request: IMV2ModerateMessage, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let outcome = try await moderation.apply(.init(roomID: try .init(request.roomID), actorUserID: identity.userID, operationID: try .init(request.operationID), action: .redactMessage, messageID: try .init(request.messageID), reasonCode: try .init(request.reasonCode)))
        switch outcome {
        case .applied(let result), .idempotent(let result):
            var response = IMV2Envelope(); response.messageRedacted = .init()
            response.messageRedacted.roomID = result.roomID.rawValue
            guard let messageID = result.messageID, let messageRevision = result.messageRevision else { throw V2ModerationStoreError.corruptPersistenceState }
            response.messageRedacted.messageID = messageID.rawValue
            response.messageRedacted.roomSequence = result.roomSequence
            response.messageRedacted.messageRevision = messageRevision
            response.messageRedacted.serverCreatedAtMs = try v2GatewayMilliseconds(result.createdAt)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .messageAlreadyRedacted, .targetNotMember, .actionAlreadyInDesiredState: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func handleConversationState(_ request: IMV2SetConversationState, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let muteUntil = request.muteUntilMs == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(request.muteUntilMs) / 1_000)
        let command = try V2ConversationStateCommand(operationID: .init(request.operationID), roomID: .init(request.roomID), isPinned: request.isPinned, isArchived: request.isArchived, muteUntil: muteUntil)
        let outcome = try await conversationCapabilities.setConversationState(actorUserID: identity.userID, command: command)
        let value: V2ConversationState
        switch outcome { case .applied(let result), .idempotent(let result): value = result; case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false) }
        var response = IMV2Envelope(); response.conversationStateSet = .init()
        response.conversationStateSet.roomID = value.roomID.rawValue; response.conversationStateSet.isPinned = value.isPinned; response.conversationStateSet.isArchived = value.isArchived
        response.conversationStateSet.muteUntilMs = try value.muteUntil.map { try v2GatewayMilliseconds($0) } ?? 0; response.conversationStateSet.updatedAtMs = try v2GatewayMilliseconds(value.updatedAt)
        return response
    }

    private func handleMessageFavorite(_ request: IMV2SetMessageFavorite, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let command = try V2MessageFavoriteCommand(operationID: .init(request.operationID), roomID: .init(request.roomID), messageID: .init(request.messageID), isFavorited: request.isFavorited)
        let outcome = try await conversationCapabilities.setMessageFavorite(actorUserID: identity.userID, command: command)
        let value: V2MessageFavorite
        switch outcome { case .applied(let result), .idempotent(let result): value = result; case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false) }
        var response = IMV2Envelope(); response.messageFavoriteChanged = .init()
        response.messageFavoriteChanged.roomID = value.roomID.rawValue; response.messageFavoriteChanged.messageID = value.messageID.rawValue; response.messageFavoriteChanged.isFavorited = value.isFavorited; response.messageFavoriteChanged.updatedAtMs = try v2GatewayMilliseconds(value.updatedAt)
        return response
    }

    private func handlePinnedMessage(_ request: IMV2SetPinnedMessage, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let command = V2PinnedMessageCommand(operationID: try .init(request.operationID), roomID: try .init(request.roomID), messageID: try .init(request.messageID), isPinned: request.isPinned)
        let outcome = try await groupCapabilities.setPinnedMessage(actorUserID: identity.userID, command: command)
        let value: V2PinnedMessage
        switch outcome { case .applied(let result), .idempotent(let result): value = result; case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false); case .alreadyInDesiredState: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false); case .revisionConflict: return errorEnvelope(code: "REVISION_CONFLICT", retryable: false); case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds); case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        var response = IMV2Envelope(); response.pinnedMessageChanged = .init()
        response.pinnedMessageChanged.roomID = value.roomID.rawValue; response.pinnedMessageChanged.messageID = value.messageID.rawValue; response.pinnedMessageChanged.isPinned = value.isPinned; response.pinnedMessageChanged.roomSequence = value.roomSequence; response.pinnedMessageChanged.updatedAtMs = try v2GatewayMilliseconds(value.updatedAt)
        return response
    }

    private func handleGroupAnnouncement(_ request: IMV2SetGroupAnnouncement, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let command = try V2GroupAnnouncementCommand(operationID: .init(request.operationID), roomID: .init(request.roomID), body: request.body, expectedRevision: request.expectedRevision)
        let outcome = try await groupCapabilities.setAnnouncement(actorUserID: identity.userID, command: command)
        let value: V2GroupAnnouncement
        switch outcome { case .applied(let result), .idempotent(let result): value = result; case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false); case .revisionConflict: return errorEnvelope(code: "REVISION_CONFLICT", retryable: false); case .alreadyInDesiredState: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false); case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds); case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        var response = IMV2Envelope(); response.groupAnnouncementChanged = .init()
        response.groupAnnouncementChanged.roomID = value.roomID.rawValue; response.groupAnnouncementChanged.body = value.body; response.groupAnnouncementChanged.revision = value.revision; response.groupAnnouncementChanged.roomSequence = value.roomSequence; response.groupAnnouncementChanged.updatedAtMs = try v2GatewayMilliseconds(value.updatedAt)
        return response
    }

    private func handleGroupRolePolicyBaseline(_ request: IMV2GetGroupRolePolicyBaseline, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let roomUUID = UUID(uuidString: request.roomID) else { return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false) }
        let value: V2GroupRolePolicyBaseline
        do {
            value = try await groupRolePolicyBaseline.readRolePolicyBaseline(roomID: .init(uuid: roomUUID), actorUserID: identity.userID)
        } catch V2GroupRolePolicyBaselineError.actorNotMember {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2GroupRolePolicyBaselineError.roomNotFound, V2RoomShardRouteError.roomNotFound {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2RoomShardRouteError.routeConflict {
            return errorEnvelope(code: "ROOM_OWNER_CHANGED", retryable: true, retryAfter: 1)
        } catch V2GroupRolePolicyBaselineError.corruptPersistenceState, V2RoomShardRouteError.corruptPersistenceState, V2RoomShardStorageRegistryError.unknownShardID {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true, retryAfter: 1)
        }
        guard value.roomID == RoomID(uuid: roomUUID) else { return errorEnvelope(code: "UNAVAILABLE", retryable: true, retryAfter: 1) }
        var response = IMV2Envelope()
        response.groupRolePolicyBaseline.roomID = value.roomID.rawValue
        response.groupRolePolicyBaseline.permissionRevision = value.permissionRevision
        response.groupRolePolicyBaseline.membershipRevision = value.membershipRevision
        response.groupRolePolicyBaseline.roomSequence = value.roomSequence
        response.groupRolePolicyBaseline.policies = [(V2RoomMembershipRole.admin, value.adminPermissions), (.member, value.memberPermissions)].map { role, permissions in
            var policy = IMV2GroupRolePolicy()
            policy.role = role.rawValue
            policy.permissions = permissions.sorted { $0.rawValue < $1.rawValue }.map { permission in
                var entry = IMV2GroupRolePermission(); entry.permission = permission.rawValue; return entry
            }
            return policy
        }
        return response
    }

    private func handleGroupRolePermissions(_ request: IMV2SetGroupRolePermissions, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let role = V2RoomMembershipRole(rawValue: request.role) else { return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false) }
        let rawPermissions = request.permissions.map(\.permission)
        let permissions = Set(rawPermissions.compactMap(V2GroupPermission.init(rawValue:)))
        guard permissions.count == rawPermissions.count else { return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false) }
        let command = try V2GroupRolePermissionsCommand(operationID: .init(request.operationID), roomID: .init(request.roomID), role: role, permissions: permissions, expectedRevision: request.expectedRevision)
        let outcome = try await groupCapabilities.setRolePermissions(actorUserID: identity.userID, command: command)
        let value: V2GroupRolePermissionsChange
        switch outcome { case .applied(let result), .idempotent(let result): value = result; case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false); case .revisionConflict: return errorEnvelope(code: "REVISION_CONFLICT", retryable: false); case .alreadyInDesiredState: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false); case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds); case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        var response = IMV2Envelope(); response.groupRolePermissionsChanged = .init()
        response.groupRolePermissionsChanged.roomID = value.roomID.rawValue; response.groupRolePermissionsChanged.role = value.role.rawValue; response.groupRolePermissionsChanged.revision = value.revision; response.groupRolePermissionsChanged.roomSequence = value.roomSequence
        response.groupRolePermissionsChanged.permissions = value.permissions.sorted { $0.rawValue < $1.rawValue }.map { var item = IMV2GroupRolePermission(); item.permission = $0.rawValue; return item }
        return response
    }

    private func handleGroupMemberRole(_ request: IMV2ChangeGroupMemberRole, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let role = V2RoomMembershipRole(rawValue: request.role) else { return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false) }
        let command = try V2GroupMemberRoleCommand(operationID: .init(request.operationID), roomID: .init(request.roomID), targetUserID: .init(request.userID), role: role, expectedMembershipRevision: request.expectedMembershipRevision)
        let outcome = try await groupCapabilities.changeMemberRole(actorUserID: identity.userID, command: command)
        let value: V2GroupMemberRoleChange
        switch outcome { case .applied(let result), .idempotent(let result): value = result; case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false); case .revisionConflict: return errorEnvelope(code: "REVISION_CONFLICT", retryable: false); case .alreadyInDesiredState: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false); case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds); case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        var response = IMV2Envelope(); response.groupMemberRoleChanged = .init()
        response.groupMemberRoleChanged.roomID = value.roomID.rawValue; response.groupMemberRoleChanged.userID = value.targetUserID.rawValue; response.groupMemberRoleChanged.role = value.role.rawValue; response.groupMemberRoleChanged.membershipRevision = value.membershipRevision; response.groupMemberRoleChanged.roomSequence = value.roomSequence
        return response
    }

    private func handleForwardMessages(_ request: IMV2ForwardMessages, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let operation = UUID(uuidString: request.operationID) else { return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false) }
        let command = try V2ForwardMessagesCommand(operationID: .init(uuid: operation), sources: try request.sources.map { try .init(roomID: .init($0.roomID), messageID: .init($0.messageID), revision: .init($0.revision)) }, targetRoomIDs: try request.targetRoomIds.map(RoomID.init))
        let results = try await forwardMessages.forward(actorUserID: identity.userID, command: command)
        guard results.allSatisfy({ result in
            result.roomSequence.map { $0 > 0 && $0 <= UInt64(Int64.max) } ?? true
        }) else { return errorEnvelope(code: "UNAVAILABLE", retryable: true) }
        var response = IMV2Envelope(); response.messagesForwarded = .init()
        response.messagesForwarded.results = results.map { result in
            var wire = IMV2ForwardMessageResult(); wire.sourceMessageID = result.sourceMessageID.rawValue; wire.targetRoomID = result.targetRoomID.rawValue; wire.messageID = result.messageID?.rawValue ?? ""; wire.roomSequence = result.roomSequence ?? 0; wire.errorCode = result.errorCode ?? ""; return wire
        }
        return response
    }

    private func handleMuteMember(_ request: IMV2MuteMember, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard request.muteUntilMs > 0 else { return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false) }
        let outcome = try await moderation.apply(.init(
            roomID: try .init(request.roomID),
            actorUserID: identity.userID,
            operationID: try .init(request.operationID),
            action: .muteMember,
            targetUserID: try .init(request.targetUserID),
            muteUntil: Date(timeIntervalSince1970: TimeInterval(request.muteUntilMs) / 1_000),
            reasonCode: try .init(request.reasonCode)
        ))
        switch outcome {
        case .applied(let result), .idempotent(let result):
            guard result.action == .muteMember, let targetUserID = result.targetUserID,
                  let muteUntil = result.muteUntil
            else { throw V2ModerationStoreError.corruptPersistenceState }
            var response = IMV2Envelope(); response.memberMuted = .init()
            response.memberMuted.roomID = result.roomID.rawValue
            response.memberMuted.targetUserID = targetUserID.rawValue
            response.memberMuted.muteUntilMs = try v2GatewayMilliseconds(muteUntil)
            response.memberMuted.roomSequence = result.roomSequence
            response.memberMuted.serverCreatedAtMs = try v2GatewayMilliseconds(result.createdAt)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .targetNotMember, .messageAlreadyRedacted, .actionAlreadyInDesiredState: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func handleModerateMemberRemoval(_ request: IMV2ModerateMemberRemoval, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let outcome = try await moderation.apply(.init(
            roomID: try .init(request.roomID),
            actorUserID: identity.userID,
            operationID: try .init(request.operationID),
            action: .removeMember,
            targetUserID: try .init(request.targetUserID),
            reasonCode: try .init(request.reasonCode)
        ))
        switch outcome {
        case .applied(let result), .idempotent(let result):
            guard result.action == .removeMember, let targetUserID = result.targetUserID,
                  let membershipRevision = result.membershipRevision
            else { throw V2ModerationStoreError.corruptPersistenceState }
            var response = IMV2Envelope(); response.memberRemovedByModerator = .init()
            response.memberRemovedByModerator.roomID = result.roomID.rawValue
            response.memberRemovedByModerator.targetUserID = targetUserID.rawValue
            response.memberRemovedByModerator.membershipRevision = membershipRevision
            response.memberRemovedByModerator.roomSequence = result.roomSequence
            response.memberRemovedByModerator.serverCreatedAtMs = try v2GatewayMilliseconds(result.createdAt)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .targetNotMember, .messageAlreadyRedacted, .actionAlreadyInDesiredState: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func handleReaction(_ request: IMV2ChangeMessageReaction, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let action: V2MessageReactionAction
        switch request.action {
        case .add: action = .add
        case .remove: action = .remove
        case .unspecified, .UNRECOGNIZED: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        }
        let outcome = try await reaction.change(.init(roomID: try .init(request.roomID), actorUserID: identity.userID, operationID: try .init(request.operationID), messageID: try .init(request.messageID), reaction: request.reaction, action: action))
        switch outcome {
        case .changed(let result), .idempotent(let result):
            var response = IMV2Envelope(); response.messageReactionChanged = .init()
            response.messageReactionChanged.roomID = result.roomID.rawValue
            response.messageReactionChanged.messageID = result.messageID.rawValue
            response.messageReactionChanged.actorUserID = result.actorUserID.rawValue
            response.messageReactionChanged.reaction = result.reaction
            response.messageReactionChanged.action = result.action == .add ? .add : .remove
            response.messageReactionChanged.roomSequence = result.roomSequence
            response.messageReactionChanged.serverCreatedAtMs = try v2GatewayMilliseconds(result.createdAt)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .alreadyInDesiredState: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func handleEdit(_ request: IMV2EditMessage, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard request.hasContent, case .text(let text)? = request.content.body else { return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false) }
        let outcome = try await edit.edit(.init(roomID: try .init(request.roomID), actorUserID: identity.userID, operationID: try .init(request.operationID), messageID: try .init(request.messageID), expectedMessageRevision: request.expectedMessageRevision, text: text))
        switch outcome {
        case .edited(let result), .idempotent(let result):
            var response = IMV2Envelope(); response.messageEdited = .init()
            response.messageEdited.roomID = result.roomID.rawValue
            response.messageEdited.messageID = result.messageID.rawValue
            response.messageEdited.text = result.text
            response.messageEdited.messageRevision = result.messageRevision
            response.messageEdited.roomSequence = result.roomSequence
            response.messageEdited.serverCreatedAtMs = try v2GatewayMilliseconds(result.createdAt)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .revisionConflict(let current): return errorEnvelope(code: "REVISION_CONFLICT", retryable: false, currentRevision: current)
        case .alreadyWithdrawn: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func handleReadReceipt(_ request: IMV2RecordReadReceipt, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let outcome: V2ReadReceiptOutcome
        do {
            outcome = try await readReceipt.record(.init(roomID: try .init(request.roomID), actorUserID: identity.userID, operationID: try .init(request.operationID), readThroughRoomSequence: request.readThroughRoomSequence))
        } catch V2ReadReceiptBatcherError.serverBusy {
            return errorEnvelope(code: "SERVER_BUSY", retryable: true)
        }
        switch outcome {
        case .recorded(let result), .idempotent(let result):
            var response = IMV2Envelope(); response.readReceiptRecorded = .init()
            response.readReceiptRecorded.roomID = result.roomID.rawValue
            response.readReceiptRecorded.userID = result.userID.rawValue
            response.readReceiptRecorded.readThroughRoomSequence = result.readThroughRoomSequence
            response.readReceiptRecorded.recordedAtMs = try v2GatewayMilliseconds(result.recordedAt)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        }
    }

    private func handleOpenDirectRoom(_ request: IMV2OpenDirectRoom, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        switch try await directMessaging.open(actorUserID: identity.userID, operationID: try .init(request.operationID), targetUserID: try .init(request.targetUserID)) {
        case .opened(let room), .idempotent(let room):
            var response = IMV2Envelope(); response.directRoomOpened = .init()
            response.directRoomOpened.roomID = room.roomID.rawValue
            response.directRoomOpened.targetUserID = room.targetUserID.rawValue
            response.directRoomOpened.createdAtMs = try v2GatewayMilliseconds(room.createdAt)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func handleBeginGroupRoomCreation(_ request: IMV2BeginGroupRoomCreation, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let draft = try await groupAudienceImports.begin(actorUserID: identity.userID, operationID: try .init(request.operationID), title: request.title)
        var response = IMV2Envelope(); response.groupRoomCreationPrepared = .init()
        response.groupRoomCreationPrepared.operationID = draft.operationID.rawValue
        response.groupRoomCreationPrepared.title = draft.title
        response.groupRoomCreationPrepared.stagedMemberCount = try v2GatewayCount(draft.stagedMemberCount)
        return response
    }

    private func handleAppendGroupRoomCreationMembers(_ request: IMV2AppendGroupRoomCreationMembers, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let members = try request.memberUserIds.map { try UserID($0) }
        let draft = try await groupAudienceImports.append(actorUserID: identity.userID, operationID: try .init(request.operationID), memberUserIDs: members)
        var response = IMV2Envelope(); response.groupRoomCreationMembersAppended = .init()
        response.groupRoomCreationMembersAppended.operationID = draft.operationID.rawValue
        response.groupRoomCreationMembersAppended.stagedMemberCount = try v2GatewayCount(draft.stagedMemberCount)
        return response
    }

    private func handleFinalizeGroupRoomCreation(_ request: IMV2FinalizeGroupRoomCreation, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let outcome = try await groupAudienceImports.finalize(actorUserID: identity.userID, operationID: try .init(request.operationID))
        switch outcome {
        case .created(let room), .idempotent(let room):
            return try groupRoomCreatedEnvelope(room)
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .invalidMembers: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        case .memberLimitReached: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        case .rateLimited(let seconds): return errorEnvelope(code: "RATE_LIMITED", retryable: true, retryAfter: seconds)
        case .unavailable: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func handleCancelGroupRoomCreation(_ request: IMV2CancelGroupRoomCreation, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let operationID = try GroupRoomOperationID(request.operationID)
        try await groupAudienceImports.cancel(actorUserID: identity.userID, operationID: operationID)
        var response = IMV2Envelope(); response.groupRoomCreationCancelled = .init()
        response.groupRoomCreationCancelled.operationID = operationID.rawValue
        return response
    }

    private func groupRoomCreatedEnvelope(_ room: V2GroupRoom) throws -> IMV2Envelope {
        var response = IMV2Envelope(); response.groupRoomCreated = .init()
        response.groupRoomCreated.roomID = room.roomID.rawValue
        response.groupRoomCreated.title = room.title
        response.groupRoomCreated.createdAtMs = try v2GatewayMilliseconds(room.createdAt)
        response.groupRoomCreated.deliveryMode = room.deliveryMode == .standardFanout ? .standardFanout : .largeGroupHybrid
        response.groupRoomCreated.memberCount = try v2GatewayCount(room.memberCount)
        return response
    }

    private func handleListRoomMembers(_ request: IMV2ListRoomMembers, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let page = try await membershipDirectory.list(.init(
            roomID: try .init(request.roomID),
            actorUserID: identity.userID,
            cursor: request.cursor.isEmpty ? nil : request.cursor,
            pageSize: Int(request.pageSize)
        ))
        var response = IMV2Envelope(); response.roomMembersPage = .init()
        response.roomMembersPage.roomID = page.roomID.rawValue
        response.roomMembersPage.membershipRevision = page.membershipRevision
        response.roomMembersPage.nextCursor = page.nextCursor ?? ""
        switch page.actorRole {
        case .owner: response.roomMembersPage.actorRole = .owner
        case .admin: response.roomMembersPage.actorRole = .admin
        case .member: response.roomMembersPage.actorRole = .member
        }
        response.roomMembersPage.members = page.entries.map { entry in
            var member = IMV2RoomMember()
            member.userID = entry.userID.rawValue
            switch entry.role {
            case .owner: member.role = .owner
            case .admin: member.role = .admin
            case .member: member.role = .member
            }
            member.publicHandle = entry.publicIdentity.handle.rawValue
            member.displayName = entry.publicIdentity.displayName
            member.accountKind = entry.publicIdentity.accountKind.rawValue
            return member
        }
        return response
    }

    private func handleGroupEventPull(_ request: IMV2GroupEventPull, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let page = try await groupEventLog.pull(
            roomID: try .init(request.roomID),
            actorUserID: identity.userID,
            afterRoomSequence: request.afterRoomSequence,
            pageSize: Int(request.pageSize)
        )
        return groupEventPageEnvelope(page)
    }

    /// Maps the durable fallback through the exact same payload-budget rules
    /// as the ordinary group-event command. The prepared-page fast path calls
    /// this only when local immutable coverage is unavailable or the fresh
    /// membership fence cannot authorize the cached page.
    private func groupEventPageEnvelope(_ page: V2GroupEventLogPage) -> IMV2Envelope {
        var response = IMV2Envelope()
        // Use the largest possible request ID to make this sizing an upper
        // bound. `V2GatewaySession` replaces it with the actual request ID
        // immediately before final protobuf encoding.
        response.requestID = .max
        response.protocolVersion = IMV2ProtocolVersion.current
        response.groupEventPage = .init()
        response.groupEventPage.roomID = page.roomID.rawValue
        var eventFieldBytes = 0
        var wireEvents: [IMV2GroupEvent] = []
        wireEvents.reserveCapacity(page.events.count)
        var nextRoomSequence = page.nextRoomSequence
        var hasMore = page.hasMore
        for (index, entry) in page.events.enumerated() {
            let candidateEventFieldBytes = eventFieldBytes + v2GroupEventRepeatedFieldBytes(entry)
            let candidateHasMore = page.hasMore || index < page.events.endIndex - 1
            guard v2GroupEventPageEnvelopeBytes(
                roomID: page.roomID.rawValue,
                eventFieldBytes: candidateEventFieldBytes,
                nextRoomSequence: entry.roomSequence,
                hasMore: candidateHasMore
            ) <= maximumGroupEventPagePayloadBytes else {
                break
            }

            var event = IMV2GroupEvent()
            event.sourceEventID = entry.sourceEventID.rawValue
            event.roomSequence = entry.roomSequence
            event.projectionKind = entry.projectionKind
            event.payload = entry.payload
            wireEvents.append(event)
            nextRoomSequence = entry.roomSequence
            hasMore = candidateHasMore
            eventFieldBytes = candidateEventFieldBytes
        }
        guard !wireEvents.isEmpty || page.events.isEmpty else {
            // A durable event must not be able to force a transport close. A
            // client cannot recover by repeating the same cursor, so make the
            // persisted incompatibility explicit and retain the connection.
            return errorEnvelope(code: "GROUP_EVENT_TOO_LARGE", retryable: false)
        }

        response.groupEventPage.events = wireEvents
        response.groupEventPage.nextRoomSequence = nextRoomSequence
        response.groupEventPage.hasMore_p = hasMore

        // The estimator is exact for the current schema and already uses the
        // largest possible request ID. Do not serialize the whole page here:
        // `V2GatewaySession` performs the authoritative protobuf encode once
        // after substituting the real request ID. Payload-budget tests encode
        // that final frame and protect this estimator when the proto evolves.
        return response
    }

    private func handleGroupEventSubscribe(_ request: IMV2GroupEventSubscribe, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let subscription = try await groupEventLog.subscribe(
            roomID: try .init(request.roomID),
            actorUserID: identity.userID
        )
        var response = IMV2Envelope()
        response.groupEventSubscribed = .init()
        response.groupEventSubscribed.roomID = subscription.roomID.rawValue
        response.groupEventSubscribed.highWatermark = subscription.highWatermark
        response.groupEventSubscribed.membershipRevision = subscription.membershipRevision
        return response
    }

    private func handleStrangerMessagePermission(_ request: IMV2SetStrangerMessagePermission, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let permission: V2StrangerMessagePermission
        switch request.permission {
        case .allow: permission = .allow
        case .deny: permission = .deny
        case .unspecified, .UNRECOGNIZED: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        }
        switch try await directMessaging.setStrangerMessagePermission(actorUserID: identity.userID, operationID: try .init(request.operationID), permission: permission) {
        case .updated(let result, let updatedAt), .idempotent(let result, let updatedAt):
            var response = IMV2Envelope(); response.strangerMessagePermissionSet = .init()
            response.strangerMessagePermissionSet.permission = result == .allow ? .allow : .deny
            response.strangerMessagePermissionSet.updatedAtMs = try v2GatewayMilliseconds(updatedAt)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        }
    }

    private func handleUserAddPermission(_ request: IMV2SetUserAddPermission, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let permission: V2UserAddPermission
        switch request.permission {
        case .allow: permission = .allow
        case .deny: permission = .deny
        case .unspecified, .UNRECOGNIZED: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        }
        switch try await directMessaging.setUserAddPermission(actorUserID: identity.userID, operationID: try .init(request.operationID), permission: permission) {
        case .updated(let result, let updatedAt), .idempotent(let result, let updatedAt):
            var response = IMV2Envelope(); response.userAddPermissionSet = .init()
            response.userAddPermissionSet.permission = result == .allow ? .allow : .deny
            response.userAddPermissionSet.updatedAtMs = try v2GatewayMilliseconds(updatedAt)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        }
    }

    private func handleReadReceiptPreferences(_ request: IMV2SetReadReceiptPreferences, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        switch try await readReceipt.setPreferences(actorUserID: identity.userID, operationID: try .init(request.operationID), allowsDirectReadReceipts: request.allowsDirectReadReceipts, allowsGroupReadReceipts: request.allowsGroupReadReceipts) {
        case .updated(let preferences), .idempotent(let preferences):
            var response = IMV2Envelope(); response.readReceiptPreferencesSet = .init()
            response.readReceiptPreferencesSet.allowsDirectReadReceipts = preferences.allowsDirectReadReceipts
            response.readReceiptPreferencesSet.allowsGroupReadReceipts = preferences.allowsGroupReadReceipts
            response.readReceiptPreferencesSet.updatedAtMs = try v2GatewayMilliseconds(preferences.updatedAt)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        }
    }

    private func handleReadReceiptReaders(_ request: IMV2ListReadReceiptReaders, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard request.pageSize > 0, request.pageSize <= 100 else { return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false) }
        let page = try await readReceipt.readers(
            roomID: try .init(request.roomID),
            messageID: try .init(request.messageID),
            actorUserID: identity.userID,
            cursor: request.cursor.isEmpty ? nil : request.cursor,
            pageSize: Int(request.pageSize)
        )
        var response = IMV2Envelope(); response.readReceiptReadersPage = .init()
        response.readReceiptReadersPage.roomID = page.roomID.rawValue
        response.readReceiptReadersPage.messageID = page.messageID.rawValue
        response.readReceiptReadersPage.nextCursor = page.nextCursor ?? ""
        response.readReceiptReadersPage.readers = page.readers.map { reader in
            var wire = IMV2ReadReceiptReader(); wire.userID = reader.userID.rawValue
            wire.publicHandle = reader.publicIdentity.handle.rawValue
            wire.displayName = reader.publicIdentity.displayName
            wire.accountKind = reader.publicIdentity.accountKind.rawValue
            return wire
        }
        return response
    }

    private func handleLiveActivityPreferences(_ request: IMV2SetLiveActivityPreferences, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        switch try await liveActivity.setPreferences(.init(actorUserID: identity.userID, operationID: try .init(request.operationID), allowsOnlinePresence: request.allowsOnlinePresence, allowsTypingIndicators: request.allowsTypingIndicators), now: now()) {
        case .updated(let preferences), .idempotent(let preferences):
            var response = IMV2Envelope(); response.liveActivityPreferencesSet = .init()
            response.liveActivityPreferencesSet.allowsOnlinePresence = preferences.allowsOnlinePresence
            response.liveActivityPreferencesSet.allowsTypingIndicators = preferences.allowsTypingIndicators
            response.liveActivityPreferencesSet.updatedAtMs = try v2GatewayMilliseconds(preferences.updatedAt)
            return response
        case .idempotencyConflict:
            return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        }
    }

    private func handleGetLiveActivityPreferences(identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let preferences = try await liveActivity.preferences(userID: identity.userID, now: now())
        var response = IMV2Envelope(); response.liveActivityPreferences = .init()
        response.liveActivityPreferences.allowsOnlinePresence = preferences.allowsOnlinePresence
        response.liveActivityPreferences.allowsTypingIndicators = preferences.allowsTypingIndicators
        response.liveActivityPreferences.updatedAtMs = try v2GatewayMilliseconds(preferences.updatedAt)
        return response
    }

    private func handleSubscribePresence(_ request: IMV2SubscribePresence, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let presence = try await liveActivity.presence(roomID: .init(request.roomID), viewerUserID: identity.userID, now: now())
        var response = IMV2Envelope(); response.presenceSubscribed = .init()
        response.presenceSubscribed.roomID = presence.roomID.rawValue
        response.presenceSubscribed.targetUserID = presence.targetUserID.rawValue
        response.presenceSubscribed.isOnline = presence.isOnline
        response.presenceSubscribed.expiresAtMs = try v2GatewayMilliseconds(presence.expiresAt)
        return response
    }

    private func handleSubscribeTyping(_ request: IMV2SubscribeTyping, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        try await liveActivity.authorizeTyping(roomID: .init(request.roomID), actorUserID: identity.userID, now: now())
        return successEnvelope()
    }

    private func handleTypingState(_ request: IMV2SetTypingState, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        try await liveActivity.authorizeTyping(roomID: .init(request.roomID), actorUserID: identity.userID, now: now())
        return successEnvelope()
    }

    private func handleRelationship(_ request: IMV2ChangeRelationship, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let action: V2RelationshipAction
        switch request.action {
        case .request: action = .request
        case .accept: action = .accept
        case .reject: action = .reject
        case .remove: action = .remove
        case .unspecified, .UNRECOGNIZED: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        }
        switch try await socialRelationships.changeRelationship(actorUserID: identity.userID, operationID: try .init(request.operationID), targetUserID: try .init(request.targetUserID), action: action) {
        case .changed(let change), .idempotent(let change):
            var response = IMV2Envelope(); response.relationshipChanged = .init()
            response.relationshipChanged.targetUserID = change.targetUserID.rawValue
            response.relationshipChanged.action = switch change.action { case .request: .request; case .accept: .accept; case .reject: .reject; case .remove: .remove }
            response.relationshipChanged.resultingState = switch change.resultingState { case .none: .none; case .pending: .pending; case .accepted: .accepted }
            response.relationshipChanged.updatedAtMs = try v2GatewayMilliseconds(change.updatedAt)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        case .invalidState: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        case .forbidden: return errorEnvelope(code: "FORBIDDEN", retryable: false)
        }
    }

    private func handleUserBlock(_ request: IMV2ChangeUserBlock, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let action: V2UserBlockAction
        switch request.action {
        case .block: action = .block
        case .unblock: action = .unblock
        case .unspecified, .UNRECOGNIZED: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        }
        switch try await socialRelationships.changeUserBlock(actorUserID: identity.userID, operationID: try .init(request.operationID), targetUserID: try .init(request.targetUserID), action: action) {
        case .changed(let change), .idempotent(let change):
            var response = IMV2Envelope(); response.userBlockChanged = .init()
            response.userBlockChanged.targetUserID = change.targetUserID.rawValue
            response.userBlockChanged.action = change.action == .block ? .block : .unblock
            response.userBlockChanged.isBlocked = change.isBlocked
            response.userBlockChanged.updatedAtMs = try v2GatewayMilliseconds(change.updatedAt)
            return response
        case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        }
    }

    private func handlePull(_ request: IMV2SyncPull, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let token = request.syncToken.isEmpty ? nil : try V2SyncToken(request.syncToken)
        switch try await sync.pull(userID: identity.userID, deviceID: identity.deviceID, syncToken: token, requestedMaxRecords: Int(request.maxRecords), requireSnapshot: request.requireSnapshot) {
        case .ready(let generation, let records, let nextToken, let receipt, let hasMore):
            var response = IMV2Envelope(); response.syncBatch = .init(); response.syncBatch.generation = generation
            response.syncBatch.records = records.map { record in var value = IMV2SyncRecord(); value.userSyncSequence = record.sequence; value.sourceEventID = record.sourceEventID.rawValue; value.projectionKind = record.projectionKind; value.payload = Data(record.payloadJSON.utf8); return value }
            response.syncBatch.nextSyncToken = nextToken.rawValue; response.syncBatch.syncReceipt = receipt.rawValue; response.syncBatch.hasMore_p = hasMore; response.syncBatch.capabilityProfile = identity.capabilityProfile
            return response
        case .resetRequired(let snapshotID, let generation, let base, let expiry):
            var response = IMV2Envelope(); response.resetRequired = .init(); response.resetRequired.snapshotID = snapshotID.rawValue; response.resetRequired.generation = generation; response.resetRequired.baseUserSyncSequence = base; response.resetRequired.expiresAtMs = try v2GatewayMilliseconds(expiry)
            return response
        case .resetPreparing(_, _, let retryAfter):
            // The wire carries whole seconds. Round up so clients do not
            // retry before the store's requested interval has elapsed.
            guard retryAfter >= 0,
                  let seconds = UInt32(exactly: retryAfter.rounded(.up)) else {
                return errorEnvelope(code: "UNAVAILABLE", retryable: true)
            }
            return errorEnvelope(code: "RESET_PREPARING", retryable: true, retryAfter: Int(seconds))
        }
    }

    private func handleSnapshotManifest(_ request: IMV2SyncSnapshot, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let manifest = try await sync.fetchSnapshotManifest(userID: identity.userID, deviceID: identity.deviceID, snapshotID: try .init(request.snapshotID), generation: request.generation)
        guard manifest.capabilityProfile == identity.capabilityProfile else {
            return errorEnvelope(code: "UPGRADE_REQUIRED", retryable: false)
        }
        var response = IMV2Envelope()
        response.snapshotManifest = .init()
        response.snapshotManifest.snapshotID = manifest.snapshotID.rawValue
        response.snapshotManifest.generation = manifest.generation
        response.snapshotManifest.baseUserSyncSequence = manifest.baseSequence
        response.snapshotManifest.rootDigest = manifest.rootDigest
        response.snapshotManifest.schemaVersion = manifest.schemaVersion
        response.snapshotManifest.capabilityProfile = manifest.capabilityProfile
        response.snapshotManifest.pageCount = manifest.pageCount
        response.snapshotManifest.totalItems = manifest.totalItems
        response.snapshotManifest.totalBytes = manifest.totalBytes
        response.snapshotManifest.nextSyncToken = manifest.nextSyncToken.rawValue
        response.snapshotManifest.syncReceipt = manifest.receipt.rawValue
        response.snapshotManifest.expiresAtMs = try v2GatewayMilliseconds(manifest.expiresAt)
        return response
    }

    private func handleSnapshotPage(_ request: IMV2SnapshotPagePull, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let page = try await sync.fetchSnapshotPage(userID: identity.userID, deviceID: identity.deviceID, snapshotID: try .init(request.snapshotID), generation: request.generation, rootDigest: request.rootDigest, index: request.pageIndex)
        var response = IMV2Envelope()
        response.snapshotPage = .init()
        response.snapshotPage.snapshotID = page.snapshotID.rawValue
        response.snapshotPage.generation = page.generation
        response.snapshotPage.rootDigest = page.rootDigest
        response.snapshotPage.pageIndex = page.index
        response.snapshotPage.firstProjectionKind = page.firstKey.projectionKind
        response.snapshotPage.firstEntityKey = page.firstKey.entityKey
        response.snapshotPage.lastProjectionKind = page.lastKey.projectionKind
        response.snapshotPage.lastEntityKey = page.lastKey.entityKey
        response.snapshotPage.itemCount = page.itemCount
        response.snapshotPage.pageDigest = page.digest
        response.snapshotPage.payload = page.payload
        return response
    }

    private func successEnvelope() -> IMV2Envelope { var response = IMV2Envelope(); response.acknowledged = .init(); return response }
    private func errorEnvelope(code: String, retryable: Bool, retryAfter: Int = 0, currentRevision: UInt64 = 0) -> IMV2Envelope {
        var response = IMV2Envelope()
        response.error = .init()
        guard let seconds = UInt32(exactly: retryAfter), currentRevision <= UInt64(Int64.max) else {
            // Invalid domain response values indicate a server failure. Do not
            // truncate a delay or send a revision that cannot be persisted.
            response.error.code = "UNAVAILABLE"
            response.error.retryable = true
            return response
        }
        response.error.code = code
        response.error.retryable = retryable
        response.error.retryAfterSeconds = seconds
        response.error.currentRevision = currentRevision
        return response
    }
}

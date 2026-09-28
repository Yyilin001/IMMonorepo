import Foundation
import IMV2ActorContracts
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

/// 网关 `GroupEventPage` 信封的精确 protobuf 载荷字节数。
///
/// 早期实现每追加一条事件就整体序列化一次候选页面，使满页场景在 protobuf 计算与临时分配上
/// 都退化为二次复杂度。把估算函数放在线路映射旁边，使大小栅栏保持线性，
/// 同时最终网关编码仍是权威结果。
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










protocol V2GatewayReadReceiptHandling: Sendable {
    var managesForegroundWriteAdmission: Bool { get }
    func record(_ request: V2AuthenticatedReadReceipt) async throws -> V2ReadReceiptOutcome
    func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID, cursor: String?, pageSize: Int) async throws -> V2ReadReceiptReadersPage
}

protocol V2GatewayMessageSendOperationHandling: Sendable {
    var managesForegroundWriteAdmission: Bool { get }
    func sendOperation(_ command: V2MessageSendOperationCommand) async throws -> V2MessageSendOperationRecoveryResult
    func recoverSendOperation(_ request: V2MessageSendOperationRecoveryRequest) async throws -> V2MessageSendOperationRecoveryResult
}

extension V2RoomRefMessagingClient: V2GatewayMessageSendOperationHandling {}

extension V2GatewayReadReceiptHandling {
    var managesForegroundWriteAdmission: Bool { false }
}

protocol V2GatewayLiveActivityHandling: Sendable {
    func preferences(userID: UserID, now: Date) async throws -> V2LiveActivityPreferences
    func presence(roomID: RoomID, viewerUserID: UserID, now: Date) async throws -> V2PresenceState
    func authorizeTyping(roomID: RoomID, actorUserID: UserID, now: Date) async throws
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



public protocol V2GatewayConversationCapabilitiesHandling: Sendable {
    func setConversationState(actorUserID: UserID, command: V2ConversationStateCommand) async throws -> V2PersonalPreferenceReceipt
    func setMessageFavorite(actorUserID: UserID, command: V2MessageFavoriteCommand) async throws -> V2PersonalPreferenceReceipt
}


extension V2ReadReceiptService: V2GatewayReadReceiptHandling {}
extension V2LiveActivityService: V2GatewayLiveActivityHandling {}
extension V2GroupEventLogService: V2GatewayGroupEventLogHandling {}
extension V2RoomMembershipDirectoryService: V2GatewayRoomMembershipDirectoryHandling {}
extension V2ConversationCapabilitiesService: V2GatewayConversationCapabilitiesHandling {}

/// 把已校验的已认证 protobuf 命令路由到 V2 领域服务。
public struct V2GatewayDomainCommandHandler:
    V2GatewayCommandHandler,
    V2PreparedGroupEventCommandHandling {
    private let readReceipt: any V2GatewayReadReceiptHandling
    private let messageSendOperations: any V2GatewayMessageSendOperationHandling
    private let messageLimits: V2MessageCommandLimits
    private let liveActivity: any V2GatewayLiveActivityHandling
    private let groupEventLog: any V2GatewayGroupEventLogHandling
    private let foregroundGroupEventHints: any V2ForegroundGroupEventHintSubmitting
    private let membershipDirectory: any V2GatewayRoomMembershipDirectoryHandling
    private let accountChanges: any V2AccountRoomChangesStarting
    private let roomRecovery: any V2RoomRecoveryCommandHandling
    private let conversationCapabilities: any V2GatewayConversationCapabilitiesHandling
    private let groupRolePolicyBaseline: any V2GroupRolePolicyBaselineReading
    private let sync: V2SyncService
    private let telemetry: any V2TelemetrySink
    private let databaseWorkAdmission: V2DatabaseWorkAdmissionController?
    private let roomCommandsHostAdmitted: Bool
    private let controlWriteAdmissionEnabled: Bool
    /// 房间日志分页与其信封头共享普通网关帧的载荷预算。
    ///
    /// 最终线路编码器仍是权威；该预算用于避免一份合法但较长的持久化积压
    /// 在抵达该边界之前就被当作传输错误断开连接。
    private let maximumGroupEventPagePayloadBytes: Int
    private let now: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant

    /// 生产环境中现有房间调用和创建房间前操作的组合入口。
    /// 用户服务与控制服务保持显式依赖，避免房间能力意外成为用户自有操作的授权依据。
    public init(roomActors: V2GatewayRoomActorServices,
                messageLimits: V2MessageCommandLimits = try! .init(maxUTF8Bytes: 65_536),
                liveActivity: V2LiveActivityService,
                foregroundGroupEventHints: any V2ForegroundGroupEventHintSubmitting,
                roomRecovery: any V2RoomRecoveryCommandHandling,
                accountChanges: any V2AccountRoomChangesStarting,
                conversationCapabilities: any V2GatewayConversationCapabilitiesHandling,
                sync: V2SyncService,
                telemetry: any V2TelemetrySink,
                databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil,
                controlWriteAdmissionEnabled: Bool = false,
                maximumGroupEventPagePayloadBytes: Int = 48 * 1_024,
                now: @escaping @Sendable () -> Date = Date.init,
                monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.init(readReceiptHandler: roomActors.receipts,
                  messageSendOperations: roomActors.messaging,
                  messageLimits: messageLimits,
                  liveActivityHandler: liveActivity,
                  groupEventLogHandler: roomActors.eventLog,
                  foregroundGroupEventHints: foregroundGroupEventHints,
                  membershipDirectoryHandler: roomActors.queries,
                  roomRecovery: roomRecovery,
                  accountChanges: accountChanges,
                  conversationCapabilitiesHandler: conversationCapabilities,
                  groupRolePolicyBaseline: roomActors.queries,
                  sync: sync, telemetry: telemetry,
                  databaseWorkAdmission: databaseWorkAdmission,
                  roomCommandsHostAdmitted: true,
                  controlWriteAdmissionEnabled: controlWriteAdmissionEnabled,
                  maximumGroupEventPagePayloadBytes: maximumGroupEventPagePayloadBytes,
                  now: now, monotonicNow: monotonicNow)
    }

    init(
        readReceiptHandler: any V2GatewayReadReceiptHandling,
        messageSendOperations: any V2GatewayMessageSendOperationHandling,
        messageLimits: V2MessageCommandLimits = try! .init(maxUTF8Bytes: 65_536),
        liveActivityHandler: any V2GatewayLiveActivityHandling,
        groupEventLogHandler: any V2GatewayGroupEventLogHandling,
        foregroundGroupEventHints: any V2ForegroundGroupEventHintSubmitting,
        membershipDirectoryHandler: any V2GatewayRoomMembershipDirectoryHandling,
        roomRecovery: any V2RoomRecoveryCommandHandling,
        accountChanges: any V2AccountRoomChangesStarting,
        conversationCapabilitiesHandler: any V2GatewayConversationCapabilitiesHandling,
        groupRolePolicyBaseline: any V2GroupRolePolicyBaselineReading,
        sync: V2SyncService,
        telemetry: any V2TelemetrySink,
        databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil,
        roomCommandsHostAdmitted: Bool = false,
        controlWriteAdmissionEnabled: Bool = false,
        maximumGroupEventPagePayloadBytes: Int = 48 * 1_024,
        now: @escaping @Sendable () -> Date = Date.init,
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        precondition(maximumGroupEventPagePayloadBytes > 0)
        readReceipt = readReceiptHandler
        self.messageSendOperations = messageSendOperations
        self.messageLimits = messageLimits
        liveActivity = liveActivityHandler
        groupEventLog = groupEventLogHandler
        self.foregroundGroupEventHints = foregroundGroupEventHints
        membershipDirectory = membershipDirectoryHandler
        self.roomRecovery = roomRecovery
        self.accountChanges = accountChanges
        conversationCapabilities = conversationCapabilitiesHandler
        self.groupRolePolicyBaseline = groupRolePolicyBaseline
        self.sync = sync
        self.telemetry = telemetry
        self.databaseWorkAdmission = databaseWorkAdmission
        self.roomCommandsHostAdmitted = roomCommandsHostAdmitted
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
            if let databaseWorkAdmission, !roomCommandsHostAdmitted {
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
                cache: context.cache,
                captureAuthorSample: context.captureAuthorSample
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
                // 新增的协议错误在完成审核前可能有意不设置指标标签。
                // 即使尚未分类，它仍表示拒绝，不能被当作已接受的命令。
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
        case .getGroupRolePolicyBaseline,
             .listRoomMembers,
             .userRoomDirectoryList,
             .roomSyncStateBatch,
             .roomLatestVisibleBatch,
             .groupEventPull,
             .groupEventSubscribe,
             .listReadReceiptReaders,
             .getLiveActivityPreferences,
             .subscribePresence,
             .subscribeTyping:
            // 这些命令以持久化状态为权威进行读取，但不会修改它。
            // 将其有界等待与写入分开，避免繁忙的房间日志追赶阻塞消息接受。
            // 授权仍由各领域服务负责。
            return .interactiveRead
        case .accountRoomChangesStart, .groupEventUnsubscribe, .unsubscribePresence, .unsubscribeTyping:
            // 这些命令只释放进程内订阅状态，或返回固定的成功响应。
            // PostgreSQL 过载时仍须可用，以便释放资源。
            return nil
        default:
            return .foregroundWrite
        }
    }

    private func commandManagesDatabaseAdmission(for envelope: IMV2Envelope) -> Bool {
        if roomCommandsHostAdmitted {
            switch envelope.body {
            case .recordReadReceipt,
                 .messageSendOperation, .messageSendOperationRecover,
                 .getGroupRolePolicyBaseline, .listRoomMembers,
                 .roomSyncStateBatch, .roomLatestVisibleBatch,
                 .groupEventPull, .groupEventSubscribe, .listReadReceiptReaders:
                return true
            default: break
            }
        }
        switch envelope.body {
        case .recordReadReceipt:
            return readReceipt.managesForegroundWriteAdmission
        case .messageSendOperation, .messageSendOperationRecover:
            return messageSendOperations.managesForegroundWriteAdmission
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
            case .messageSendOperation(let wire):
                let command = try V2MessageSendOperationWireCodec.decode(command: wire, limits: messageLimits)
                let operationIdentity = try command.identity
                guard operationIdentity.accountID == identity.userID,
                      command.command.senderUserID == identity.userID,
                      case .room(let roomID) = operationIdentity.scope,
                      roomID == command.command.roomID else { return errorEnvelope(code: "FORBIDDEN", retryable: false) }
                let result = try await messageSendOperations.sendOperation(command)
                var response = IMV2Envelope()
                response.messageSendOperationResult = V2MessageSendOperationWireCodec.encode(result: result)
                return response
            case .messageSendOperationRecover(let wire):
                let request = try V2MessageSendOperationWireCodec.decode(recovery: wire)
                guard request.identity.accountID == identity.userID,
                      case .room = request.identity.scope else { return errorEnvelope(code: "FORBIDDEN", retryable: false) }
                let result = try await messageSendOperations.recoverSendOperation(request)
                var response = IMV2Envelope()
                response.messageSendOperationResult = V2MessageSendOperationWireCodec.encode(result: result)
                return response
            case .recordReadReceipt(let request): return try await handleReadReceipt(request, identity: identity)
            case .getGroupRolePolicyBaseline(let request): return try await handleGroupRolePolicyBaseline(request, identity: identity)
            case .listRoomMembers(let request): return try await handleListRoomMembers(request, identity: identity)
            case .accountRoomChangesStart:
                guard let originatingConnectionID else { throw V2AccountRoomChangeService.Failure.staleConnection }
                let epoch = try await accountChanges.startAccountRoomChanges(connectionID: originatingConnectionID, userID: identity.userID)
                var response = IMV2Envelope()
                response.accountRoomChangesReady.connectionEpoch = epoch
                return response
            case .userRoomDirectoryList(let request): return try await roomRecovery.list(request, actorUserID: identity.userID)
            case .roomLatestVisibleBatch(let request): return try await roomRecovery.batch(request, actorUserID: identity.userID)
            case .roomSyncStateBatch(let request): return try await roomRecovery.batch(request, actorUserID: identity.userID)
            case .groupEventPull(let request): return try await handleGroupEventPull(request, identity: identity)
            case .groupEventSubscribe(let request): return try await handleGroupEventSubscribe(request, identity: identity)
            case .groupEventUnsubscribe(let request):
                _ = try RoomID(request.roomID)
                return successEnvelope()
            case .listReadReceiptReaders(let request): return try await handleReadReceiptReaders(request, identity: identity)
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
            case .setConversationState(let request): return try await handleConversationState(request, identity: identity)
            case .setMessageFavorite(let request): return try await handleMessageFavorite(request, identity: identity)
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
        } catch V2AccountRoomChangeService.Failure.closed, V2AccountRoomChangeService.Failure.staleConnection {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch V2RoomRecoveryReadError.invalidRequest, V2RoomRecoveryReadError.invalidCursor {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        } catch V2RoomRecoveryReadError.topologyChanged {
            return errorEnvelope(code: "ROOM_DIRECTORY_RESET_REQUIRED", retryable: true)
        } catch V2RoomRecoveryReadError.corruptPersistence {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch V2SyncServiceError.invalidRequest {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        } catch V2ForwardPendingError.pending {
            return errorEnvelope(code: "FORWARD_PENDING", retryable: true, retryAfter: 1)
        } catch V2ForwardPendingError.paused {
            return errorEnvelope(code: "FORWARD_PAUSED", retryable: true, retryAfter: 30)
        } catch is V2MessageSendOperationWireCodecError,
                is V2MessageOperationValidationError {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        } catch let failure as V2RoomCallFailure {
            switch failure {
            case .outcomeUnknown:
                // 客户端重试时沿用操作 ID；超时的写入可能已在前一实例中持久化。
                return errorEnvelope(code: "UNAVAILABLE", retryable: true)
            case .notAccepted(let reason), .rolledBack(let reason):
                switch reason {
                case .cancelled: throw CancellationError()
                case .forbidden: return errorEnvelope(code: "FORBIDDEN", retryable: false)
                case .notFound: return errorEnvelope(code: "NOT_FOUND", retryable: false)
                case .invalidRequest: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
                case .idempotencyConflict: return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
                default: return errorEnvelope(code: "UNAVAILABLE", retryable: true)
                }
            }
        } catch V2RoomMembershipDirectoryError.revisionConflict(let currentRevision) {
            return errorEnvelope(code: "REVISION_CONFLICT", retryable: false, currentRevision: currentRevision)
        } catch V2RevisionValidationError.outOfRange, V2CoreError.invalidIdentifier, V2CoreError.invalidPositiveValue, V2SendMessageValidationError.invalidTextLength, V2MediaStoreError.invalidReferenceSet, V2MentionValidationError.invalidLimits, V2MentionValidationError.invalidTargetSet, V2ModerationValidationError.invalidReasonCode, V2ModerationValidationError.invalidActionShape, V2ModerationValidationError.invalidMuteExpiry, V2RoomMembershipValidationError.selfTargetingNotAllowed, V2DirectMessagingValidationError.selfTargetingNotAllowed, V2SocialRelationshipValidationError.selfTargetingNotAllowed, V2MessageReactionValidationError.invalidReaction, V2MessageEditValidationError.invalidText, V2ReadReceiptValidationError.invalidRoomSequence, V2GroupMessagingValidationError.invalidTitle, V2GroupMessagingValidationError.invalidInitialMembers, V2RoomMembershipDirectoryError.invalidRequest, V2RoomMembershipDirectoryError.invalidCursor, V2GroupEventLogError.invalidRequest {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        } catch V2RoomMembershipStoreError.ownerChanged, V2RoomOwnerFenceError.ownerChanged, V2ReadReceiptStoreError.ownerChanged {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch V2RoomMembershipStoreError.actorNotOwner {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2RoomMembershipStoreError.targetUnavailable {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2ConversationCapabilitiesStoreError.operationPayloadMismatch {
            return errorEnvelope(code:"IDEMPOTENCY_CONFLICT",retryable:false)
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
        } catch V2RoomMembershipDirectoryError.ownerChanged {
            return errorEnvelope(code: "REVISION_CONFLICT", retryable: true)
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
        } catch V2DirectAuthorizationIntentError.identityConflict {
            return errorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        } catch is V2DirectAuthorizationCoordinationError,
                is V2DirectAuthorizationIntentError,
                is V2DirectAuthorizationReceiptError,
                is V2DirectSendControlPolicyError {
            // 未完成的撤销、中止的授权许可或不可用的所有者只影响当前请求。
            // 保留已认证的传输连接供重试。
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch V2SocialRelationshipStoreError.actorInactive {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2SocialRelationshipStoreError.corruptPersistenceState {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch V2RoomWriteStoreError.messageOperationClosed {
            return errorEnvelope(code: "MESSAGE_OPERATION_CLOSED", retryable: false)
        } catch V2RoomWriteStoreError.actorNotEligible, V2RoomWriteStoreError.actorMuted, V2RoomWriteStoreError.roomFrozen, V2RoomWriteStoreError.directMessageBlocked, V2RoomWriteStoreError.strangerMessagePermissionDenied {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2RoomWriteStoreError.roomNotFound, V2RoomWriteStoreError.replyTargetNotFound {
            return errorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2RoomWriteStoreError.capacityProfileMismatch, V2RoomWriteStoreError.corruptPersistenceState {
            // 容量配置是不可变的房间契约。部署使用了另一配置，或持久化准入不变量
            // 遭到破坏，都属于运行可用性故障，而非线路协议或认证故障。
            // 保持已认证连接，并只暴露稳定的协议错误类别。
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
            // 令牌只是不可解读的续传能力。令牌过期不属于传输故障：
            // 客户端可从持久化游标重新拉取，无须重连。
            return errorEnvelope(code: "SYNC_TOKEN_INVALID", retryable: false)
        } catch V2SyncStoreError.invalidOrExpiredSyncReceipt {
            // ACK 回执限定单次拉取范围。过期回执不能推进游标；
            // 应向客户端明确指示重试，而非暴露存储错误。
            return errorEnvelope(code: "SYNC_RECEIPT_INVALID", retryable: false)
        } catch V2SyncStoreError.deviceRevoked {
            // 持久化分片墓碑可能先于所有副本关闭已认证套接字而生效。
            // 此时让执行中的请求失败，不暴露任何投影数据。
            return errorEnvelope(code: "UNAUTHENTICATED", retryable: false)
        } catch V2SyncStoreError.resetRequired, V2SyncStoreError.generationMismatch {
            return errorEnvelope(code: "RESET_REQUIRED", retryable: false)
        } catch V2SyncStoreError.snapshotExpiredOrInvalid, V2SyncStoreError.snapshotFenceMismatch, V2SyncStoreError.noResetPending {
            return errorEnvelope(code: "RESET_REQUIRED", retryable: false)
        } catch V2SyncStoreError.acknowledgementBeyondWatermark {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        } catch V2SyncStoreError.syncLogSequenceGap, V2SyncStoreError.snapshotCheckpointUnavailable {
            // 服务端目前无法生成完整的同步响应。保持请求可重试，
            // 不发放不完整的能力，也不把尚未分配的快照呈现为已就绪。
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch V2SyncStoreError.syncRecordTooLarge {
            // 持久化状态不能迫使传输层断开连接。
            // 不可重试的错误码也能防止超大的首条记录让客户端无限重试。
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
            // 领域存储使用此封闭错误表示持久化不变量失败。
            // 这些失败不会使已认证传输会话失效；泄漏底层数据库结构还会暴露内部状态。
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch is V2ForwardMessageResultValidationError {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error where v2PostgresFailureDisposition(error) != .other {
            // 仅影响当前请求的数据库资源不足或事务重试耗尽都不属于传输故障。
            // 返回经处理的可重试响应，并保持已认证连接。
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
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




    private func handleConversationState(_ request: IMV2SetConversationState, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let revision=V2PersonalPreferenceRevision(rawValue:request.expectedRevision) else { return errorEnvelope(code:"INVALID_ARGUMENT",retryable:false) }
        let command=try V2ConversationStateCommand(operationID:.init(request.operationID),roomID:.init(request.roomID),isPinned:request.isPinned,isArchived:request.isArchived,muteUntil:request.muteUntilMs==0 ? nil:Date(timeIntervalSince1970:Double(request.muteUntilMs)/1000),expectedRevision:revision,firstSubmissionDeadlineMilliseconds:request.firstSubmissionDeadlineMs)
        var response=IMV2Envelope();response.personalPreferenceReceipt=try personalPreferenceWire(await conversationCapabilities.setConversationState(actorUserID:identity.userID,command:command));return response
    }
    private func handleMessageFavorite(_ request: IMV2SetMessageFavorite, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let revision=V2PersonalPreferenceRevision(rawValue:request.expectedRevision) else { return errorEnvelope(code:"INVALID_ARGUMENT",retryable:false) }
        let command=try V2MessageFavoriteCommand(operationID:.init(request.operationID),roomID:.init(request.roomID),messageID:.init(request.messageID),isFavorited:request.isFavorited,expectedRevision:revision,firstSubmissionDeadlineMilliseconds:request.firstSubmissionDeadlineMs)
        var response=IMV2Envelope();response.personalPreferenceReceipt=try personalPreferenceWire(await conversationCapabilities.setMessageFavorite(actorUserID:identity.userID,command:command));return response
    }
    private func personalPreferenceWire(_ receipt:V2PersonalPreferenceReceipt) throws -> IMV2PersonalPreferenceReceipt {
        var wire=IMV2PersonalPreferenceReceipt();wire.actorUserID=receipt.identity.accountID.rawValue;wire.operationID=receipt.identity.operation.rawOperationID
        switch receipt.identity.scope { case .room(let room):wire.roomID=room.rawValue;wire.kind = .conversationState
        case .message(let room,let message):wire.roomID=room.rawValue;wire.messageID=message.rawValue;wire.kind = .messageFavorite
        default:throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
        wire.fingerprintVersion=UInt32(receipt.fingerprint.version);wire.fingerprint=receipt.fingerprint.digest;wire.resolvedAtMs=receipt.resolvedAtMilliseconds
        switch receipt.outcome {
        case .closed:wire.closed=true
        case .rejected(let rejection):
            var value=IMV2PersonalPreferenceRejection()
            switch rejection {case .revisionConflict(let current):value.reason = .revisionConflict;value.currentRevision=current.rawValue
            case .permissionDenied:value.reason = .permissionDenied;case .notFound:value.reason = .notFound;case .expiredUnsubmitted:value.reason = .expiredUnsubmitted}
            wire.rejected=value
        case .committed(.conversationState(let value)):
            var result=IMV2ConversationStateSet();result.roomID=value.roomID.rawValue;result.isPinned=value.isPinned;result.isArchived=value.isArchived
            result.muteUntilMs=try value.muteUntil.map(v2GatewayMilliseconds) ?? 0;result.updatedAtMs=try v2GatewayMilliseconds(value.updatedAt);result.revision=value.revision.rawValue;wire.conversationState=result
        case .committed(.messageFavorite(let value)):
            var result=IMV2MessageFavoriteChanged();result.roomID=value.roomID.rawValue;result.messageID=value.messageID.rawValue;result.isFavorited=value.isFavorited
            result.updatedAtMs=try v2GatewayMilliseconds(value.updatedAt);result.revision=value.revision.rawValue;wire.messageFavorite=result
        }
        return wire
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

    /// 用与普通群事件命令完全相同的载荷预算规则构造持久化回落响应。
    ///
    /// 预编码快速路径只会在本地不可变覆盖不足，或最新成员栅栏无法为缓存分页授权时
    /// 才回落到本方法。
    private func groupEventPageEnvelope(_ page: V2GroupEventLogPage) -> IMV2Envelope {
        var response = IMV2Envelope()
        // 使用可能的最大请求 ID，让此处估算成为上界。
        // `V2GatewaySession` 会在最终 protobuf 编码前替换为实际请求 ID。
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
            // 持久化事件不能迫使传输连接关闭。客户端无法靠重复同一游标恢复，
            // 因此应明确指出持久化数据不兼容，并保持连接。
            return errorEnvelope(code: "GROUP_EVENT_TOO_LARGE", retryable: false)
        }

        response.groupEventPage.events = wireEvents
        response.groupEventPage.nextRoomSequence = nextRoomSequence
        response.groupEventPage.hasMore_p = hasMore
        // 保留裁剪的下界必须随页返回：客户端据此把房间标记为"历史不完整"，
        // 而不是静默地少几条。
        response.groupEventPage.logTrimmedThroughRoomSequence = page.logTrimmedThroughRoomSequence

        // 此估算器对当前 schema 是精确的，且已采用可能的最大请求 ID。
        // 此处不要序列化整个页面：`V2GatewaySession` 替换实际请求 ID 后，
        // 才进行唯一一次权威 protobuf 编码。载荷预算测试会编码最终帧，
        // 在 proto 演进时保护此估算逻辑。
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







    private func handleReadReceiptReaders(_ request: IMV2ListReadReceiptReaders, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard request.pageSize > 0, request.pageSize <= 100, request.cursor.utf8.count <= 512 else {
            return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
        }
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
            return wire
        }
        return response
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
            // 线路协议只传输整秒数；向上取整，避免客户端在存储要求的间隔结束前重试。
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
            // 无效的领域响应值意味着服务端故障。不要截断延迟值，
            // 也不要发送无法持久化的修订号。
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

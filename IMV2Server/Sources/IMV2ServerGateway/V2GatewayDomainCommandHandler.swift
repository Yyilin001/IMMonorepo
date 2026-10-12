import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

/// 网关 `GroupEventPage` 信封的精确 protobuf 载荷字节数。
///
/// 早期实现每追加一条事件就整体序列化一次候选页面，使满页场景在 protobuf 计算与临时分配上
/// 都退化为二次复杂度。把估算函数放在线路映射旁边，使大小栅栏保持线性，
/// 同时最终网关编码仍是权威结果。
func v2GroupEventPageEnvelopeBytes(
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

func v2GroupEventRepeatedFieldBytes(_ entry: V2GroupEventLogEntry) -> Int {
    let eventBytes =
        v2ProtobufLengthDelimitedFieldBytes(fieldNumber: 1, payloadBytes: entry.sourceEventID.rawValue.utf8.count)
        + v2ProtobufVarintFieldBytes(fieldNumber: 2, value: entry.roomSequence)
        + v2ProtobufLengthDelimitedFieldBytes(fieldNumber: 3, payloadBytes: entry.projectionKind.utf8.count)
        + v2ProtobufLengthDelimitedFieldBytes(fieldNumber: 4, payloadBytes: entry.payload.count)
    return v2ProtobufLengthDelimitedFieldBytes(fieldNumber: 2, payloadBytes: eventBytes)
}

func v2ProtobufLengthDelimitedFieldBytes(fieldNumber: Int, payloadBytes: Int) -> Int {
    v2ProtobufTagBytes(fieldNumber: fieldNumber, wireType: 2)
        + v2ProtobufVarintByteCount(UInt64(payloadBytes))
        + payloadBytes
}

func v2ProtobufVarintFieldBytes(fieldNumber: Int, value: UInt64) -> Int {
    guard value != 0 else { return 0 }
    return v2ProtobufTagBytes(fieldNumber: fieldNumber, wireType: 0)
        + v2ProtobufVarintByteCount(value)
}

func v2ProtobufTagBytes(fieldNumber: Int, wireType: UInt64) -> Int {
    v2ProtobufVarintByteCount((UInt64(fieldNumber) << 3) | wireType)
}

func v2ProtobufVarintByteCount(_ value: UInt64) -> Int {
    var remaining = value
    var count = 1
    while remaining >= 0x80 {
        remaining >>= 7
        count += 1
    }
    return count
}

/// A command has exactly one database-work admission owner. Commands with no
/// database work have no admission owner, so cleanup remains available during
/// overload. Room Host admission includes its own release and cancellation.
private enum V2GatewayAdmissionOwner: Equatable {
    case none
    case gateway
    case roomHost
    case operationHandler
}

/// 把已校验的已认证 protobuf 命令路由到 V2 领域服务。
public struct V2GatewayDomainCommandHandler:
    V2GatewayCommandHandler,
    V2PreparedGroupEventCommandHandling {
    private let receiptCommands: V2GatewayReceiptCommands
    private let messageCommands: V2GatewayMessageCommands
    private let liveActivityCommands: V2GatewayLiveActivityCommands
    private let groupEventCommands: V2GatewayGroupEventCommands
    private let roomQueryCommands: V2GatewayRoomQueryCommands
    private let accountChanges: any V2AccountRoomChangesStarting
    private let roomRecovery: any V2RoomRecoveryCommandHandling
    private let syncCommands: V2GatewaySyncCommands
    private let telemetry: any V2TelemetrySink
    private let databaseWorkAdmission: V2DatabaseWorkAdmissionController?
    private let databaseFailureIsTransient: @Sendable (any Error) -> Bool
    /// Room commands acquire admission in the Host when room actors are used.
    private let roomCommandsHostAdmitted: Bool
    /// 房间日志分页与其信封头共享普通网关帧的载荷预算。
    ///
    /// 最终线路编码器仍是权威；该预算用于避免一份合法但较长的持久化积压
    /// 在抵达该边界之前就被当作传输错误断开连接。
    private let now: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant

    package init(
        readReceiptHandler: any V2GatewayReadReceiptHandling,
        messageSendOperations: any V2GatewayMessageSendOperationHandling,
        messageLimits: V2MessageCommandLimits = try! .init(maxUTF8Bytes: 65_536),
        liveActivityHandler: any V2GatewayLiveActivityHandling,
        groupEventLogHandler: any V2GatewayGroupEventLogHandling,
        membershipDirectoryHandler: any V2GatewayRoomMembershipDirectoryHandling,
        roomRecovery: any V2RoomRecoveryCommandHandling,
        accountChanges: any V2AccountRoomChangesStarting,
        conversationCapabilitiesHandler: any V2GatewayConversationCapabilitiesHandling,
        groupRolePolicyBaseline: any V2GroupRolePolicyBaselineReading,
        sync: V2SyncService,
        telemetry: any V2TelemetrySink,
        databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil,
        databaseFailureIsTransient: @escaping @Sendable (any Error) -> Bool = { _ in false },
        roomCommandsHostAdmitted: Bool = false,
        maximumGroupEventPagePayloadBytes: Int = 48 * 1_024,
        now: @escaping @Sendable () -> Date = Date.init,
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        precondition(maximumGroupEventPagePayloadBytes > 0)
        receiptCommands = .init(readReceipt: readReceiptHandler)
        messageCommands = .init(messageSendOperations: messageSendOperations, messageLimits: messageLimits, conversationCapabilities: conversationCapabilitiesHandler)
        liveActivityCommands = .init(liveActivity: liveActivityHandler, now: now)
        roomQueryCommands = .init(groupRolePolicyBaseline: groupRolePolicyBaseline, membershipDirectory: membershipDirectoryHandler)
        syncCommands = .init(sync: sync)
        groupEventCommands = .init(groupEventLog: groupEventLogHandler, maximumGroupEventPagePayloadBytes: maximumGroupEventPagePayloadBytes)
        self.roomRecovery = roomRecovery
        self.accountChanges = accountChanges
        self.telemetry = telemetry
        self.databaseWorkAdmission = databaseWorkAdmission
        self.databaseFailureIsTransient = databaseFailureIsTransient
        self.roomCommandsHostAdmitted = roomCommandsHostAdmitted
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
               admissionOwner(for: envelope) == .gateway {
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
            if let databaseWorkAdmission, admissionOwner(for: telemetryEnvelope) == .gateway {
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
                    result = try await groupEventCommands.pullPreparedGroupEventPage(
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
                result = try await groupEventCommands.pullPreparedGroupEventPage(
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
                    groupEventCommands.groupEventPageEnvelope(page),
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
        } catch let error where databaseFailureIsTransient(error) {
            return .envelope(await recordAndReturn(
                errorEnvelope(code: "UNAVAILABLE", retryable: true),
                traceID: traceID,
                command: command,
                startedAt: startedAt
            ))
        } catch {
            if let failure = error as? V2RoomCallFailure,
               let response = groupEventPullBackpressure(failure) {
                return .envelope(await recordAndReturn(response, traceID: traceID,
                    command: command, startedAt: startedAt))
            }
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
        if case .messageSendOperationRecover = envelope.body,
           messageCommands.messageSendOperations.usesReadOnlySendRecovery { return .interactiveRead }
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

    private func admissionOwner(for envelope: IMV2Envelope) -> V2GatewayAdmissionOwner {
        guard databaseWorkClass(for: envelope) != nil else { return .none }
        if case .messageSendOperationRecover = envelope.body,
           messageCommands.messageSendOperations.usesReadOnlySendRecovery { return .gateway }
        if roomCommandsHostAdmitted {
            switch envelope.body {
            case .recordReadReceipt,
                 .messageSendOperation, .messageSendOperationRecover,
                 .getGroupRolePolicyBaseline, .listRoomMembers,
                 .roomSyncStateBatch, .roomLatestVisibleBatch,
                 .groupEventPull, .groupEventSubscribe, .listReadReceiptReaders:
                return .roomHost
            default: break
            }
        }
        switch envelope.body {
        case .recordReadReceipt:
            return receiptCommands.readReceipt.managesForegroundWriteAdmission ? .operationHandler : .gateway
        case .messageSendOperation, .messageSendOperationRecover:
            return messageCommands.messageSendOperations.managesForegroundWriteAdmission ? .operationHandler : .gateway
        default:
            return .gateway
        }
    }

    private func handleWithoutTelemetry(
        envelope: IMV2Envelope,
        identity: V2AuthenticatedConnection,
        originatingConnectionID: UUID?
    ) async throws -> IMV2Envelope {
        do {
            switch envelope.body {
            case .messageSendOperation(let wire): return try await messageCommands.send(wire, identity: identity)
            case .messageSendOperationRecover(let wire): return try await messageCommands.recover(wire, identity: identity)
            case .recordReadReceipt(let request): return try await receiptCommands.handleReadReceipt(request, identity: identity)
            case .getGroupRolePolicyBaseline(let request): return try await roomQueryCommands.handleGroupRolePolicyBaseline(request, identity: identity)
            case .listRoomMembers(let request): return try await roomQueryCommands.handleListRoomMembers(request, identity: identity)
            case .accountRoomChangesStart:
                guard let originatingConnectionID else { throw V2AccountRoomChangeService.Failure.staleConnection }
                let epoch = try await accountChanges.startAccountRoomChanges(connectionID: originatingConnectionID, userID: identity.userID)
                var response = IMV2Envelope()
                response.accountRoomChangesReady.connectionEpoch = epoch
                return response
            case .userRoomDirectoryList(let request): return try await roomRecovery.list(request, actorUserID: identity.userID)
            case .roomLatestVisibleBatch(let request): return try await roomRecovery.batch(request, actorUserID: identity.userID)
            case .roomSyncStateBatch(let request): return try await roomRecovery.batch(request, actorUserID: identity.userID)
            case .groupEventPull(let request): return try await groupEventCommands.handleGroupEventPull(request, identity: identity)
            case .groupEventSubscribe:
                // Subscription authority belongs to the connection registry and signed Room Owner.
                return v2GatewayErrorEnvelope(code: "UNAVAILABLE", retryable: true)
            case .groupEventUnsubscribe:
                return v2GatewayErrorEnvelope(code: "UNAVAILABLE", retryable: true)
            case .listReadReceiptReaders(let request): return try await receiptCommands.handleReadReceiptReaders(request, identity: identity)
            case .getLiveActivityPreferences: return try await liveActivityCommands.handleGetLiveActivityPreferences(identity: identity)
            case .subscribePresence(let request): return try await liveActivityCommands.handleSubscribePresence(request, identity: identity)
            case .unsubscribePresence(let request):
                _ = try RoomID(request.roomID)
                return successEnvelope()
            case .subscribeTyping(let request): return try await liveActivityCommands.handleSubscribeTyping(request, identity: identity)
            case .unsubscribeTyping(let request):
                _ = try RoomID(request.roomID)
                return successEnvelope()
            case .setTypingState(let request): return try await liveActivityCommands.handleTypingState(request, identity: identity)
            case .setConversationState(let request): return try await messageCommands.handleConversationState(request, identity: identity)
            case .setMessageFavorite(let request): return try await messageCommands.handleMessageFavorite(request, identity: identity)
            case .syncPull(let request): return try await syncCommands.handlePull(request, identity: identity)
            case .syncAck(let request):
                try await syncCommands.sync.acknowledge(userID: identity.userID, deviceID: identity.deviceID, generation: request.generation, highestContiguousSequence: request.highestContiguousSequence, receipt: try .init(request.syncReceipt))
                return successEnvelope()
            case .syncSnapshot(let request): return try await syncCommands.handleSnapshotManifest(request, identity: identity)
            case .snapshotPagePull(let request): return try await syncCommands.handleSnapshotPage(request, identity: identity)
            case .snapshotAck(let request):
                try await syncCommands.sync.acknowledgeSnapshot(userID: identity.userID, deviceID: identity.deviceID, snapshotID: try .init(request.snapshotID), generation: request.generation, baseSequence: request.baseUserSyncSequence, receipt: try .init(request.snapshotReceipt))
                return successEnvelope()
            default: return errorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
            }
        } catch V2GatewayTimestampError.unrepresentable, V2GroupMessagingValidationError.invalidMemberCount,
                V2AcceptanceIdentifierError.invalidTimestamp {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch V2AccountRoomChangeService.Failure.closed, V2AccountRoomChangeService.Failure.staleConnection {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        } catch is V2RealtimePublicationBackpressure {
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
        } catch let overload as V2GatewayMessageOverloadFailure {
            let command: V2MessageSendFailureCommand
            switch envelope.body {
            case .messageSendOperation: command = .submit
            case .messageSendOperationRecover: command = .recover
            default: throw overload // the decoded operation wrapper is family-specific
            }
            let disposition: V2MessageSendFailureDisposition
            switch overload.failure {
            case .notAccepted(.overloaded): disposition = .notAccepted
            case .rolledBack(.overloaded): disposition = .rolledBack
            default: throw overload // no inferred rollback or generic availability mapping
            }
            await telemetry.record(.messageSendInternalFailure(command: command,
                disposition: disposition, reason: .overloaded))
            let hint = try V2MessageOperationRetryHint(identity: overload.identity,
                fingerprint: overload.fingerprint, reason: .admissionUnavailable,
                retryAfterMilliseconds: nil)
            var response = IMV2Envelope()
            response.messageSendOperationResult = V2MessageSendOperationWireCodec.encode(result: .deferred(hint))
            return response
        } catch let failure as V2RoomCallFailure {
            if case .groupEventPull = envelope.body,
               let response = groupEventPullBackpressure(failure) { return response }
            let diagnosticCommand: V2MessageSendFailureCommand?
            switch envelope.body {
            case .messageSendOperation: diagnosticCommand = .submit
            case .messageSendOperationRecover: diagnosticCommand = .recover
            default: diagnosticCommand = nil
            }
            if let diagnosticCommand {
                let disposition: V2MessageSendFailureDisposition
                let reason: V2MessageSendFailureReason
                switch failure {
                case .outcomeUnknown: disposition = .outcomeUnknown; reason = .none
                case .notAccepted(let actorReason): disposition = .notAccepted; reason = messageFailureReason(actorReason)
                case .rolledBack(let actorReason): disposition = .rolledBack; reason = messageFailureReason(actorReason)
                }
                await telemetry.record(.messageSendInternalFailure(command: diagnosticCommand,
                    disposition: disposition, reason: reason))
            }
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
        } catch V2SocialRelationshipStoreError.actorInactive {
            return errorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2SocialRelationshipStoreError.corruptPersistenceState {
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)

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
        } catch let error where databaseFailureIsTransient(error) {
            // 仅影响当前请求的数据库资源不足或事务重试耗尽都不属于传输故障。
            // 返回经处理的可重试响应，并保持已认证连接。
            return errorEnvelope(code: "UNAVAILABLE", retryable: true)
        }
    }

    private func successEnvelope() -> IMV2Envelope { v2GatewaySuccessEnvelope() }
    /// Only a known rejected/rolled-back read is backpressure. Unknown results
    /// and unavailable transports retain their existing error handling.
    private func groupEventPullBackpressure(_ failure: V2RoomCallFailure) -> IMV2Envelope? {
        switch failure {
        case .notAccepted(.overloaded), .rolledBack(.overloaded):
            return errorEnvelope(code: "SERVER_BUSY", retryable: true, retryAfter: 1)
        default: return nil
        }
    }

    private func errorEnvelope(code: String, retryable: Bool, retryAfter: Int = 0, currentRevision: UInt64 = 0) -> IMV2Envelope {
        v2GatewayErrorEnvelope(code: code, retryable: retryable, retryAfter: retryAfter, currentRevision: currentRevision)
    }
}

private func messageFailureReason(_ reason: V2RoomFailureReason) -> V2MessageSendFailureReason {
    switch reason {
    case .staleActivation: .staleActivation
    case .notReady: .notReady
    case .retired: .retired
    case .authorityLost: .authorityLost
    case .unavailable: .unavailable
    case .overloaded: .overloaded
    case .deadlineExceeded: .deadlineExceeded
    case .cancelled: .cancelled
    case .notFound: .notFound
    case .forbidden: .forbidden
    case .invalidRequest: .invalidRequest
    case .unsupportedVersion: .unsupportedVersion
    case .idempotencyConflict: .idempotencyConflict
    }
}

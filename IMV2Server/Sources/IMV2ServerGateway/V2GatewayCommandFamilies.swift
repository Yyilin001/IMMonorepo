import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

// Each family owns protobuf conversion for its commands. The outer handler owns
// dispatch, the common error map, telemetry and Gateway admission.
struct V2GatewayMessageCommands: Sendable {
    let messageSendOperations: any V2GatewayMessageSendOperationHandling
    let messageLimits: V2MessageCommandLimits
    let conversationCapabilities: any V2GatewayConversationCapabilitiesHandling
    func send(_ wire: IMV2MessageSendOperation, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let command = try V2MessageSendOperationWireCodec.decode(command: wire, limits: messageLimits)
        let operationIdentity = try command.identity
        guard operationIdentity.accountID == identity.userID,
              command.command.senderUserID == identity.userID,
              case .room(let roomID) = operationIdentity.scope,
              roomID == command.command.roomID else { return v2GatewayErrorEnvelope(code: "FORBIDDEN", retryable: false) }
        let result = try await messageSendOperations.sendOperation(command)
        var response = IMV2Envelope()
        response.messageSendOperationResult = V2MessageSendOperationWireCodec.encode(result: result)
        return response
    }

    func recover(_ wire: IMV2MessageSendOperationRecover, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let request = try V2MessageSendOperationWireCodec.decode(recovery: wire)
        guard request.identity.accountID == identity.userID,
              case .room = request.identity.scope else { return v2GatewayErrorEnvelope(code: "FORBIDDEN", retryable: false) }
        let result = try await messageSendOperations.recoverSendOperation(request)
        var response = IMV2Envelope()
        response.messageSendOperationResult = V2MessageSendOperationWireCodec.encode(result: result)
        return response
    }
    func handleConversationState(_ request: IMV2SetConversationState, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let revision=V2PersonalPreferenceRevision(rawValue:request.expectedRevision) else { return v2GatewayErrorEnvelope(code:"INVALID_ARGUMENT",retryable:false) }
        let command=try V2ConversationStateCommand(operationID:.init(request.operationID),roomID:.init(request.roomID),isPinned:request.isPinned,isArchived:request.isArchived,muteUntil:request.muteUntilMs==0 ? nil:Date(timeIntervalSince1970:Double(request.muteUntilMs)/1000),expectedRevision:revision,firstSubmissionDeadlineMilliseconds:request.firstSubmissionDeadlineMs)
        var response=IMV2Envelope();response.personalPreferenceReceipt=try personalPreferenceWire(await conversationCapabilities.setConversationState(actorUserID:identity.userID,command:command));return response
    }

    func handleMessageFavorite(_ request: IMV2SetMessageFavorite, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let revision=V2PersonalPreferenceRevision(rawValue:request.expectedRevision) else { return v2GatewayErrorEnvelope(code:"INVALID_ARGUMENT",retryable:false) }
        let command=try V2MessageFavoriteCommand(operationID:.init(request.operationID),roomID:.init(request.roomID),messageID:.init(request.messageID),isFavorited:request.isFavorited,expectedRevision:revision,firstSubmissionDeadlineMilliseconds:request.firstSubmissionDeadlineMs)
        var response=IMV2Envelope();response.personalPreferenceReceipt=try personalPreferenceWire(await conversationCapabilities.setMessageFavorite(actorUserID:identity.userID,command:command));return response
    }

    func personalPreferenceWire(_ receipt:V2PersonalPreferenceReceipt) throws -> IMV2PersonalPreferenceReceipt {
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
}

struct V2GatewayReceiptCommands: Sendable {
    let readReceipt: any V2GatewayReadReceiptHandling
    func handleReadReceipt(_ request: IMV2RecordReadReceipt, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let outcome: V2ReadReceiptOutcome
        do {
            outcome = try await readReceipt.record(.init(roomID: try .init(request.roomID), actorUserID: identity.userID, operationID: try .init(request.operationID), readThroughRoomSequence: request.readThroughRoomSequence))
        } catch V2ReadReceiptBatcherError.serverBusy {
            return v2GatewayErrorEnvelope(code: "SERVER_BUSY", retryable: true)
        }
        switch outcome {
        case .recorded(let result), .idempotent(let result):
            var response = IMV2Envelope(); response.readReceiptRecorded = .init()
            response.readReceiptRecorded.roomID = result.roomID.rawValue
            response.readReceiptRecorded.userID = result.userID.rawValue
            response.readReceiptRecorded.readThroughRoomSequence = result.readThroughRoomSequence
            response.readReceiptRecorded.recordedAtMs = try v2GatewayMilliseconds(result.recordedAt)
            return response
        case .idempotencyConflict: return v2GatewayErrorEnvelope(code: "IDEMPOTENCY_CONFLICT", retryable: false)
        }
    }

    func handleReadReceiptReaders(_ request: IMV2ListReadReceiptReaders, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard request.pageSize > 0, request.pageSize <= 100, request.cursor.utf8.count <= 512 else {
            return v2GatewayErrorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
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
}

struct V2GatewayRoomQueryCommands: Sendable {
    let groupRolePolicyBaseline: any V2GroupRolePolicyBaselineReading
    let membershipDirectory: any V2GatewayRoomMembershipDirectoryHandling
    func handleGroupRolePolicyBaseline(_ request: IMV2GetGroupRolePolicyBaseline, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        guard let roomUUID = UUID(uuidString: request.roomID) else { return v2GatewayErrorEnvelope(code: "INVALID_ARGUMENT", retryable: false) }
        let value: V2GroupRolePolicyBaseline
        do {
            value = try await groupRolePolicyBaseline.readRolePolicyBaseline(roomID: .init(uuid: roomUUID), actorUserID: identity.userID)
        } catch V2GroupRolePolicyBaselineError.actorNotMember {
            return v2GatewayErrorEnvelope(code: "FORBIDDEN", retryable: false)
        } catch V2GroupRolePolicyBaselineError.roomNotFound, V2RoomShardRouteError.roomNotFound {
            return v2GatewayErrorEnvelope(code: "NOT_FOUND", retryable: false)
        } catch V2RoomShardRouteError.routeConflict {
            return v2GatewayErrorEnvelope(code: "ROOM_OWNER_CHANGED", retryable: true, retryAfter: 1)
        } catch V2GroupRolePolicyBaselineError.corruptPersistenceState, V2RoomShardRouteError.corruptPersistenceState, V2RoomShardStorageRegistryError.unknownShardID {
            return v2GatewayErrorEnvelope(code: "UNAVAILABLE", retryable: true, retryAfter: 1)
        }
        guard value.roomID == RoomID(uuid: roomUUID) else { return v2GatewayErrorEnvelope(code: "UNAVAILABLE", retryable: true, retryAfter: 1) }
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

    func handleListRoomMembers(_ request: IMV2ListRoomMembers, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
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
}

struct V2GatewayLiveActivityCommands: Sendable {
    let liveActivity: any V2GatewayLiveActivityHandling
    let now: @Sendable () -> Date
    func handleGetLiveActivityPreferences(identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let preferences = try await liveActivity.preferences(userID: identity.userID, now: now())
        var response = IMV2Envelope(); response.liveActivityPreferences = .init()
        response.liveActivityPreferences.allowsOnlinePresence = preferences.allowsOnlinePresence
        response.liveActivityPreferences.allowsTypingIndicators = preferences.allowsTypingIndicators
        response.liveActivityPreferences.updatedAtMs = try v2GatewayMilliseconds(preferences.updatedAt)
        return response
    }

    func handleSubscribePresence(_ request: IMV2SubscribePresence, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let presence = try await liveActivity.presence(roomID: .init(request.roomID), viewerUserID: identity.userID, now: now())
        var response = IMV2Envelope(); response.presenceSubscribed = .init()
        response.presenceSubscribed.roomID = presence.roomID.rawValue
        response.presenceSubscribed.targetUserID = presence.targetUserID.rawValue
        response.presenceSubscribed.isOnline = presence.isOnline
        response.presenceSubscribed.expiresAtMs = try v2GatewayMilliseconds(presence.expiresAt)
        return response
    }

    func handleSubscribeTyping(_ request: IMV2SubscribeTyping, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        try await liveActivity.authorizeTyping(roomID: .init(request.roomID), actorUserID: identity.userID, now: now())
        return v2GatewaySuccessEnvelope()
    }

    func handleTypingState(_ request: IMV2SetTypingState, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        try await liveActivity.authorizeTyping(roomID: .init(request.roomID), actorUserID: identity.userID, now: now())
        return v2GatewaySuccessEnvelope()
    }
}

struct V2GatewaySyncCommands: Sendable {
    let sync: V2SyncService
    func handlePull(_ request: IMV2SyncPull, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
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
                return v2GatewayErrorEnvelope(code: "UNAVAILABLE", retryable: true)
            }
            return v2GatewayErrorEnvelope(code: "RESET_PREPARING", retryable: true, retryAfter: Int(seconds))
        }
    }

    func handleSnapshotManifest(_ request: IMV2SyncSnapshot, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let manifest = try await sync.fetchSnapshotManifest(userID: identity.userID, deviceID: identity.deviceID, snapshotID: try .init(request.snapshotID), generation: request.generation)
        guard manifest.capabilityProfile == identity.capabilityProfile else {
            return v2GatewayErrorEnvelope(code: "UPGRADE_REQUIRED", retryable: false)
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

    func handleSnapshotPage(_ request: IMV2SnapshotPagePull, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
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
}


struct V2GatewayGroupEventCommands: Sendable {
    let groupEventLog: any V2GatewayGroupEventLogHandling
    let maximumGroupEventPagePayloadBytes: Int

    func pullPreparedGroupEventPage(
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

    func handleGroupEventPull(_ request: IMV2GroupEventPull, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        let page = try await groupEventLog.pull(
            roomID: try .init(request.roomID),
            actorUserID: identity.userID,
            afterRoomSequence: request.afterRoomSequence,
            pageSize: Int(request.pageSize)
        )
        return groupEventPageEnvelope(page)
    }

    func groupEventPageEnvelope(_ page: V2GroupEventLogPage) -> IMV2Envelope {
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
            return v2GatewayErrorEnvelope(code: "GROUP_EVENT_TOO_LARGE", retryable: false)
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

    func handleGroupEventSubscribe(_ request: IMV2GroupEventSubscribe, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
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
}

func v2GatewaySuccessEnvelope() -> IMV2Envelope {
    var response = IMV2Envelope()
    response.acknowledged = .init()
    return response
}

func v2GatewayErrorEnvelope(code: String, retryable: Bool, retryAfter: Int = 0, currentRevision: UInt64 = 0) -> IMV2Envelope {
    var response = IMV2Envelope()
    response.error = .init()
    guard let seconds = UInt32(exactly: retryAfter), currentRevision <= UInt64(Int64.max) else {
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

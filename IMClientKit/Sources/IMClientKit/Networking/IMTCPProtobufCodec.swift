import Foundation

enum IMTCPProtobufCodec {
    static let protocolVersion: UInt32 = 2

    static func encode<Payload: Sendable>(
        type: IMTCPPacketType,
        requestID: UUID?,
        payload: Payload,
        timestamp: Date = Date()
    ) throws -> Data {
        var packet = IMRTPacket()
        if let requestID {
            packet.requestID = requestID.uuidString
        }
        packet.timestampMs = timestamp.millisecondsSince1970
        packet.protocolVersion = protocolVersion

        switch type {
        case .auth:
            guard let payload = payload as? IMTCPAuthRequestPayload else {
                throw IMTCPClientError.invalidPayload(type)
            }
            packet.auth = payload.protobuf
        case .authOK:
            guard let payload = payload as? IMTCPAuthAcceptedPayload else {
                throw IMTCPClientError.invalidPayload(type)
            }
            packet.authOk = payload.protobuf
        case .authError:
            guard let payload = payload as? IMTCPAuthErrorPayload else {
                throw IMTCPClientError.invalidPayload(type)
            }
            packet.authError = payload.protobuf
        case .heartbeat:
            guard let payload = payload as? IMTCPHeartbeatPayload else {
                throw IMTCPClientError.invalidPayload(type)
            }
            packet.heartbeat = payload.protobuf
        case .heartbeatAck:
            guard let payload = payload as? IMTCPHeartbeatPayload else {
                throw IMTCPClientError.invalidPayload(type)
            }
            packet.heartbeatAck = payload.protobuf
        case .message:
            guard let payload = payload as? IMTCPMessagePayload else {
                throw IMTCPClientError.invalidPayload(type)
            }
            packet.message = payload.protobuf
        case .ack:
            guard let payload = payload as? IMTCPAckPayload else {
                throw IMTCPClientError.invalidPayload(type)
            }
            packet.ack = payload.protobuf
        case .conversationEvent:
            guard let payload = payload as? IMTCPConversationEventPayload else {
                throw IMTCPClientError.invalidPayload(type)
            }
            packet.conversationEvent = payload.protobuf
        case .contactEvent:
            guard let payload = payload as? IMTCPContactEventPayload else {
                throw IMTCPClientError.invalidPayload(type)
            }
            packet.contactEvent = payload.protobuf
        case .kick:
            guard let payload = payload as? IMTCPKickPayload else {
                throw IMTCPClientError.invalidPayload(type)
            }
            packet.kick = payload.protobuf
        }

        return try packet.serializedData()
    }

    static func decode(_ data: Data) throws -> IMTCPInboundPacket {
        let packet = try IMRTPacket(serializedBytes: data)
        let requestID = packet.hasRequestID ? UUID(uuidString: packet.requestID) : nil
        let timestamp = packet.timestampMs > 0 ? Date(millisecondsSince1970: packet.timestampMs) : nil

        switch packet.body {
        case .auth(let payload):
            return IMTCPInboundPacket(type: .auth, requestID: requestID, timestamp: timestamp, payload: try payload.domainValue())
        case .authOk(let payload):
            return IMTCPInboundPacket(type: .authOK, requestID: requestID, timestamp: timestamp, payload: try payload.domainValue())
        case .authError(let payload):
            return IMTCPInboundPacket(type: .authError, requestID: requestID, timestamp: timestamp, payload: payload.domainValue)
        case .heartbeat(let payload):
            return IMTCPInboundPacket(type: .heartbeat, requestID: requestID, timestamp: timestamp, payload: payload.domainValue)
        case .heartbeatAck(let payload):
            return IMTCPInboundPacket(type: .heartbeatAck, requestID: requestID, timestamp: timestamp, payload: payload.domainValue)
        case .message(let payload):
            return IMTCPInboundPacket(type: .message, requestID: requestID, timestamp: timestamp, payload: try payload.domainValue())
        case .ack(let payload):
            return IMTCPInboundPacket(type: .ack, requestID: requestID, timestamp: timestamp, payload: payload.domainValue)
        case .conversationEvent(let payload):
            return IMTCPInboundPacket(type: .conversationEvent, requestID: requestID, timestamp: timestamp, payload: try payload.domainValue())
        case .contactEvent(let payload):
            return IMTCPInboundPacket(type: .contactEvent, requestID: requestID, timestamp: timestamp, payload: try payload.domainValue())
        case .kick(let payload):
            return IMTCPInboundPacket(type: .kick, requestID: requestID, timestamp: timestamp, payload: payload.domainValue)
        case nil:
            throw IMTCPClientError.invalidPacket
        }
    }
}

public struct IMTCPDecodedPayload: Sendable {
    private let value: any Sendable

    init(_ value: any Sendable) {
        self.value = value
    }

    public func decodePayload<T: Sendable>(_: T.Type) throws -> T {
        guard let typed = value as? T else {
            throw IMTCPClientError.invalidPacket
        }
        return typed
    }
}

public struct IMTCPInboundPacket: Sendable {
    public let type: IMTCPPacketType
    public let requestID: UUID?
    public let timestamp: Date?
    public let payload: IMTCPDecodedPayload

    init(type: IMTCPPacketType, requestID: UUID?, timestamp: Date?, payload: any Sendable) {
        self.type = type
        self.requestID = requestID
        self.timestamp = timestamp
        self.payload = IMTCPDecodedPayload(payload)
    }
}

private extension Date {
    var millisecondsSince1970: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }

    init(millisecondsSince1970: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(millisecondsSince1970) / 1000)
    }
}

private extension IMTCPAuthRequestPayload {
    var protobuf: IMRTAuthRequest {
        var value = IMRTAuthRequest()
        value.accessToken = accessToken
        if let deviceID { value.deviceID = deviceID }
        if let deviceName { value.deviceName = deviceName }
        if let platform { value.platform = platform }
        if let appVersion { value.appVersion = appVersion }
        value.protocolVersion = UInt32(protocolVersion)
        return value
    }
}

private extension IMRTAuthRequest {
    func domainValue() throws -> IMTCPAuthRequestPayload {
        IMTCPAuthRequestPayload(
            accessToken: accessToken,
            deviceID: hasDeviceID ? deviceID : nil,
            deviceName: hasDeviceName ? deviceName : nil,
            platform: hasPlatform ? platform : nil,
            appVersion: hasAppVersion ? appVersion : nil,
            protocolVersion: Int(protocolVersion)
        )
    }
}

private extension IMTCPAuthAcceptedPayload {
    var protobuf: IMRTAuthAccepted {
        var value = IMRTAuthAccepted()
        value.connectionID = connectionID.uuidString
        value.userID = userID.uuidString
        value.sessionID = sessionID.uuidString
        value.heartbeatIntervalSeconds = UInt32(heartbeatIntervalSeconds)
        value.serverTimeMs = serverTime.millisecondsSince1970
        return value
    }
}

private extension IMRTAuthAccepted {
    func domainValue() throws -> IMTCPAuthAcceptedPayload {
        guard let connectionID = UUID(uuidString: connectionID),
              let userID = UUID(uuidString: userID),
              let sessionID = UUID(uuidString: sessionID)
        else {
            throw IMTCPClientError.invalidPayload(.authOK)
        }
        return IMTCPAuthAcceptedPayload(
            connectionID: connectionID,
            userID: userID,
            sessionID: sessionID,
            heartbeatIntervalSeconds: Int(heartbeatIntervalSeconds),
            serverTime: Date(millisecondsSince1970: serverTimeMs)
        )
    }
}

private extension IMTCPAuthErrorPayload {
    var protobuf: IMRTAuthError {
        var value = IMRTAuthError()
        value.code = code
        value.message = message
        return value
    }
}

private extension IMRTAuthError {
    var domainValue: IMTCPAuthErrorPayload {
        IMTCPAuthErrorPayload(code: code, message: message)
    }
}

private extension IMTCPHeartbeatPayload {
    var protobuf: IMRTHeartbeat {
        var value = IMRTHeartbeat()
        value.sequence = Int32(sequence)
        return value
    }
}

private extension IMRTHeartbeat {
    var domainValue: IMTCPHeartbeatPayload {
        IMTCPHeartbeatPayload(sequence: Int(sequence))
    }
}

private extension IMTCPAckPayload {
    var protobuf: IMRTAck {
        var value = IMRTAck()
        value.messageID = messageID
        if let conversationID { value.conversationID = conversationID }
        value.status = status
        return value
    }
}

private extension IMRTAck {
    var domainValue: IMTCPAckPayload {
        IMTCPAckPayload(
            messageID: messageID,
            conversationID: hasConversationID ? conversationID : nil,
            status: status
        )
    }
}

private extension IMTCPMessagePayload {
    var protobuf: IMRTMessagePayload {
        var value = IMRTMessagePayload()
        if let clientMessageID { value.clientMessageID = clientMessageID }
        if let messageID { value.messageID = messageID }
        value.conversationID = conversationID
        if let senderUserID { value.senderUserID = senderUserID.uuidString }
        if let serverSequence { value.serverSequence = serverSequence }
        if let serverTimestamp { value.serverTimestampMs = serverTimestamp.millisecondsSince1970 }
        value.content = content.protobuf
        value.derivedState = derivedState.protobuf
        return value
    }
}

private extension IMRTMessagePayload {
    func domainValue() throws -> IMTCPMessagePayload {
        IMTCPMessagePayload(
            clientMessageID: hasClientMessageID ? clientMessageID : nil,
            messageID: hasMessageID ? messageID : nil,
            conversationID: conversationID,
            senderUserID: hasSenderUserID ? UUID(uuidString: senderUserID) : nil,
            serverSequence: hasServerSequence ? serverSequence : nil,
            serverTimestamp: hasServerTimestampMs ? Date(millisecondsSince1970: serverTimestampMs) : nil,
            content: try content.domainValue(),
            derivedState: try derivedState.domainValue()
        )
    }
}

private extension IMMessageContent {
    var protobuf: IMRTMessageContent {
        var value = IMRTMessageContent()
        switch self {
        case .text(let text):
            var content = IMRTTextContent()
            content.text = text
            value.text = content
        case .reply(let reference, let text):
            var content = IMRTReplyContent()
            content.reference = reference.protobuf
            content.text = text
            value.reply = content
        case .recalled:
            value.recalled = IMRTRecalledContent()
        case .system(let event):
            value.system = event.protobuf
        case .image(let asset):
            value.image = asset.protobuf
        case .audio(let asset):
            value.audio = asset.protobuf
        case .file(let asset):
            value.file = asset.protobuf
        }
        return value
    }
}

private extension IMRTMessageContent {
    func domainValue() throws -> IMMessageContent {
        switch body {
        case .text(let content):
            return .text(content.text)
        case .reply(let content):
            return .reply(reference: try content.reference.domainValue(), text: content.text)
        case .recalled:
            return .recalled
        case .system(let content):
            return .system(try content.domainValue())
        case .image(let asset):
            return .image(try asset.domainValue())
        case .audio(let asset):
            return .audio(try asset.domainValue())
        case .file(let asset):
            return .file(try asset.domainValue())
        case nil:
            throw IMTCPClientError.invalidPayload(.message)
        }
    }
}

private extension IMReplyReference {
    var protobuf: IMRTReplyReference {
        var value = IMRTReplyReference()
        value.messageID = messageID
        if let senderUserID { value.senderUserID = senderUserID.uuidString }
        value.previewText = previewText
        return value
    }
}

private extension IMRTReplyReference {
    func domainValue() throws -> IMReplyReference {
        IMReplyReference(
            messageID: messageID,
            senderUserID: hasSenderUserID ? UUID(uuidString: senderUserID) : nil,
            previewText: previewText
        )
    }
}

private extension IMMediaAsset {
    var protobuf: IMRTMediaAsset {
        var value = IMRTMediaAsset()
        value.assetID = assetID
        value.kind = kind.rawValue
        value.mimeType = mimeType
        value.byteSize = byteSize
        value.filename = filename
        if let width { value.width = Int32(width) }
        if let height { value.height = Int32(height) }
        if let durationMillis { value.durationMillis = Int32(durationMillis) }
        if let previewAssetID { value.previewAssetID = previewAssetID }
        return value
    }
}

private extension IMRTMediaAsset {
    func domainValue() throws -> IMMediaAsset {
        guard let kind = IMMediaAssetKind(rawValue: kind) else {
            throw IMTCPClientError.invalidPayload(.message)
        }
        return IMMediaAsset(
            assetID: assetID,
            kind: kind,
            mimeType: mimeType,
            byteSize: byteSize,
            filename: filename,
            width: hasWidth ? Int(width) : nil,
            height: hasHeight ? Int(height) : nil,
            durationMillis: hasDurationMillis ? Int(durationMillis) : nil,
            previewAssetID: hasPreviewAssetID ? previewAssetID : nil
        )
    }
}

private extension IMSystemEvent {
    var protobuf: IMRTSystemContent {
        var value = IMRTSystemContent()
        value.type = type.rawValue
        if let actorUserID { value.actorUserID = actorUserID.uuidString }
        if let actorEmail { value.actorEmail = actorEmail }
        if let targetUserID { value.targetUserID = targetUserID.uuidString }
        if let targetEmail { value.targetEmail = targetEmail }
        value.memberEmails = memberEmails
        if let previousRole { value.previousRole = previousRole.rawValue }
        if let newRole { value.newRole = newRole.rawValue }
        value.updatedFields = updatedFields.map(\.rawValue)
        if let title { value.title = title }
        if let notice { value.notice = notice }
        if let avatarPreset { value.avatarPreset = avatarPreset.rawValue }
        if let legacyText { value.legacyText = legacyText }
        return value
    }
}

private extension IMRTSystemContent {
    func domainValue() throws -> IMSystemEvent {
        guard let type = IMSystemEventType(rawValue: type) else {
            throw IMTCPClientError.invalidPayload(.message)
        }
        return IMSystemEvent(
            type: type,
            actorUserID: hasActorUserID ? UUID(uuidString: actorUserID) : nil,
            actorEmail: hasActorEmail ? actorEmail : nil,
            targetUserID: hasTargetUserID ? UUID(uuidString: targetUserID) : nil,
            targetEmail: hasTargetEmail ? targetEmail : nil,
            memberEmails: memberEmails,
            previousRole: hasPreviousRole ? IMConversationMemberRole(rawValue: previousRole) : nil,
            newRole: hasNewRole ? IMConversationMemberRole(rawValue: newRole) : nil,
            updatedFields: updatedFields.compactMap(IMConversationMetadataField.init(rawValue:)),
            title: hasTitle ? title : nil,
            notice: hasNotice ? notice : nil,
            avatarPreset: hasAvatarPreset ? IMConversationAvatarPreset(rawValue: avatarPreset) : nil,
            legacyText: hasLegacyText ? legacyText : nil
        )
    }
}

private extension MessageDerivedState {
    var protobuf: IMRTMessageDerivedState {
        var value = IMRTMessageDerivedState()
        value.recallState = recallState.protobufRawValue
        value.edits = edits.map(\.protobuf)
        value.reactions = reactions.map(\.protobuf)
        if let streamState { value.streamState = streamState.protobuf }
        return value
    }
}

private extension IMRTMessageDerivedState {
    func domainValue() throws -> MessageDerivedState {
        MessageDerivedState(
            recallState: recallState == "recalled" ? .recalled : .active,
            edits: edits.map { $0.domainValue },
            reactions: reactions.compactMap { $0.domainValue },
            streamState: hasStreamState ? try streamState.domainValue() : nil
        )
    }
}

private extension MessageRecallState {
    var protobufRawValue: String {
        switch self {
        case .active:
            return "active"
        case .recalled:
            return "recalled"
        }
    }
}

private extension MessageEdit {
    var protobuf: IMRTMessageEdit {
        var value = IMRTMessageEdit()
        if let editedAt { value.editedAtMs = editedAt.millisecondsSince1970 }
        value.text = text
        return value
    }
}

private extension IMRTMessageEdit {
    var domainValue: MessageEdit {
        MessageEdit(
            editedAt: hasEditedAtMs ? Date(millisecondsSince1970: editedAtMs) : nil,
            text: text
        )
    }
}

private extension MessageReaction {
    var protobuf: IMRTMessageReaction {
        var value = IMRTMessageReaction()
        value.emoji = emoji
        value.actorUserIds = actorUserIDs.map(\.uuidString)
        return value
    }
}

private extension IMRTMessageReaction {
    var domainValue: MessageReaction? {
        let ids = actorUserIds.compactMap(UUID.init(uuidString:))
        guard ids.count == actorUserIds.count else {
            return nil
        }
        return MessageReaction(emoji: emoji, actorUserIDs: ids)
    }
}

private extension MessageStreamState {
    var protobuf: IMRTMessageStreamState {
        var value = IMRTMessageStreamState()
        value.streamID = streamID
        value.state = state.rawValue
        value.lastChunkIndex = Int32(lastChunkIndex)
        value.partialText = partialText
        if let errorCode { value.errorCode = errorCode }
        if let errorMessage { value.errorMessage = errorMessage }
        value.updatedAtMs = updatedAt.millisecondsSince1970
        value.isAiGenerated = isAIGenerated
        return value
    }
}

private extension IMRTMessageStreamState {
    func domainValue() throws -> MessageStreamState {
        guard let state = MessageStreamLifecycleState(rawValue: state) else {
            throw IMTCPClientError.invalidPayload(.conversationEvent)
        }
        return MessageStreamState(
            streamID: streamID,
            state: state,
            lastChunkIndex: Int(lastChunkIndex),
            partialText: partialText,
            errorCode: hasErrorCode ? errorCode : nil,
            errorMessage: hasErrorMessage ? errorMessage : nil,
            updatedAt: Date(millisecondsSince1970: updatedAtMs),
            isAIGenerated: isAiGenerated
        )
    }
}

private extension IMTCPMessageStreamPayload {
    var protobuf: IMRTMessageStreamPayload {
        var value = IMRTMessageStreamPayload()
        value.streamID = streamID
        value.messageID = messageID
        value.conversationID = conversationID
        value.chunkIndex = Int32(chunkIndex)
        if let deltaText { value.deltaText = deltaText }
        value.partialTextLength = Int32(partialTextLength)
        value.state = state.rawValue
        value.serverTimestampMs = serverTimestamp.millisecondsSince1970
        return value
    }
}

private extension IMRTMessageStreamPayload {
    func domainValue() throws -> IMTCPMessageStreamPayload {
        guard let state = MessageStreamLifecycleState(rawValue: state) else {
            throw IMTCPClientError.invalidPayload(.conversationEvent)
        }
        return IMTCPMessageStreamPayload(
            streamID: streamID,
            messageID: messageID,
            conversationID: conversationID,
            chunkIndex: Int(chunkIndex),
            deltaText: hasDeltaText ? deltaText : nil,
            partialTextLength: Int(partialTextLength),
            state: state,
            serverTimestamp: Date(millisecondsSince1970: serverTimestampMs)
        )
    }
}

private extension IMTCPConversationEventPayload {
    var protobuf: IMRTConversationEvent {
        var value = IMRTConversationEvent()
        value.eventType = eventType.rawValue
        value.conversation = conversation.protobuf
        if let message { value.message = message.protobuf }
        if let stream { value.stream = stream.protobuf }
        if let actorUserID { value.actorUserID = actorUserID.uuidString }
        value.serverTimestampMs = serverTimestamp.millisecondsSince1970
        value.messageIds = messageIDs.map(\.uuidString)
        if let favoriteChangedMessageID { value.favoriteChangedMessageID = favoriteChangedMessageID.uuidString }
        if let isFavorited { value.isFavorited = isFavorited }
        if let visibilityAction { value.visibilityAction = visibilityAction.rawValue }
        return value
    }
}

private extension IMRTConversationEvent {
    func domainValue() throws -> IMTCPConversationEventPayload {
        guard let eventType = IMTCPConversationEventType(rawValue: eventType) else {
            throw IMTCPClientError.invalidPayload(.conversationEvent)
        }
        return IMTCPConversationEventPayload(
            eventType: eventType,
            conversation: try conversation.domainValue(),
            message: hasMessage ? try message.domainValue() : nil,
            stream: hasStream ? try stream.domainValue() : nil,
            actorUserID: hasActorUserID ? UUID(uuidString: actorUserID) : nil,
            serverTimestamp: Date(millisecondsSince1970: serverTimestampMs),
            messageIDs: messageIds.compactMap(UUID.init(uuidString:)),
            favoriteChangedMessageID: hasFavoriteChangedMessageID ? UUID(uuidString: favoriteChangedMessageID) : nil,
            isFavorited: hasIsFavorited ? isFavorited : nil,
            visibilityAction: hasVisibilityAction ? IMTCPConversationVisibilityAction(rawValue: visibilityAction) : nil
        )
    }
}

private extension IMConversationSummaryResponseBody {
    var protobuf: IMRTConversationSummary {
        var value = IMRTConversationSummary()
        value.id = id.uuidString
        if let title { value.title = title }
        value.kind = kind
        if let directMessagingState { value.directMessagingState = directMessagingState }
        if let directPeer { value.directPeer = directPeer.protobuf }
        if let notice { value.notice = notice }
        if let avatarPreset { value.avatarPreset = avatarPreset.rawValue }
        value.muteAll = muteAll
        value.memberCount = Int32(memberCount)
        value.memberUserIds = memberUserIDs.map(\.uuidString)
        if let lastMessage { value.lastMessage = lastMessage.protobuf }
        value.lastReadSequence = Int32(lastReadSequence)
        value.unreadCount = Int32(unreadCount)
        value.isPinned = isPinned
        if let pinnedAt { value.pinnedAtMs = pinnedAt.millisecondsSince1970 }
        value.isMuted = isMuted
        if let createdAt { value.createdAtMs = createdAt.millisecondsSince1970 }
        value.updatedAtMs = updatedAt.millisecondsSince1970
        return value
    }
}

private extension IMRTConversationSummary {
    func domainValue() throws -> IMConversationSummaryResponseBody {
        guard let id = UUID(uuidString: id) else {
            throw IMTCPClientError.invalidPayload(.conversationEvent)
        }
        return IMConversationSummaryResponseBody(
            id: id,
            title: hasTitle ? title : nil,
            kind: kind,
            directMessagingState: hasDirectMessagingState ? directMessagingState : nil,
            directPeer: hasDirectPeer ? try directPeer.domainValue() : nil,
            memberCount: Int(memberCount),
            memberUserIDs: memberUserIds.compactMap(UUID.init(uuidString:)),
            notice: hasNotice ? notice : nil,
            avatarPreset: hasAvatarPreset ? IMConversationAvatarPreset(rawValue: avatarPreset) : nil,
            muteAll: muteAll,
            lastMessage: hasLastMessage ? try lastMessage.domainValue() : nil,
            lastReadSequence: Int(lastReadSequence),
            unreadCount: Int(unreadCount),
            isPinned: isPinned,
            pinnedAt: hasPinnedAtMs ? Date(millisecondsSince1970: pinnedAtMs) : nil,
            isMuted: isMuted,
            createdAt: hasCreatedAtMs ? Date(millisecondsSince1970: createdAtMs) : nil,
            updatedAt: Date(millisecondsSince1970: updatedAtMs)
        )
    }
}

private extension IMDirectPeerResponseBody {
    var protobuf: IMRTDirectPeer {
        var value = IMRTDirectPeer()
        value.id = id.uuidString
        value.email = email
        if let displayName { value.displayName = displayName }
        if let avatarPreset { value.avatarPreset = avatarPreset.rawValue }
        return value
    }
}

private extension IMRTDirectPeer {
    func domainValue() throws -> IMDirectPeerResponseBody {
        guard let id = UUID(uuidString: id) else {
            throw IMTCPClientError.invalidPayload(.conversationEvent)
        }
        return IMDirectPeerResponseBody(
            id: id,
            email: email,
            displayName: hasDisplayName ? displayName : nil,
            avatarPreset: hasAvatarPreset ? UserAvatarPreset(rawValue: avatarPreset) : nil
        )
    }
}

private extension IMMessagePreviewResponseBody {
    var protobuf: IMRTMessagePreview {
        var value = IMRTMessagePreview()
        value.id = id.uuidString
        value.senderUserID = senderUserID.uuidString
        value.serverSequence = Int32(serverSequence)
        value.content = content.protobuf
        value.derivedState = derivedState.protobuf
        if let createdAt { value.createdAtMs = createdAt.millisecondsSince1970 }
        return value
    }
}

private extension IMRTMessagePreview {
    func domainValue() throws -> IMMessagePreviewResponseBody {
        guard let id = UUID(uuidString: id),
              let senderUserID = UUID(uuidString: senderUserID)
        else {
            throw IMTCPClientError.invalidPayload(.conversationEvent)
        }
        return IMMessagePreviewResponseBody(
            id: id,
            senderUserID: senderUserID,
            serverSequence: Int(serverSequence),
            content: try content.domainValue(),
            derivedState: try derivedState.domainValue(),
            createdAt: hasCreatedAtMs ? Date(millisecondsSince1970: createdAtMs) : nil
        )
    }
}

private extension IMConversationMessageResponseBody {
    var protobuf: IMRTConversationMessage {
        var value = IMRTConversationMessage()
        value.id = id.uuidString
        value.conversationID = conversationID.uuidString
        value.senderUserID = senderUserID.uuidString
        if let clientMessageID { value.clientMessageID = clientMessageID }
        value.serverSequence = Int32(serverSequence)
        value.content = content.protobuf
        value.derivedState = derivedState.protobuf
        if let createdAt { value.createdAtMs = createdAt.millisecondsSince1970 }
        return value
    }
}

private extension IMRTConversationMessage {
    func domainValue() throws -> IMConversationMessageResponseBody {
        guard let id = UUID(uuidString: id),
              let conversationID = UUID(uuidString: conversationID),
              let senderUserID = UUID(uuidString: senderUserID)
        else {
            throw IMTCPClientError.invalidPayload(.conversationEvent)
        }
        return IMConversationMessageResponseBody(
            id: id,
            conversationID: conversationID,
            senderUserID: senderUserID,
            clientMessageID: hasClientMessageID ? clientMessageID : nil,
            serverSequence: Int(serverSequence),
            content: try content.domainValue(),
            derivedState: try derivedState.domainValue(),
            createdAt: hasCreatedAtMs ? Date(millisecondsSince1970: createdAtMs) : nil
        )
    }
}

private extension IMTCPContactEventPayload {
    var protobuf: IMRTContactEvent {
        var value = IMRTContactEvent()
        value.eventType = eventType.rawValue
        if let request { value.request = request.protobuf }
        if let contact { value.contact = contact.protobuf }
        if let contactUserID { value.contactUserID = contactUserID.uuidString }
        if let actorUserID { value.actorUserID = actorUserID.uuidString }
        value.serverTimestampMs = serverTimestamp.millisecondsSince1970
        return value
    }
}

private extension IMRTContactEvent {
    func domainValue() throws -> IMTCPContactEventPayload {
        guard let eventType = IMTCPContactEventType(rawValue: eventType) else {
            throw IMTCPClientError.invalidPayload(.contactEvent)
        }
        return IMTCPContactEventPayload(
            eventType: eventType,
            request: hasRequest ? try request.domainValue() : nil,
            contact: hasContact ? try contact.domainValue() : nil,
            contactUserID: hasContactUserID ? UUID(uuidString: contactUserID) : nil,
            actorUserID: hasActorUserID ? UUID(uuidString: actorUserID) : nil,
            serverTimestamp: Date(millisecondsSince1970: serverTimestampMs)
        )
    }
}

private extension ContactResponseBody {
    var protobuf: IMRTContact {
        var value = IMRTContact()
        value.id = id.uuidString
        value.email = email
        if let profileDisplayName { value.displayName = profileDisplayName }
        if let avatarPreset { value.avatarPreset = avatarPreset.rawValue }
        if let remark { value.remark = remark }
        if let createdAt { value.createdAtMs = createdAt.millisecondsSince1970 }
        return value
    }
}

private extension IMRTContact {
    func domainValue() throws -> ContactResponseBody {
        guard let id = UUID(uuidString: id) else {
            throw IMTCPClientError.invalidPayload(.contactEvent)
        }
        return ContactResponseBody(
            id: id,
            email: email,
            displayName: hasDisplayName ? displayName : nil,
            avatarPreset: hasAvatarPreset ? UserAvatarPreset(rawValue: avatarPreset) : nil,
            remark: hasRemark ? remark : nil,
            createdAt: hasCreatedAtMs ? Date(millisecondsSince1970: createdAtMs) : nil
        )
    }
}

private extension ContactRequestResponseBody {
    var protobuf: IMRTContactRequest {
        var value = IMRTContactRequest()
        value.id = id.uuidString
        value.requester = requester.protobuf
        value.addressee = addressee.protobuf
        value.status = status.rawValue
        if let message { value.message = message }
        if let requesterRemark { value.requesterRemark = requesterRemark }
        if let addresseeRemark { value.addresseeRemark = addresseeRemark }
        if let createdAt { value.createdAtMs = createdAt.millisecondsSince1970 }
        if let updatedAt { value.updatedAtMs = updatedAt.millisecondsSince1970 }
        if let respondedAt { value.respondedAtMs = respondedAt.millisecondsSince1970 }
        return value
    }
}

private extension IMRTContactRequest {
    func domainValue() throws -> ContactRequestResponseBody {
        guard let id = UUID(uuidString: id),
              let status = ContactRequestStatus(rawValue: status)
        else {
            throw IMTCPClientError.invalidPayload(.contactEvent)
        }
        return ContactRequestResponseBody(
            id: id,
            requester: try requester.domainValue(),
            addressee: try addressee.domainValue(),
            status: status,
            message: hasMessage ? message : nil,
            requesterRemark: hasRequesterRemark ? requesterRemark : nil,
            addresseeRemark: hasAddresseeRemark ? addresseeRemark : nil,
            createdAt: hasCreatedAtMs ? Date(millisecondsSince1970: createdAtMs) : nil,
            updatedAt: hasUpdatedAtMs ? Date(millisecondsSince1970: updatedAtMs) : nil,
            respondedAt: hasRespondedAtMs ? Date(millisecondsSince1970: respondedAtMs) : nil
        )
    }
}

private extension AuthUser {
    var protobuf: IMRTUser {
        var value = IMRTUser()
        value.id = id.uuidString
        value.email = email
        if let displayName { value.displayName = displayName }
        if let avatarPreset { value.avatarPreset = avatarPreset.rawValue }
        return value
    }
}

private extension IMRTUser {
    func domainValue() throws -> AuthUser {
        guard let id = UUID(uuidString: id) else {
            throw IMTCPClientError.invalidPayload(.contactEvent)
        }
        return AuthUser(
            id: id,
            email: email,
            displayName: hasDisplayName ? displayName : nil,
            avatarPreset: hasAvatarPreset ? UserAvatarPreset(rawValue: avatarPreset) : nil
        )
    }
}

private extension IMTCPKickPayload {
    var protobuf: IMRTKick {
        var value = IMRTKick()
        value.reason = reason.rawValue
        value.message = message
        return value
    }
}

private extension IMRTKick {
    var domainValue: IMTCPKickPayload {
        IMTCPKickPayload(
            reason: IMTCPKickReason(rawValue: reason) ?? .protocolError,
            message: message
        )
    }
}

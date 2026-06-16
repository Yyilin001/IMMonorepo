import Foundation

enum IMTCPProtobufCodec {
    static let protocolVersion = IMRealtimeProtocolVersion.current

    static func decodeDomainEvent(_ data: Data) throws -> IMTCPChatDomainEventPayload {
        try IMRTChatDomainEvent(serializedBytes: data).domainValue()
    }

    static func encodeDomainEvent(
        _ payload: IMTCPChatDomainEventPayload,
        requireDeliveryMetadata: Bool = true
    ) throws -> Data {
        try payload.protobuf(requireDeliveryMetadata: requireDeliveryMetadata).serializedData()
    }

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
                throw IMTCPClientError.invalidPayload(type, reason: "payload type mismatch")
            }
            packet.auth = payload.protobuf
        case .authOK:
            guard let payload = payload as? IMTCPAuthAcceptedPayload else {
                throw IMTCPClientError.invalidPayload(type, reason: "payload type mismatch")
            }
            packet.authOk = payload.protobuf
        case .authError:
            guard let payload = payload as? IMTCPAuthErrorPayload else {
                throw IMTCPClientError.invalidPayload(type, reason: "payload type mismatch")
            }
            packet.authError = payload.protobuf
        case .heartbeat:
            guard let payload = payload as? IMTCPHeartbeatPayload else {
                throw IMTCPClientError.invalidPayload(type, reason: "payload type mismatch")
            }
            packet.heartbeat = payload.protobuf
        case .heartbeatAck:
            guard let payload = payload as? IMTCPHeartbeatPayload else {
                throw IMTCPClientError.invalidPayload(type, reason: "payload type mismatch")
            }
            packet.heartbeatAck = payload.protobuf
        case .sendMessage:
            guard let payload = payload as? IMTCPMessagePayload else {
                throw IMTCPClientError.invalidPayload(type, reason: "payload type mismatch")
            }
            packet.sendMessage = payload.protobuf
        case .conversationActivity:
            guard let payload = payload as? IMTCPConversationActivityPayload else {
                throw IMTCPClientError.invalidPayload(type, reason: "payload type mismatch")
            }
            packet.conversationActivity = payload.protobuf
        case .ack:
            guard let payload = payload as? IMTCPAckPayload else {
                throw IMTCPClientError.invalidPayload(type, reason: "payload type mismatch")
            }
            packet.ack = payload.protobuf
        case .domainEvent:
            guard let payload = payload as? IMTCPChatDomainEventPayload else {
                throw IMTCPClientError.invalidPayload(type, reason: "payload type mismatch")
            }
            packet.domainEvent = try payload.protobuf(requireDeliveryMetadata: true)
        case .streamSignal:
            guard let payload = payload as? IMTCPMessageStreamSignalPayload else {
                throw IMTCPClientError.invalidPayload(type, reason: "payload type mismatch")
            }
            packet.streamSignal = payload.protobuf
        case .kick:
            guard let payload = payload as? IMTCPKickPayload else {
                throw IMTCPClientError.invalidPayload(type, reason: "payload type mismatch")
            }
            packet.kick = payload.protobuf
        }

        return try packet.serializedData()
    }

    static func decode(_ data: Data) throws -> IMTCPInboundPacket {
        let packet = try IMRTPacket(serializedBytes: data)
        guard packet.protocolVersion == protocolVersion else {
            throw IMTCPClientError.invalidPacket
        }
        let requestID = packet.hasRequestID ? UUID(uuidString: packet.requestID) : nil
        let timestamp = packet.timestampMs > 0 ? Date(millisecondsSince1970: packet.timestampMs) : nil

        switch packet.body {
        case .auth(let payload):
            return IMTCPInboundPacket(type: .auth, requestID: requestID, timestamp: timestamp, protocolVersion: Int(packet.protocolVersion), payload: try payload.domainValue())
        case .authOk(let payload):
            return IMTCPInboundPacket(type: .authOK, requestID: requestID, timestamp: timestamp, protocolVersion: Int(packet.protocolVersion), payload: try payload.domainValue())
        case .authError(let payload):
            return IMTCPInboundPacket(type: .authError, requestID: requestID, timestamp: timestamp, protocolVersion: Int(packet.protocolVersion), payload: payload.domainValue)
        case .heartbeat(let payload):
            return IMTCPInboundPacket(type: .heartbeat, requestID: requestID, timestamp: timestamp, protocolVersion: Int(packet.protocolVersion), payload: payload.domainValue)
        case .heartbeatAck(let payload):
            return IMTCPInboundPacket(type: .heartbeatAck, requestID: requestID, timestamp: timestamp, protocolVersion: Int(packet.protocolVersion), payload: payload.domainValue)
        case .sendMessage(let payload):
            return IMTCPInboundPacket(type: .sendMessage, requestID: requestID, timestamp: timestamp, protocolVersion: Int(packet.protocolVersion), payload: try payload.domainValue())
        case .conversationActivity(let payload):
            return IMTCPInboundPacket(type: .conversationActivity, requestID: requestID, timestamp: timestamp, protocolVersion: Int(packet.protocolVersion), payload: try payload.domainValue())
        case .ack(let payload):
            return IMTCPInboundPacket(type: .ack, requestID: requestID, timestamp: timestamp, protocolVersion: Int(packet.protocolVersion), payload: payload.domainValue)
        case .domainEvent(let payload):
            return IMTCPInboundPacket(type: .domainEvent, requestID: requestID, timestamp: timestamp, protocolVersion: Int(packet.protocolVersion), payload: try payload.domainValue())
        case .streamSignal(let payload):
            return IMTCPInboundPacket(type: .streamSignal, requestID: requestID, timestamp: timestamp, protocolVersion: Int(packet.protocolVersion), payload: try payload.domainValue())
        case .kick(let payload):
            return IMTCPInboundPacket(type: .kick, requestID: requestID, timestamp: timestamp, protocolVersion: Int(packet.protocolVersion), payload: payload.domainValue)
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
    public let protocolVersion: Int
    public let payload: IMTCPDecodedPayload

    init(type: IMTCPPacketType, requestID: UUID?, timestamp: Date?, protocolVersion: Int, payload: any Sendable) {
        self.type = type
        self.requestID = requestID
        self.timestamp = timestamp
        self.protocolVersion = protocolVersion
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
            appVersion: hasAppVersion ? appVersion : nil
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
    var protobuf: IMRTSendMessageCommand {
        var value = IMRTSendMessageCommand()
        if let clientMessageID { value.clientMessageID = clientMessageID }
        value.conversationID = conversationID
        value.content = content.protobuf
        return value
    }
}

private extension IMRTSendMessageCommand {
    func domainValue() throws -> IMTCPMessagePayload {
        IMTCPMessagePayload(
            clientMessageID: hasClientMessageID ? clientMessageID : nil,
            messageID: nil,
            conversationID: conversationID,
            senderUserID: nil,
            serverSequence: nil,
            serverTimestamp: nil,
            content: try content.domainValue(),
            derivedState: IMMessageDerivedState()
        )
    }
}

private extension IMTCPConversationActivityPayload {
    var protobuf: IMRTConversationActivityCommand {
        var value = IMRTConversationActivityCommand()
        value.conversationID = conversationID
        value.isActive = isActive
        return value
    }
}

private extension IMRTConversationActivityCommand {
    func domainValue() throws -> IMTCPConversationActivityPayload {
        guard UUID(uuidString: conversationID) != nil else {
            throw IMTCPClientError.invalidPayload(.conversationActivity)
        }
        return IMTCPConversationActivityPayload(
            conversationID: conversationID,
            isActive: isActive
        )
    }
}

private extension IMMessageContent {
    var protobuf: IMRTMessageContent {
        var value = IMRTMessageContent()
        switch self {
        case .richText(let body):
            value.richText = body.protobuf
        case .reply(let reference, let body):
            var content = IMRTReplyContent()
            content.reference = reference.protobuf
            content.body = body.protobuf
            value.reply = content
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
        case .richText(let content):
            return .richText(try content.domainValue())
        case .reply(let content):
            return .reply(reference: try content.reference.domainValue(), body: try content.body.domainValue())
        case .image(let asset):
            return .image(try asset.domainValue())
        case .audio(let asset):
            return .audio(try asset.domainValue())
        case .file(let asset):
            return .file(try asset.domainValue())
        case nil:
            throw IMTCPClientError.invalidPayload(.domainEvent)
        }
    }
}

private extension IMRichTextContent {
    var protobuf: IMRTRichTextContent {
        var value = IMRTRichTextContent()
        value.text = text
        value.entities = entities.map(\.protobuf)
        return value
    }
}

private extension IMRTRichTextContent {
    func domainValue() throws -> IMRichTextContent {
        IMRichTextContent(
            text: text,
            entities: try entities.map { try $0.domainValue() }
        )
    }
}

private extension IMTextRange {
    var protobuf: IMRTTextRange {
        var value = IMRTTextRange()
        value.location = Int32(location)
        value.length = Int32(length)
        return value
    }
}

private extension IMRTTextRange {
    var domainValue: IMTextRange {
        IMTextRange(location: Int(location), length: Int(length))
    }
}

private extension IMTextEntity {
    var protobuf: IMRTTextEntity {
        var value = IMRTTextEntity()
        value.range = range.protobuf
        switch self {
        case .link(_, let url):
            var entity = IMRTLinkEntity()
            entity.url = url
            value.link = entity
        case .mention(_, let userID):
            var entity = IMRTMentionEntity()
            entity.userID = userID.uuidString
            value.mention = entity
        case .hashtag(_, let hashtag):
            var entity = IMRTHashtagEntity()
            entity.value = hashtag
            value.hashtag = entity
        case .inlineCode:
            value.inlineCode = IMRTInlineCodeEntity()
        }
        return value
    }
}

private extension IMRTTextEntity {
    func domainValue() throws -> IMTextEntity {
        let range = range.domainValue
        switch body {
        case .link(let entity):
            return .link(range: range, url: entity.url)
        case .mention(let entity):
            guard let userID = UUID(uuidString: entity.userID) else {
                throw IMTCPClientError.invalidPayload(.domainEvent)
            }
            return .mention(range: range, userID: userID)
        case .hashtag(let entity):
            return .hashtag(range: range, value: entity.value)
        case .inlineCode:
            return .inlineCode(range: range)
        case nil:
            throw IMTCPClientError.invalidPayload(.domainEvent)
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
            throw IMTCPClientError.invalidPayload(.domainEvent)
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
            edits: try edits.map { try $0.domainValue() },
            reactions: try reactions.map { try $0.domainValue() },
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
        value.body = body.protobuf
        return value
    }
}

private extension IMRTMessageEdit {
    func domainValue() throws -> MessageEdit {
        MessageEdit(
            editedAt: hasEditedAtMs ? Date(millisecondsSince1970: editedAtMs) : nil,
            body: try body.domainValue()
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
    func domainValue() throws -> MessageReaction {
        let ids = try domainEventUUIDs(actorUserIds)
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
            throw IMTCPClientError.invalidPayload(.domainEvent)
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
            throw IMTCPClientError.invalidPayload(.domainEvent)
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

private extension IMTCPMessageStreamSignalPayload {
    var protobuf: IMRTMessageStreamSignal {
        var value = IMRTMessageStreamSignal()
        value.stream = stream.protobuf
        if let message { value.message = message.protobuf }
        return value
    }
}

private extension IMRTMessageStreamSignal {
    func domainValue() throws -> IMTCPMessageStreamSignalPayload {
        IMTCPMessageStreamSignalPayload(
            stream: try stream.domainValue(),
            message: hasMessage ? try message.domainValue() : nil
        )
    }
}

private extension IMTCPChatDomainEventPayload {
    func protobuf(requireDeliveryMetadata: Bool) throws -> IMRTChatDomainEvent {
        if requireDeliveryMetadata {
            guard let ownerCursor, ownerCursor > 0,
                  let ownerAggregateSequence, ownerAggregateSequence > 0
            else {
                throw IMTCPClientError.invalidPayload(.domainEvent)
            }
        }
        var value = IMRTChatDomainEvent()
        value.eventID = eventID.uuidString
        value.eventType = eventType.rawValue
        value.aggregateType = aggregateType
        value.aggregateID = aggregateID.uuidString
        value.aggregateSequence = aggregateSequence
        value.occurredAtMs = occurredAt.millisecondsSince1970
        if let actorUserID { value.actorUserID = actorUserID.uuidString }
        if let conversation { value.conversation = conversation.protobuf }
        if let timelineNotice { value.timelineNotice = timelineNotice.protobuf }
        value.requiresTimelineNotice = requiresTimelineNotice
        if let ownerCursor { value.ownerCursor = ownerCursor }
        if let ownerAggregateSequence { value.ownerAggregateSequence = ownerAggregateSequence }

        switch body {
        case .messageCreated(let message, let clientMessageID):
            var event = IMRTMessageCreatedEvent()
            event.message = message.protobuf
            if let clientMessageID { event.clientMessageID = clientMessageID }
            value.messageCreated = event
        case .messageEdited(let messageID, let body, let editedAt, let message):
            var event = IMRTMessageEditedEvent()
            event.messageID = messageID.uuidString
            event.body = body.protobuf
            event.editedAtMs = editedAt.millisecondsSince1970
            if let message { event.message = message.protobuf }
            value.messageEdited = event
        case .messageRevoked(let messageID, let revokedAt, let revokedByUserID, let message):
            var event = IMRTMessageRevokedEvent()
            event.messageID = messageID.uuidString
            event.revokedAtMs = revokedAt.millisecondsSince1970
            if let revokedByUserID { event.revokedByUserID = revokedByUserID.uuidString }
            if let message { event.message = message.protobuf }
            value.messageRevoked = event
        case .messageVisibilityChanged(let messageIDs, let message, let visibilityAction):
            var event = IMRTMessageVisibilityChangedEvent()
            event.messageIds = messageIDs.map(\.uuidString)
            if let message { event.message = message.protobuf }
            if let visibilityAction { event.visibilityAction = visibilityAction.rawValue }
            value.messageVisibilityChanged = event
        case .messageFavoriteChanged(let messageID, let isFavorited):
            var event = IMRTMessageFavoriteChangedEvent()
            event.messageID = messageID.uuidString
            event.isFavorited = isFavorited
            value.messageFavoriteChanged = event
        case .messageStream(let stream, let message):
            var event = IMRTMessageStreamEvent()
            event.stream = stream.protobuf
            if let message { event.message = message.protobuf }
            switch eventType {
            case .messageStreamStarted:
                value.messageStreamStarted = event
            case .messageStreamCompleted:
                value.messageStreamCompleted = event
            case .messageStreamFailed:
                value.messageStreamFailed = event
            case .messageStreamCancelled:
                value.messageStreamCancelled = event
            default:
                throw IMTCPClientError.invalidPayload(
                    .domainEvent,
                    reason: "message_stream body requires a durable stream lifecycle event type"
                )
            }
        case .conversationChanged:
            let event = IMRTConversationChangedEvent()
            switch eventType {
            case .conversationCreated:
                value.conversationCreated = event
            case .conversationSettingsChanged:
                value.conversationSettingsChanged = event
            default:
                value.conversationUpdated = event
            }
        case .conversationActivityHint(let hint):
            value.conversationActivityHint = hint.protobuf
        case .conversationRemovedForSelf:
            value.conversationRemovedForSelf = IMRTConversationRemovedForSelfEvent()
        case .conversationVisibilityChanged(let visibilityAction, let messageIDs):
            var event = IMRTConversationVisibilityChangedEvent()
            event.visibilityAction = visibilityAction.rawValue
            event.messageIds = messageIDs.map(\.uuidString)
            value.conversationVisibilityChanged = event
        case .memberChanged(let memberUserIDs):
            var event = IMRTMemberChangedEvent()
            event.memberUserIds = memberUserIDs.map(\.uuidString)
            switch eventType {
            case .memberAdded:
                value.memberAdded = event
            case .memberRemoved:
                value.memberRemoved = event
            default:
                value.memberRoleUpdated = event
            }
        case .contactChanged(let request, let contact, let contactUserID):
            var event = IMRTContactChangedEvent()
            if let request { event.request = request.protobuf }
            if let contact { event.contact = contact.protobuf }
            if let contactUserID { event.contactUserID = contactUserID.uuidString }
            switch eventType {
            case .contactRequestCreated:
                value.contactRequestCreated = event
            case .contactRequestAccepted:
                value.contactRequestAccepted = event
            default:
                value.contactRequestUpdated = event
            }
        }
        return value
    }
}

private func domainEventUUIDs(_ values: [String]) throws -> [UUID] {
    try values.map { value in
        guard let id = UUID(uuidString: value) else {
            throw IMTCPClientError.invalidPayload(.domainEvent)
        }
        return id
    }
}

private func optionalDomainEventUUID(_ hasValue: Bool, _ value: String) throws -> UUID? {
    guard hasValue else { return nil }
    guard let id = UUID(uuidString: value) else {
        throw IMTCPClientError.invalidPayload(.domainEvent)
    }
    return id
}

private func domainEventInt(_ value: UInt64) throws -> Int {
    guard value <= UInt64(Int.max) else {
        throw IMTCPClientError.invalidPayload(.domainEvent, reason: "integer overflow")
    }
    return Int(value)
}

private func requiredNonNegativeSequence(_ hasValue: Bool, _ value: UInt64, field: String) throws -> UInt64 {
    guard hasValue else {
        throw IMTCPClientError.invalidPayload(.domainEvent, reason: "\(field) is missing")
    }
    return value
}

private extension IMRTChatDomainEvent {
    func domainValue() throws -> IMTCPChatDomainEventPayload {
        guard let eventID = UUID(uuidString: eventID),
              let eventType = IMTCPChatDomainEventType(rawValue: eventType),
              let aggregateID = UUID(uuidString: aggregateID),
              hasAggregateSequence,
              aggregateSequence > 0
        else {
            throw IMTCPClientError.invalidPayload(.domainEvent)
        }
        guard !hasOwnerCursor || ownerCursor > 0,
              !hasOwnerAggregateSequence || ownerAggregateSequence > 0
        else {
            throw IMTCPClientError.invalidPayload(.domainEvent)
        }
        let body = try domainBody()
        guard body.matches(eventType: eventType),
              eventType.expectedAggregateType == aggregateType
        else {
            throw IMTCPClientError.invalidPayload(.domainEvent)
        }
        guard !requiresTimelineNotice || hasTimelineNotice else {
            throw IMTCPClientError.invalidPayload(.domainEvent)
        }

        return IMTCPChatDomainEventPayload(
            eventID: eventID,
            eventType: eventType,
            aggregateType: aggregateType,
            aggregateID: aggregateID,
            aggregateSequence: aggregateSequence,
            occurredAt: Date(millisecondsSince1970: occurredAtMs),
            actorUserID: try optionalDomainEventUUID(hasActorUserID, actorUserID),
            conversation: hasConversation ? try conversation.domainValue() : nil,
            timelineNotice: hasTimelineNotice ? try timelineNotice.domainValue() : nil,
            requiresTimelineNotice: requiresTimelineNotice,
            ownerCursor: hasOwnerCursor ? ownerCursor : nil,
            ownerAggregateSequence: hasOwnerAggregateSequence ? ownerAggregateSequence : nil,
            body: body
        )
    }

    private func domainBody() throws -> IMTCPChatDomainEventBody {
        switch body {
        case .messageCreated(let event):
            return .messageCreated(
                message: try event.message.domainValue(),
                clientMessageID: event.hasClientMessageID ? event.clientMessageID : nil
            )
        case .messageEdited(let event):
            guard let messageID = UUID(uuidString: event.messageID) else {
                throw IMTCPClientError.invalidPayload(.domainEvent)
            }
            return .messageEdited(
                messageID: messageID,
                body: try event.body.domainValue(),
                editedAt: Date(millisecondsSince1970: event.editedAtMs),
                message: event.hasMessage ? try event.message.domainValue() : nil
            )
        case .messageRevoked(let event):
            guard let messageID = UUID(uuidString: event.messageID) else {
                throw IMTCPClientError.invalidPayload(.domainEvent)
            }
            return .messageRevoked(
                messageID: messageID,
                revokedAt: Date(millisecondsSince1970: event.revokedAtMs),
                revokedByUserID: try optionalDomainEventUUID(event.hasRevokedByUserID, event.revokedByUserID),
                message: event.hasMessage ? try event.message.domainValue() : nil
            )
        case .messageVisibilityChanged(let event):
            return .messageVisibilityChanged(
                messageIDs: try domainEventUUIDs(event.messageIds),
                message: event.hasMessage ? try event.message.domainValue() : nil,
                visibilityAction: event.hasVisibilityAction ? IMTCPConversationVisibilityAction(rawValue: event.visibilityAction) : nil
            )
        case .messageFavoriteChanged(let event):
            guard let messageID = UUID(uuidString: event.messageID) else {
                throw IMTCPClientError.invalidPayload(.domainEvent)
            }
            return .messageFavoriteChanged(messageID: messageID, isFavorited: event.isFavorited)
        case .messageStreamStarted(let event),
             .messageStreamCompleted(let event),
             .messageStreamFailed(let event),
             .messageStreamCancelled(let event):
            return .messageStream(
                try event.stream.domainValue(),
                message: event.hasMessage ? try event.message.domainValue() : nil
            )
        case .conversationCreated, .conversationUpdated, .conversationSettingsChanged:
            return .conversationChanged
        case .conversationActivityHint(let event):
            return .conversationActivityHint(try event.domainValue())
        case .conversationRemovedForSelf:
            return .conversationRemovedForSelf
        case .conversationVisibilityChanged(let event):
            guard let action = IMTCPConversationVisibilityAction(rawValue: event.visibilityAction) else {
                throw IMTCPClientError.invalidPayload(.domainEvent)
            }
            return .conversationVisibilityChanged(
                visibilityAction: action,
                messageIDs: try domainEventUUIDs(event.messageIds)
            )
        case .memberAdded(let event), .memberRemoved(let event), .memberRoleUpdated(let event):
            return .memberChanged(memberUserIDs: try domainEventUUIDs(event.memberUserIds))
        case .contactRequestCreated(let event), .contactRequestAccepted(let event), .contactRequestUpdated(let event):
            return .contactChanged(
                request: event.hasRequest ? try event.request.domainValue() : nil,
                contact: event.hasContact ? try event.contact.domainValue() : nil,
                contactUserID: try optionalDomainEventUUID(event.hasContactUserID, event.contactUserID)
            )
        case nil:
            throw IMTCPClientError.invalidPayload(.domainEvent)
        }
    }
}

private extension IMTCPChatDomainEventBody {
    func matches(eventType: IMTCPChatDomainEventType) -> Bool {
        switch (self, eventType) {
        case (.messageCreated, .messageCreated),
             (.messageEdited, .messageEdited),
             (.messageRevoked, .messageRevoked),
             (.messageVisibilityChanged, .messageVisibilityChanged),
             (.messageFavoriteChanged, .messageFavoriteChanged),
             (.messageStream, .messageStreamStarted),
             (.messageStream, .messageStreamCompleted),
             (.messageStream, .messageStreamFailed),
             (.messageStream, .messageStreamCancelled),
             (.conversationChanged, .conversationCreated),
             (.conversationChanged, .conversationUpdated),
             (.conversationChanged, .conversationSettingsChanged),
             (.conversationActivityHint, .conversationActivityHint),
             (.conversationRemovedForSelf, .conversationRemovedForSelf),
             (.conversationVisibilityChanged, .conversationVisibilityChanged),
             (.memberChanged, .memberAdded),
             (.memberChanged, .memberRemoved),
             (.memberChanged, .memberRoleUpdated),
             (.contactChanged, .contactRequestCreated),
             (.contactChanged, .contactRequestAccepted),
             (.contactChanged, .contactRequestUpdated):
            true
        default:
            false
        }
    }
}

private extension IMTCPChatDomainEventType {
    var expectedAggregateType: String {
        switch self {
        case .contactRequestCreated, .contactRequestAccepted, .contactRequestUpdated:
            "contact"
        default:
            "conversation"
        }
    }
}

private extension IMConversationActivityHintResponseBody {
    var protobuf: IMRTConversationActivityHintEvent {
        var value = IMRTConversationActivityHintEvent()
        value.messageID = messageID.uuidString
        value.senderUserID = senderUserID.uuidString
        value.serverSequence = serverSequence
        value.timelineSequence = timelineSequence
        value.previewText = previewText
        if let messageCreatedAt {
            value.messageCreatedAtMs = messageCreatedAt.millisecondsSince1970
        }
        value.updatedAtMs = updatedAt.millisecondsSince1970
        return value
    }
}

private extension IMRTConversationActivityHintEvent {
    func domainValue() throws -> IMConversationActivityHintResponseBody {
        guard let messageID = UUID(uuidString: messageID),
              let senderUserID = UUID(uuidString: senderUserID),
              hasServerSequence,
              serverSequence > 0,
              hasTimelineSequence,
              timelineSequence > 0
        else {
            throw IMTCPClientError.invalidPayload(.domainEvent)
        }
        return IMConversationActivityHintResponseBody(
            messageID: messageID,
            senderUserID: senderUserID,
            serverSequence: serverSequence,
            timelineSequence: timelineSequence,
            previewText: previewText,
            messageCreatedAt: hasMessageCreatedAtMs ? Date(millisecondsSince1970: messageCreatedAtMs) : nil,
            updatedAt: Date(millisecondsSince1970: updatedAtMs)
        )
    }
}

private extension IMTimelineNoticeResponseBody {
    var protobuf: IMRTTimelineNotice {
        var value = IMRTTimelineNotice()
        value.id = id.uuidString
        value.conversationID = conversationID.uuidString
        value.timelineSequence = timelineSequence
        value.eventType = eventType
        if let actorUserID { value.actorUserID = actorUserID.uuidString }
        value.targetUserIds = targetUserIDs.map(\.uuidString)
        value.noticeKind = noticeKind
        value.params = params
        value.fallbackText = fallbackText
        value.createdAtMs = createdAt.millisecondsSince1970
        return value
    }
}

private extension IMRTTimelineNotice {
    func domainValue() throws -> IMTimelineNoticeResponseBody {
        guard let id = UUID(uuidString: id),
              let conversationID = UUID(uuidString: conversationID),
              hasTimelineSequence,
              timelineSequence > 0
        else {
            throw IMTCPClientError.invalidPayload(.domainEvent)
        }
        return IMTimelineNoticeResponseBody(
            id: id,
            conversationID: conversationID,
            timelineSequence: timelineSequence,
            eventType: eventType,
            actorUserID: try optionalDomainEventUUID(hasActorUserID, actorUserID),
            targetUserIDs: try domainEventUUIDs(targetUserIds),
            noticeKind: noticeKind,
            params: params,
            fallbackText: fallbackText,
            createdAt: Date(millisecondsSince1970: createdAtMs)
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
        value.lastReadSequence = lastReadSequence
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
            throw IMTCPClientError.invalidPayload(.domainEvent)
        }
        return IMConversationSummaryResponseBody(
            id: id,
            title: hasTitle ? title : nil,
            kind: kind,
            directMessagingState: hasDirectMessagingState ? directMessagingState : nil,
            directPeer: hasDirectPeer ? try directPeer.domainValue() : nil,
            memberCount: Int(memberCount),
            memberUserIDs: try domainEventUUIDs(memberUserIds),
            notice: hasNotice ? notice : nil,
            avatarPreset: hasAvatarPreset ? IMConversationAvatarPreset(rawValue: avatarPreset) : nil,
            muteAll: muteAll,
            lastMessage: hasLastMessage ? try lastMessage.domainValue() : nil,
            lastReadSequence: try requiredNonNegativeSequence(hasLastReadSequence, lastReadSequence, field: "last_read_sequence"),
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
            throw IMTCPClientError.invalidPayload(.domainEvent)
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
        value.serverSequence = UInt64(serverSequence)
        value.timelineSequence = UInt64(timelineSequence)
        value.content = content.protobuf
        value.derivedState = derivedState.protobuf
        if let createdAt { value.createdAtMs = createdAt.millisecondsSince1970 }
        return value
    }
}

private extension IMRTMessagePreview {
    func domainValue() throws -> IMMessagePreviewResponseBody {
        guard let id = UUID(uuidString: id),
              let senderUserID = UUID(uuidString: senderUserID),
              hasServerSequence,
              serverSequence > 0,
              hasTimelineSequence,
              timelineSequence > 0
        else {
            throw IMTCPClientError.invalidPayload(.domainEvent)
        }
        return IMMessagePreviewResponseBody(
            id: id,
            senderUserID: senderUserID,
            serverSequence: serverSequence,
            timelineSequence: timelineSequence,
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
        value.serverSequence = UInt64(serverSequence)
        value.timelineSequence = UInt64(timelineSequence)
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
              let senderUserID = UUID(uuidString: senderUserID),
              hasServerSequence,
              serverSequence > 0,
              hasTimelineSequence,
              timelineSequence > 0
        else {
            throw IMTCPClientError.invalidPayload(.domainEvent)
        }
        return IMConversationMessageResponseBody(
            id: id,
            conversationID: conversationID,
            senderUserID: senderUserID,
            clientMessageID: hasClientMessageID ? clientMessageID : nil,
            serverSequence: serverSequence,
            timelineSequence: timelineSequence,
            content: try content.domainValue(),
            derivedState: try derivedState.domainValue(),
            createdAt: hasCreatedAtMs ? Date(millisecondsSince1970: createdAtMs) : nil
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
            throw IMTCPClientError.invalidPayload(.domainEvent)
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
            throw IMTCPClientError.invalidPayload(.domainEvent)
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
            throw IMTCPClientError.invalidPayload(.domainEvent)
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

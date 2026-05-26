@testable import IMClientKit
@testable import IMApp
import Foundation

func testMessageContent(kind: String, body: [String: String]) -> IMMessageContent {
    switch kind {
    case IMMessageContentType.richText.rawValue:
        return .richText(.plain(body["text"] ?? ""))
    case IMMessageContentType.reply.rawValue:
        return .reply(
            reference: IMReplyReference(
                messageID: body["referenceMessageID"] ?? "",
                senderUserID: body["referenceSenderUserID"].flatMap(UUID.init(uuidString:)),
                previewText: body["referencePreviewText"] ?? ""
            ),
            body: .plain(body["text"] ?? "")
        )
    case IMMessageContentType.image.rawValue:
        return .image(testMediaAsset(kind: .image, body: body))
    case IMMessageContentType.audio.rawValue:
        return .audio(testMediaAsset(kind: .audio, body: body))
    case IMMessageContentType.file.rawValue:
        return .file(testMediaAsset(kind: .file, body: body))
    default:
        return .richText(.plain(body["text"] ?? ""))
    }
}

private func testMediaAsset(kind: IMMediaAssetKind, body: [String: String]) -> IMMediaAsset {
    IMMediaAsset(
        assetID: body["assetID"] ?? "",
        kind: kind,
        mimeType: body["mimeType"] ?? "application/octet-stream",
        byteSize: Int64(body["byteSize"] ?? "") ?? 0,
        filename: body["filename"] ?? "",
        width: Int(body["width"] ?? ""),
        height: Int(body["height"] ?? ""),
        durationMillis: Int(body["durationMillis"] ?? ""),
        previewAssetID: body["previewAssetID"]
    )
}

extension IMTCPMessagePayload {
    init(
        clientMessageID: String?,
        messageID: String?,
        conversationID: String,
        senderUserID: UUID?,
        serverSequence: UInt64?,
        serverTimestamp: Date?,
        kind: String,
        body: [String: String]
    ) {
        self.init(
            clientMessageID: clientMessageID,
            messageID: messageID,
            conversationID: conversationID,
            senderUserID: senderUserID,
            serverSequence: serverSequence,
            serverTimestamp: serverTimestamp,
            content: testMessageContent(kind: kind, body: body)
        )
    }

    var body: [String: String] {
        switch content {
        case .richText(let body):
            return ["text": body.text]
        case .reply(let reference, let body):
            return [
                "text": body.text,
                "referenceMessageID": reference.messageID,
                "referenceSenderUserID": reference.senderUserID?.uuidString ?? "",
                "referencePreviewText": reference.previewText
            ]
        case .image(let asset), .audio(let asset), .file(let asset):
            return mediaBody(asset)
        }
    }

    var kind: String {
        content.type.rawValue
    }
}

enum TestConversationEventType: String {
    case conversationCreated = "conversation_created"
    case membersAdded = "members_added"
    case memberLeft = "member_left"
    case membersUpdated = "members_updated"
    case conversationRemovedForSelf = "conversation_removed_for_self"
    case summaryUpdated = "summary_updated"
    case messageUpdated = "message_updated"
    case messageRecalled = "message_recalled"
    case messageVisibilityChanged = "message_visibility_changed"
    case messageFavoriteChanged = "message_favorite_changed"
    case conversationVisibilityChanged = "conversation_visibility_changed"
    case conversationSettingsChanged = "conversation_settings_changed"
    case inviteChanged = "invite_changed"
    case messageStreamStarted = "message_stream_started"
    case messageStreamChunk = "message_stream_chunk"
    case messageStreamCompleted = "message_stream_completed"
    case messageStreamFailed = "message_stream_failed"
    case messageStreamCancelled = "message_stream_cancelled"
}

struct TestConversationEventPayload {
    let eventType: TestConversationEventType
    let conversation: IMConversationSummaryResponseBody
    let message: IMConversationMessageResponseBody?
    let stream: IMTCPMessageStreamPayload?
    let actorUserID: UUID?
    let serverTimestamp: Date
    let messageIDs: [UUID]
    let favoriteChangedMessageID: UUID?
    let isFavorited: Bool?
    let visibilityAction: IMTCPConversationVisibilityAction?

    init(
        eventType: TestConversationEventType,
        conversation: IMConversationSummaryResponseBody,
        message: IMConversationMessageResponseBody? = nil,
        stream: IMTCPMessageStreamPayload? = nil,
        actorUserID: UUID?,
        serverTimestamp: Date,
        messageIDs: [UUID] = [],
        favoriteChangedMessageID: UUID? = nil,
        isFavorited: Bool? = nil,
        visibilityAction: IMTCPConversationVisibilityAction? = nil
    ) {
        self.eventType = eventType
        self.conversation = conversation
        self.message = message
        self.stream = stream
        self.actorUserID = actorUserID
        self.serverTimestamp = serverTimestamp
        self.messageIDs = messageIDs
        self.favoriteChangedMessageID = favoriteChangedMessageID
        self.isFavorited = isFavorited
        self.visibilityAction = visibilityAction
    }
}

enum TestContactEventType {
    case friendRequestCreated
    case friendRequestAccepted
    case friendRequestDeclined
    case friendRequestCancelled
    case contactRemoved
}

struct TestContactEventPayload {
    let eventType: TestContactEventType
    let request: ContactRequestResponseBody?
    let contact: ContactResponseBody?
    let contactUserID: UUID?
    let actorUserID: UUID?
    let serverTimestamp: Date

    init(
        eventType: TestContactEventType,
        request: ContactRequestResponseBody?,
        contact: ContactResponseBody?,
        contactUserID: UUID?,
        actorUserID: UUID?,
        serverTimestamp: Date
    ) {
        self.eventType = eventType
        self.request = request
        self.contact = contact
        self.contactUserID = contactUserID
        self.actorUserID = actorUserID
        self.serverTimestamp = serverTimestamp
    }

    var domainEventType: IMTCPChatDomainEventType {
        switch eventType {
        case .friendRequestCreated:
            return .contactRequestCreated
        case .friendRequestAccepted:
            return .contactRequestAccepted
        case .friendRequestDeclined, .friendRequestCancelled, .contactRemoved:
            return .contactRequestUpdated
        }
    }

    var domainEventPayload: IMTCPChatDomainEventPayload {
        IMTCPChatDomainEventPayload(
            eventID: UUID(),
            eventType: domainEventType,
            aggregateType: "contact",
            aggregateID: contactUserID
                ?? contact?.id
                ?? request?.id
                ?? actorUserID
                ?? UUID(),
            aggregateSequence: 0,
            occurredAt: serverTimestamp,
            actorUserID: actorUserID,
            conversation: nil,
            body: .contactChanged(
                request: request,
                contact: contact,
                contactUserID: contactUserID
            )
        )
    }
}

extension ContactStore {
    func apply(
        event payload: TestContactEventPayload,
        currentUserID: UUID?,
        isRelevant: (ContactRequestResponseBody, UUID) -> Bool,
        normalize: ([ContactRequestResponseBody], UUID) -> [ContactRequestResponseBody],
        sortPendingNewestFirst: (ContactRequestResponseBody, ContactRequestResponseBody) -> Bool
    ) -> ContactStore.EventApplyResult {
        apply(
            domainEvent: payload.domainEventPayload,
            currentUserID: currentUserID,
            isRelevant: isRelevant,
            normalize: normalize,
            sortPendingNewestFirst: sortPendingNewestFirst
        )
    }
}

extension IMTCPConnectionEvent {
    static func conversationEvent(
        requestID: UUID?,
        payload: TestConversationEventPayload
    ) -> IMTCPConnectionEvent {
        let eventID = requestID ?? payload.message?.id ?? UUID()
        let body: IMTCPChatDomainEventBody
        let eventType: IMTCPChatDomainEventType

        switch payload.eventType {
        case .messageUpdated:
            if let message = payload.message {
                eventType = .messageEdited
                body = .messageEdited(
                    messageID: message.id,
                    body: message.content.richTextForDomainEvent,
                    editedAt: payload.serverTimestamp,
                    message: message
                )
            } else {
                eventType = .conversationUpdated
                body = .conversationChanged
            }
        case .messageRecalled:
            if let message = payload.message {
                eventType = .messageRevoked
                body = .messageRevoked(
                    messageID: message.id,
                    revokedAt: payload.serverTimestamp,
                    revokedByUserID: payload.actorUserID,
                    message: message
                )
            } else {
                eventType = .conversationUpdated
                body = .conversationChanged
            }
        case .messageVisibilityChanged:
            eventType = .messageVisibilityChanged
            body = .messageVisibilityChanged(
                messageIDs: payload.messageIDs,
                message: payload.message,
                visibilityAction: payload.visibilityAction
            )
        case .messageFavoriteChanged:
            eventType = .messageFavoriteChanged
            body = .messageFavoriteChanged(
                messageID: payload.favoriteChangedMessageID ?? payload.message?.id ?? UUID(),
                isFavorited: payload.isFavorited ?? false
            )
        case .conversationRemovedForSelf:
            eventType = .conversationRemovedForSelf
            body = .conversationRemovedForSelf
        case .conversationSettingsChanged:
            eventType = .conversationSettingsChanged
            body = .conversationChanged
        case .conversationVisibilityChanged:
            eventType = .conversationVisibilityChanged
            body = .conversationVisibilityChanged(
                visibilityAction: payload.visibilityAction ?? .conversationCleared,
                messageIDs: payload.messageIDs
            )
        case .membersAdded:
            eventType = .memberAdded
            body = .memberChanged(memberUserIDs: [])
        case .memberLeft:
            eventType = .memberRemoved
            body = .memberChanged(memberUserIDs: [])
        case .membersUpdated:
            eventType = .memberRoleUpdated
            body = .memberChanged(memberUserIDs: [])
        case .messageStreamStarted:
            eventType = .messageStreamStarted
            body = .messageStream(payload.stream ?? emptyStreamPayload(payload), message: payload.message)
        case .messageStreamChunk:
            eventType = .messageStreamChunk
            body = .messageStream(payload.stream ?? emptyStreamPayload(payload), message: payload.message)
        case .messageStreamCompleted:
            eventType = .messageStreamCompleted
            body = .messageStream(payload.stream ?? emptyStreamPayload(payload), message: payload.message)
        case .messageStreamFailed:
            eventType = .messageStreamFailed
            body = .messageStream(payload.stream ?? emptyStreamPayload(payload), message: payload.message)
        case .messageStreamCancelled:
            eventType = .messageStreamCancelled
            body = .messageStream(payload.stream ?? emptyStreamPayload(payload), message: payload.message)
        case .conversationCreated, .summaryUpdated, .inviteChanged:
            eventType = .conversationUpdated
            body = .conversationChanged
        }

        return .domainEvent(
            requestID: requestID,
            payload: IMTCPChatDomainEventPayload(
                eventID: eventID,
                eventType: eventType,
                aggregateType: "conversation",
                aggregateID: payload.conversation.id,
                aggregateSequence: UInt64(payload.message?.serverSequence ?? 0),
                occurredAt: payload.serverTimestamp,
                actorUserID: payload.actorUserID,
                conversation: payload.conversation,
                body: body
            )
        )
    }

    static func message(
        requestID: UUID?,
        payload: IMTCPMessagePayload
    ) -> IMTCPConnectionEvent {
        let messageID = payload.messageID.flatMap(UUID.init(uuidString:)) ?? UUID()
        let conversationID = UUID(uuidString: payload.conversationID) ?? UUID()
        let senderUserID = payload.senderUserID ?? UUID()
        let occurredAt = payload.serverTimestamp ?? Date()
        let message = IMConversationMessageResponseBody(
            id: messageID,
            conversationID: conversationID,
            senderUserID: senderUserID,
            clientMessageID: payload.clientMessageID,
            serverSequence: Int(payload.serverSequence ?? 0),
            content: payload.content,
            derivedState: payload.derivedState,
            createdAt: occurredAt
        )

        return .domainEvent(
            requestID: requestID,
            payload: IMTCPChatDomainEventPayload(
                eventID: messageID,
                eventType: .messageCreated,
                aggregateType: "conversation",
                aggregateID: conversationID,
                aggregateSequence: payload.serverSequence ?? 0,
                occurredAt: occurredAt,
                actorUserID: payload.senderUserID,
                conversation: nil,
                body: .messageCreated(message: message, clientMessageID: payload.clientMessageID)
            )
        )
    }
}

private extension IMMessageContent {
    var richTextForDomainEvent: IMRichTextContent {
        switch self {
        case .richText(let body):
            return body
        case .reply(_, let body):
            return body
        default:
            return .plain(textValue ?? "")
        }
    }
}

private func emptyStreamPayload(_ payload: TestConversationEventPayload) -> IMTCPMessageStreamPayload {
    IMTCPMessageStreamPayload(
        streamID: "",
        messageID: payload.message?.id.uuidString ?? "",
        conversationID: payload.conversation.id.uuidString,
        chunkIndex: 0,
        partialTextLength: 0,
        state: .failed,
        serverTimestamp: payload.serverTimestamp
    )
}

extension IMMessagePreviewResponseBody {
    init(
        id: UUID,
        senderUserID: UUID,
        serverSequence: Int,
        kind: String,
        body: [String: String],
        createdAt: Date?
    ) {
        self.init(
            id: id,
            senderUserID: senderUserID,
            serverSequence: serverSequence,
            content: testMessageContent(kind: kind, body: body),
            createdAt: createdAt
        )
    }

    var body: [String: String] {
        switch content {
        case .richText(let body):
            return ["text": body.text]
        case .reply(let reference, let body):
            return [
                "text": body.text,
                "referenceMessageID": reference.messageID,
                "referenceSenderUserID": reference.senderUserID?.uuidString ?? "",
                "referencePreviewText": reference.previewText
            ]
        case .image(let asset), .audio(let asset), .file(let asset):
            return mediaBody(asset)
        }
    }

    var kind: String {
        content.type.rawValue
    }
}

extension IMConversationMessageResponseBody {
    init(
        id: UUID,
        conversationID: UUID,
        senderUserID: UUID,
        clientMessageID: String? = nil,
        serverSequence: Int,
        kind: String,
        body: [String: String],
        createdAt: Date?
    ) {
        self.init(
            id: id,
            conversationID: conversationID,
            senderUserID: senderUserID,
            clientMessageID: clientMessageID,
            serverSequence: serverSequence,
            content: testMessageContent(kind: kind, body: body),
            createdAt: createdAt
        )
    }

    var body: [String: String] {
        switch content {
        case .richText(let body):
            return ["text": body.text]
        case .reply(let reference, let body):
            return [
                "text": body.text,
                "referenceMessageID": reference.messageID,
                "referenceSenderUserID": reference.senderUserID?.uuidString ?? "",
                "referencePreviewText": reference.previewText
            ]
        case .image(let asset), .audio(let asset), .file(let asset):
            return mediaBody(asset)
        }
    }

    var kind: String {
        content.type.rawValue
    }
}

private func mediaBody(_ asset: IMMediaAsset) -> [String: String] {
    var body: [String: String] = [
        "assetID": asset.assetID,
        "mimeType": asset.mimeType,
        "byteSize": String(asset.byteSize),
        "filename": asset.filename
    ]
    if let width = asset.width {
        body["width"] = String(width)
    }
    if let height = asset.height {
        body["height"] = String(height)
    }
    if let durationMillis = asset.durationMillis {
        body["durationMillis"] = String(durationMillis)
    }
    if let previewAssetID = asset.previewAssetID {
        body["previewAssetID"] = previewAssetID
    }
    return body
}

extension IMCachedMessageState {
    init(
        id: String,
        conversationID: String,
        clientMessageID: String?,
        serverMessageID: String?,
        senderUserID: UUID?,
        serverSequence: UInt64?,
        kind: String,
        text: String,
        direction: IMMessageDirection,
        createdAt: Date,
        deliveryState: IMMessageDeliveryState
    ) {
        self.init(
            id: id,
            conversationID: conversationID,
            clientMessageID: clientMessageID,
            serverMessageID: serverMessageID,
            senderUserID: senderUserID,
            serverSequence: serverSequence,
            content: testMessageContent(kind: kind, body: ["text": text]),
            direction: direction,
            createdAt: createdAt,
            deliveryState: deliveryState
        )
    }
}

extension IMConversationCacheSnapshot {
    init(
        conversations: [IMCachedConversationState],
        selectedConversationID: String?,
        lastSummaryRefreshAt: Date?,
        summarySyncToken: String? = nil
    ) {
        self.init(
            metadata: IMCacheMetadataState(
                selectedConversationID: selectedConversationID,
                lastSummaryRefreshAt: lastSummaryRefreshAt,
                summarySyncToken: summarySyncToken
            ),
            conversations: conversations,
            cursors: conversations.map { conversation in
                IMSyncCursorState(
                    conversationID: conversation.id,
                    hasLoadedMessages: conversation.hasLoadedMessages,
                    latestSyncedServerSequence: conversation.latestSyncedServerSequence,
                    oldestLoadedServerSequence: conversation.oldestLoadedServerSequence
                )
            }
        )
    }
}

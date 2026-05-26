@testable import IMClientKit
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

extension SessionClient {
    func fetchIMConversations() async throws -> [IMConversationSummaryResponseBody] {
        try await fetchIMConversationSummaries().items
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

extension IMConversationStore {
    func applyTestDomainMessage(_ payload: IMTCPMessagePayload, currentUserID: UUID) {
        guard let conversationID = UUID(uuidString: payload.conversationID),
              let senderUserID = payload.senderUserID
        else {
            return
        }
        let messageID = payload.messageID.flatMap(UUID.init(uuidString:)) ?? UUID()
        let serverSequence = payload.serverSequence ?? 1
        _ = applyDomainEvent(
            IMTCPChatDomainEventPayload(
                eventID: messageID,
                eventType: .messageCreated,
                aggregateType: "conversation",
                aggregateID: conversationID,
                aggregateSequence: serverSequence,
                occurredAt: payload.serverTimestamp ?? Date(),
                actorUserID: senderUserID,
                conversation: nil,
                body: .messageCreated(
                    message: IMConversationMessageResponseBody(
                        id: messageID,
                        conversationID: conversationID,
                        senderUserID: senderUserID,
                        clientMessageID: payload.clientMessageID,
                        serverSequence: Int(serverSequence),
                        content: payload.content,
                        derivedState: payload.derivedState,
                        createdAt: payload.serverTimestamp
                    ),
                    clientMessageID: payload.clientMessageID
                )
            ),
            currentUserID: currentUserID
        )
    }

    func applyTestConversationEvent(
        _ payload: TestConversationEventPayload,
        currentUserID: UUID
    ) -> IMConversationEventApplyOutcome {
        applyDomainEvent(payload.domainEventPayload(), currentUserID: currentUserID)
    }

    func applyRecalledMessage(_ response: IMConversationMessageResponseBody, currentUserID: UUID) {
        applyUpdatedMessage(response, currentUserID: currentUserID)
    }
}

private extension TestConversationEventPayload {
    func domainEventPayload() -> IMTCPChatDomainEventPayload {
        IMTCPChatDomainEventPayload(
            eventID: UUID(),
            eventType: domainEventType,
            aggregateType: "conversation",
            aggregateID: conversation.id,
            aggregateSequence: UInt64(message?.serverSequence ?? conversation.lastMessage?.serverSequence ?? 0),
            occurredAt: serverTimestamp,
            actorUserID: actorUserID,
            conversation: conversation,
            body: domainEventBody
        )
    }

    var domainEventType: IMTCPChatDomainEventType {
        switch eventType {
        case .conversationCreated:
            return .conversationCreated
        case .membersAdded:
            return .memberAdded
        case .memberLeft:
            return .memberRemoved
        case .membersUpdated:
            return .memberRoleUpdated
        case .conversationRemovedForSelf:
            return .conversationRemovedForSelf
        case .summaryUpdated:
            return .conversationUpdated
        case .messageUpdated:
            return .messageEdited
        case .messageRecalled:
            return .messageRevoked
        case .messageVisibilityChanged:
            return .messageVisibilityChanged
        case .messageFavoriteChanged:
            return .messageFavoriteChanged
        case .conversationVisibilityChanged:
            return .conversationVisibilityChanged
        case .conversationSettingsChanged, .inviteChanged:
            return .conversationSettingsChanged
        case .messageStreamStarted:
            return .messageStreamStarted
        case .messageStreamChunk:
            return .messageStreamChunk
        case .messageStreamCompleted:
            return .messageStreamCompleted
        case .messageStreamFailed:
            return .messageStreamFailed
        case .messageStreamCancelled:
            return .messageStreamCancelled
        }
    }

    var domainEventBody: IMTCPChatDomainEventBody {
        switch eventType {
        case .messageUpdated:
            return .messageEdited(
                messageID: message?.id ?? UUID(),
                body: message.flatMap { richTextBody($0.content) } ?? .plain(message?.content.previewText ?? ""),
                editedAt: message?.derivedState.edits.last?.editedAt ?? serverTimestamp,
                message: message
            )
        case .messageRecalled:
            return .messageRevoked(
                messageID: message?.id ?? UUID(),
                revokedAt: serverTimestamp,
                revokedByUserID: actorUserID,
                message: message
            )
        case .messageVisibilityChanged:
            return .messageVisibilityChanged(
                messageIDs: messageIDs,
                message: message,
                visibilityAction: visibilityAction
            )
        case .messageFavoriteChanged:
            return .messageFavoriteChanged(
                messageID: favoriteChangedMessageID ?? message?.id ?? UUID(),
                isFavorited: isFavorited ?? false
            )
        case .conversationRemovedForSelf:
            return .conversationRemovedForSelf
        case .conversationVisibilityChanged:
            return .conversationVisibilityChanged(
                visibilityAction: visibilityAction ?? .conversationCleared,
                messageIDs: messageIDs
            )
        case .membersAdded, .memberLeft, .membersUpdated:
            return .memberChanged(memberUserIDs: conversation.memberUserIDs)
        case .messageStreamStarted,
             .messageStreamChunk,
             .messageStreamCompleted,
             .messageStreamFailed,
             .messageStreamCancelled:
            return .messageStream(stream ?? emptyStreamPayload(), message: message)
        case .conversationCreated, .summaryUpdated, .conversationSettingsChanged, .inviteChanged:
            return .conversationChanged
        }
    }

    func emptyStreamPayload() -> IMTCPMessageStreamPayload {
        IMTCPMessageStreamPayload(
            streamID: "",
            messageID: message?.id.uuidString ?? "",
            conversationID: conversation.id.uuidString,
            chunkIndex: 0,
            partialTextLength: 0,
            state: .streaming,
            serverTimestamp: serverTimestamp
        )
    }

    func richTextBody(_ content: IMMessageContent) -> IMRichTextContent? {
        switch content {
        case .richText(let body), .reply(_, let body):
            return body
        case .image, .audio, .file:
            return nil
        }
    }
}

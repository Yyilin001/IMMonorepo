@testable import IMClientKit
import Foundation

func testMessageContent(kind: String, body: [String: String]) -> IMMessageContent {
    switch kind {
    case IMMessageContentType.text.rawValue:
        return .text(body["text"] ?? "")
    case IMMessageContentType.reply.rawValue:
        return .reply(
            reference: IMReplyReference(
                messageID: body["referenceMessageID"] ?? "",
                senderUserID: body["referenceSenderUserID"].flatMap(UUID.init(uuidString:)),
                previewText: body["referencePreviewText"] ?? ""
            ),
            text: body["text"] ?? ""
        )
    case IMMessageContentType.recalled.rawValue:
        return .recalled
    case IMMessageContentType.system.rawValue:
        return .system(.legacyText(body["text"] ?? ""))
    default:
        return .text(body["text"] ?? "")
    }
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
        case .text(let text):
            return ["text": text]
        case .reply(let reference, let text):
            return [
                "text": text,
                "referenceMessageID": reference.messageID,
                "referenceSenderUserID": reference.senderUserID?.uuidString ?? "",
                "referencePreviewText": reference.previewText
            ]
        case .recalled:
            return [:]
        case .system(let event):
            return ["text": event.displayText]
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
        case .text(let text):
            return ["text": text]
        case .reply(let reference, let text):
            return [
                "text": text,
                "referenceMessageID": reference.messageID,
                "referenceSenderUserID": reference.senderUserID?.uuidString ?? "",
                "referencePreviewText": reference.previewText
            ]
        case .recalled:
            return [:]
        case .system(let event):
            return ["text": event.displayText]
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
        case .text(let text):
            return ["text": text]
        case .reply(let reference, let text):
            return [
                "text": text,
                "referenceMessageID": reference.messageID,
                "referenceSenderUserID": reference.senderUserID?.uuidString ?? "",
                "referencePreviewText": reference.previewText
            ]
        case .recalled:
            return [:]
        case .system(let event):
            return ["text": event.displayText]
        }
    }

    var kind: String {
        content.type.rawValue
    }
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

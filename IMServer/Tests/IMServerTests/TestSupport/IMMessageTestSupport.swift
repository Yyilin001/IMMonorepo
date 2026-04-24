@testable import IMServer
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

extension ConversationMessage {
    convenience init(
        id: UUID? = nil,
        conversationID: UUID,
        senderUserID: UUID,
        serverSequence: Int,
        clientMessageID: String? = nil,
        kind: String,
        body: [String: String]
    ) throws {
        try self.init(
            id: id,
            conversationID: conversationID,
            senderUserID: senderUserID,
            serverSequence: serverSequence,
            clientMessageID: clientMessageID,
            content: testMessageContent(kind: kind, body: body)
        )
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
}

extension IMMessagePreviewResponse {
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
}

extension IMMessageResponse {
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
}

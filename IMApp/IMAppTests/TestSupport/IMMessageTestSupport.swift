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
    case IMMessageContentType.image.rawValue:
        return .image(testMediaAsset(kind: .image, body: body))
    case IMMessageContentType.audio.rawValue:
        return .audio(testMediaAsset(kind: .audio, body: body))
    case IMMessageContentType.file.rawValue:
        return .file(testMediaAsset(kind: .file, body: body))
    default:
        return .text(body["text"] ?? "")
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

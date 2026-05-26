@testable import IMServer
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
        case .richText(let body):
            return ["text": body.text]
        case .reply(let reference, let body):
            return [
                "text": body.text,
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
}

extension IMMessagePreviewResponse {
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
        case .recalled:
            return [:]
        case .system(let event):
            return ["text": event.displayText]
        case .image(let asset), .audio(let asset), .file(let asset):
            return mediaBody(asset)
        }
    }
}

extension IMMessageResponse {
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
        case .recalled:
            return [:]
        case .system(let event):
            return ["text": event.displayText]
        case .image(let asset), .audio(let asset), .file(let asset):
            return mediaBody(asset)
        }
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

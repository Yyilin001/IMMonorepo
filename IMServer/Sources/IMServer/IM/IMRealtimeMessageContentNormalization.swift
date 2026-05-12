import Fluent
import Vapor

extension IMRealtimeMessageService {
    func normalizedContent(from content: IMMessageContent) throws -> IMMessageContent {
        switch content {
        case .text(let rawText):
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw IMRealtimeMessageError.emptyTextBody
            }
            return .text(text)
        case .reply(let reference, let rawText):
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            let referenceMessageID = reference.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let referencePreview = reference.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw IMRealtimeMessageError.emptyTextBody
            }
            guard !referenceMessageID.isEmpty, !referencePreview.isEmpty else {
                throw IMRealtimeMessageError.invalidReplyReference
            }
            return .reply(
                reference: IMReplyReference(
                    messageID: referenceMessageID,
                    senderUserID: reference.senderUserID,
                    previewText: referencePreview
                ),
                text: text
            )
        case .image(let asset), .audio(let asset), .file(let asset):
            return try normalizedMediaContent(content.type, asset: asset)
        case .recalled, .system:
            throw IMRealtimeMessageError.unsupportedMessageContent
        }
    }

    func normalizedMediaContent(
        _ type: IMMessageContentType,
        asset: IMMediaAsset
    ) throws -> IMMessageContent {
        let normalizedAssetID = asset.assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMimeType = asset.mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFilename = asset.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAssetID.isEmpty,
              !normalizedMimeType.isEmpty,
              !normalizedFilename.isEmpty,
              asset.byteSize >= 0
        else {
            throw IMRealtimeMessageError.unsupportedMessageContent
        }

        let normalizedAsset = IMMediaAsset(
            assetID: normalizedAssetID,
            kind: asset.kind,
            mimeType: normalizedMimeType,
            byteSize: asset.byteSize,
            filename: normalizedFilename,
            width: asset.width,
            height: asset.height,
            durationMillis: asset.durationMillis,
            previewAssetID: asset.previewAssetID?.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        switch type {
        case .image:
            return .image(normalizedAsset)
        case .audio:
            return .audio(normalizedAsset)
        case .file:
            return .file(normalizedAsset)
        case .text, .reply, .recalled, .system:
            throw IMRealtimeMessageError.unsupportedMessageContent
        }
    }

    func canonicalizeReplyReferenceIfNeeded(
        _ content: IMMessageContent,
        conversationID: UUID,
        on database: any Database
    ) async throws -> IMMessageContent {
        guard case .reply(let reference, _) = content,
              let replyMessageID = UUID(uuidString: reference.messageID)
        else {
            if case .reply = content {
                throw IMRealtimeMessageError.invalidReplyReference
            }
            return content
        }

        guard let referencedMessage = try await ConversationMessage.query(on: database)
            .filter(\.$id == replyMessageID)
            .filter(\.$conversation.$id == conversationID)
            .first()
        else {
            throw IMRealtimeMessageError.invalidReplyReference
        }

        let canonicalPreview = try canonicalReplyReferencePreview(
            for: referencedMessage.decodedContent()
        )
        guard case .reply(_, let text) = content else {
            return content
        }

        return .reply(
            reference: IMReplyReference(
                messageID: replyMessageID.uuidString,
                senderUserID: referencedMessage.$sender.id,
                previewText: canonicalPreview
            ),
            text: text
        )
    }

    func canonicalReplyReferencePreview(for content: IMMessageContent) throws -> String {
        switch content {
        case .recalled:
            return "原消息已撤回"
        case .text, .reply, .system, .image, .audio, .file:
            let preview = content.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            return preview.isEmpty ? "原消息暂不可用" : preview
        }
    }
}

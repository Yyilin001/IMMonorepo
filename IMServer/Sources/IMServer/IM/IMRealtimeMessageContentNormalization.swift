import Fluent
import Vapor

extension IMRealtimeMessageService {
    func normalizedContent(from content: IMMessageContent) throws -> IMMessageContent {
        switch content {
        case .richText(let body):
            return .richText(try normalizedRichText(body))
        case .reply(let reference, let rawBody):
            let body = try normalizedRichText(rawBody)
            let referenceMessageID = reference.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let referencePreview = reference.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !referenceMessageID.isEmpty, !referencePreview.isEmpty else {
                throw IMRealtimeMessageError.invalidReplyReference
            }
            return .reply(
                reference: IMReplyReference(
                    messageID: referenceMessageID,
                    senderUserID: reference.senderUserID,
                    previewText: referencePreview
                ),
                body: body
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
        case .richText, .reply, .recalled, .system:
            throw IMRealtimeMessageError.unsupportedMessageContent
        }
    }

    func validateMentionTargets(in content: IMMessageContent, memberUserIDs: Set<UUID>) throws {
        let entities: [IMTextEntity]
        switch content {
        case .richText(let body):
            entities = body.entities
        case .reply(_, let body):
            entities = body.entities
        case .image, .audio, .file, .recalled, .system:
            return
        }

        for entity in entities {
            if case .mention(_, let userID) = entity, !memberUserIDs.contains(userID) {
                throw IMRealtimeMessageError.unsupportedMessageContent
            }
        }
    }

    func normalizedRichTextForCommand(_ body: IMRichTextContent) throws -> IMRichTextContent {
        try normalizedRichText(body)
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
        guard case .reply(_, let body) = content else {
            return content
        }

        return .reply(
            reference: IMReplyReference(
                messageID: replyMessageID.uuidString,
                senderUserID: referencedMessage.$sender.id,
                previewText: canonicalPreview
            ),
            body: body
        )
    }

    func canonicalReplyReferencePreview(for content: IMMessageContent) throws -> String {
        switch content {
        case .recalled:
            return "原消息已撤回"
        case .richText, .reply, .system, .image, .audio, .file:
            let preview = content.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            return preview.isEmpty ? "原消息暂不可用" : preview
        }
    }

    private func normalizedRichText(_ body: IMRichTextContent) throws -> IMRichTextContent {
        let text = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw IMRealtimeMessageError.emptyTextBody
        }
        guard text == body.text || body.entities.isEmpty else {
            throw IMRealtimeMessageError.unsupportedMessageContent
        }

        try validateEntities(body.entities, in: text)
        return IMRichTextContent(text: text, entities: body.entities)
    }

    private func validateEntities(_ entities: [IMTextEntity], in text: String) throws {
        let utf16Count = text.utf16.count
        var occupiedRanges: [Range<Int>] = []

        for entity in entities {
            let range = entity.range
            guard range.location >= 0,
                  range.length > 0,
                  range.location <= utf16Count,
                  range.location + range.length <= utf16Count,
                  utf16Range(range, in: text) != nil
            else {
                throw IMRealtimeMessageError.unsupportedMessageContent
            }

            let candidateRange = range.location..<(range.location + range.length)
            guard !occupiedRanges.contains(where: { $0.overlaps(candidateRange) }) else {
                throw IMRealtimeMessageError.unsupportedMessageContent
            }
            occupiedRanges.append(candidateRange)

            switch entity {
            case .link(_, let url):
                guard let components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
                      components.scheme == "http" || components.scheme == "https",
                      components.host?.isEmpty == false
                else {
                    throw IMRealtimeMessageError.unsupportedMessageContent
                }
            case .mention:
                continue
            case .hashtag(let range, let value):
                let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedValue.isEmpty,
                      substring(for: range, in: text).trimmingCharacters(in: CharacterSet(charactersIn: "#")).caseInsensitiveCompare(normalizedValue) == .orderedSame
                else {
                    throw IMRealtimeMessageError.unsupportedMessageContent
                }
            case .inlineCode:
                continue
            }
        }
    }

    private func utf16Range(_ range: IMTextRange, in text: String) -> Range<String.Index>? {
        let lowerUTF16 = text.utf16.index(text.utf16.startIndex, offsetBy: range.location)
        let upperUTF16 = text.utf16.index(text.utf16.startIndex, offsetBy: range.location + range.length)
        guard let lower = String.Index(lowerUTF16, within: text),
              let upper = String.Index(upperUTF16, within: text),
              lower <= upper
        else {
            return nil
        }
        return lower..<upper
    }

    private func substring(for range: IMTextRange, in text: String) -> String {
        guard let stringRange = utf16Range(range, in: text) else {
            return ""
        }
        return String(text[stringRange])
    }
}

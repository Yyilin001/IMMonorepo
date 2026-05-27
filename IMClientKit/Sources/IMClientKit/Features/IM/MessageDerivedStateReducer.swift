import Foundation

struct MessageDerivedStateReducer {
    func resolveReplyReference(
        for message: IMConversationMessage,
        in messages: [IMConversationMessage]
    ) -> IMReplyReferenceResolution? {
        let aggregate = message.aggregate
        guard case .reply(let reference, _) = aggregate.primaryContent else {
            return nil
        }

        if let referencedMessage = messages.first(where: {
            $0.serverMessageID == reference.messageID || $0.id == reference.messageID
        }) {
            if referencedMessage.aggregate.derivedState.isRecalled {
                return IMReplyReferenceResolution(
                    state: .recalled,
                    text: "原消息已撤回"
                )
            }

            let preview = referencedMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return IMReplyReferenceResolution(
                state: .loaded,
                text: preview.isEmpty ? "原消息暂不可用" : preview
            )
        }

        let fallback = reference.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        return IMReplyReferenceResolution(
            state: .unavailable,
            text: fallback.isEmpty ? "原消息暂不可用" : fallback
        )
    }

    func mergedSummaryPreviewText(
        existing: IMConversation?,
        responseLastMessage: IMMessagePreviewResponseBody?
    ) -> String {
        let latestLoadedMessage = existing?.messages.last

        guard let responseLastMessage else {
            return latestLoadedMessage?.text
                ?? existing?.lastMessagePreviewText
                ?? "暂无消息"
        }

        let responsePreview = responseLastMessage.content
            .presentation(derivedState: responseLastMessage.derivedState)
            .previewText

        guard let latestLoadedMessage else {
            return responsePreview
        }

        let responseMessageID = responseLastMessage.id.uuidString
        let responseServerSequence = UInt64(responseLastMessage.serverSequence)

        if latestLoadedMessage.serverMessageID == responseMessageID
            || latestLoadedMessage.id == responseMessageID
            || latestLoadedMessage.serverSequence == responseServerSequence {
            return responsePreview
        }

        if latestLoadedMessage.serverSequence > responseServerSequence {
            return latestLoadedMessage.text
        }

        return responsePreview
    }
}

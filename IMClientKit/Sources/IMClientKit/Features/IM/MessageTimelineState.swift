import Foundation

struct MessageTimelineState {
    func latestPreviewText(
        in messages: [IMConversationMessage],
        fallback: String
    ) -> String {
        messages.last?.text ?? fallback
    }

    func latestUpdatedAt(
        in messages: [IMConversationMessage],
        fallback: Date
    ) -> Date {
        messages.last?.createdAt ?? fallback
    }

    func localMessageID(
        matchingReferencedMessageID targetMessageID: String,
        in messages: [IMConversationMessage]
    ) -> String? {
        let trimmedTargetMessageID = targetMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTargetMessageID.isEmpty else {
            return nil
        }

        return messages.first(where: {
            $0.serverMessageID == trimmedTargetMessageID || $0.id == trimmedTargetMessageID
        })?.id
    }
}

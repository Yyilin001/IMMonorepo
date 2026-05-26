import Foundation
import IMClientKit

extension IMConversationMessage {
    enum RecallRule {
        static let window: TimeInterval = 2 * 60
    }

    var canCancelQueuedSend: Bool {
        guard direction == .outgoing, content.isUserComposable else {
            return false
        }

        if case .queued = deliveryState {
            return true
        }

        return false
    }

    var canReply: Bool {
        guard serverSequence != nil else {
            return false
        }

        switch content {
        case .richText, .reply, .image, .audio, .file:
            return true
        case .recalled, .system:
            return false
        }
    }

    var canRecall: Bool {
        guard direction == .outgoing,
              serverMessageID != nil || serverSequence != nil,
              Date().timeIntervalSince(createdAt) <= RecallRule.window
        else {
            return false
        }

        switch content {
        case .richText, .reply, .image, .audio, .file:
            return true
        case .recalled, .system:
            return false
        }
    }

    var canEdit: Bool {
        guard direction == .outgoing,
              serverMessageID != nil || serverSequence != nil,
              !derivedState.isRecalled
        else {
            return false
        }

        switch content {
        case .richText, .reply:
            return true
        case .image, .audio, .file, .recalled, .system:
            return false
        }
    }

    var canReact: Bool {
        guard serverMessageID != nil || serverSequence != nil, !derivedState.isRecalled else {
            return false
        }

        switch content {
        case .richText, .reply, .image, .audio, .file:
            return true
        case .recalled, .system:
            return false
        }
    }
}

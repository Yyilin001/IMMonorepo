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
        guard !derivedState.isRecalled else {
            return false
        }

        switch content {
        case .richText, .reply, .image, .audio, .file:
            return true
        }
    }

    var canRecall: Bool {
        guard direction == .outgoing,
              Date().timeIntervalSince(createdAt) <= RecallRule.window
        else {
            return false
        }

        return !derivedState.isRecalled
    }

    var canEdit: Bool {
        guard direction == .outgoing,
              !derivedState.isRecalled
        else {
            return false
        }

        switch content {
        case .richText, .reply:
            return true
        case .image, .audio, .file:
            return false
        }
    }

    var canReact: Bool {
        guard !derivedState.isRecalled else {
            return false
        }

        switch content {
        case .richText, .reply, .image, .audio, .file:
            return true
        }
    }
}

extension IMPendingConversationMessage {
    var canCancelQueuedSend: Bool {
        guard direction == .outgoing, content.isUserComposable else {
            return false
        }

        if case .queued = deliveryState {
            return true
        }

        return false
    }
}

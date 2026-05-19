import Foundation

struct MessageDerivedState: Codable, Equatable, Sendable {
    let recallState: MessageRecallState
    let edits: [MessageEdit]
    let reactions: [MessageReaction]
    let streamState: MessageStreamState?

    init(
        recallState: MessageRecallState = .active,
        edits: [MessageEdit] = [],
        reactions: [MessageReaction] = [],
        streamState: MessageStreamState? = nil
    ) {
        self.recallState = recallState
        self.edits = edits
        self.reactions = reactions
        self.streamState = streamState
    }

    var isRecalled: Bool {
        recallState != .active
    }
}

enum MessageStreamLifecycleState: String, Codable, Equatable, Sendable {
    case streaming
    case completed
    case failed
    case cancelled
}

struct MessageStreamState: Codable, Equatable, Sendable {
    let streamID: String
    let state: MessageStreamLifecycleState
    let lastChunkIndex: Int
    let partialText: String
    let errorCode: String?
    let errorMessage: String?
    let updatedAt: Date
    let isAIGenerated: Bool

    init(
        streamID: String,
        state: MessageStreamLifecycleState,
        lastChunkIndex: Int = 0,
        partialText: String = "",
        errorCode: String? = nil,
        errorMessage: String? = nil,
        updatedAt: Date = Date(),
        isAIGenerated: Bool = true
    ) {
        self.streamID = streamID
        self.state = state
        self.lastChunkIndex = lastChunkIndex
        self.partialText = partialText
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
        self.isAIGenerated = isAIGenerated
    }
}

enum MessageRecallState: Codable, Equatable, Sendable {
    case active
    case recalled
}

struct MessageEdit: Codable, Equatable, Sendable {
    let editedAt: Date?
    let text: String
}

struct MessageReaction: Codable, Equatable, Sendable {
    let emoji: String
    let actorUserIDs: [UUID]
}

enum MessagePrimaryContent: Equatable, Sendable {
    case text(String)
    case reply(reference: IMReplyReference, text: String)
    case system(IMSystemEvent)
    case image(IMMediaAsset)
    case audio(IMMediaAsset)
    case file(IMMediaAsset)
}

struct MessageAggregate: Equatable, Sendable {
    let primaryContent: MessagePrimaryContent?
    let derivedState: MessageDerivedState
}

struct MessagePresentation: Equatable, Sendable {
    let primaryContent: MessagePrimaryContent?
    let derivedState: MessageDerivedState

    init(aggregate: MessageAggregate) {
        self.primaryContent = aggregate.primaryContent
        self.derivedState = aggregate.derivedState
    }

    var previewText: String {
        guard !derivedState.isRecalled else {
            return "撤回了一条消息"
        }

        switch primaryContent {
        case .text(let text):
            return effectiveText(fallback: text)
        case .reply(_, let text):
            return effectiveText(fallback: text)
        case .system(let event):
            return event.displayText
        case .image(let asset):
            return "[图片] \(asset.filename)"
        case .audio(let asset):
            return "[语音] \(asset.filename)"
        case .file(let asset):
            return "[文件] \(asset.filename)"
        case nil:
            return "暂无消息"
        }
    }

    var mediaAsset: IMMediaAsset? {
        switch primaryContent {
        case .image(let asset), .audio(let asset), .file(let asset):
            return asset
        case .text, .reply, .system, .none:
            return nil
        }
    }

    var searchableTexts: [String] {
        guard !derivedState.isRecalled else {
            return [previewText]
        }

        switch primaryContent {
        case .text(let text):
            return [effectiveText(fallback: text)]
        case .reply(let reference, let text):
            return [effectiveText(fallback: text), reference.previewText]
        case .system(let event):
            return [event.displayText]
        case .image(let asset), .audio(let asset), .file(let asset):
            return [asset.filename, previewText]
        case nil:
            return [previewText]
        }
    }

    private func effectiveText(fallback: String) -> String {
        if let streamState = derivedState.streamState,
           streamState.state != .completed,
           !streamState.partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return streamState.partialText
        }
        let latestEditedText = derivedState.edits.last?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let latestEditedText, !latestEditedText.isEmpty else {
            return fallback
        }
        return latestEditedText
    }
}

typealias IMMessageDerivedState = MessageDerivedState
typealias IMMessageRecallState = MessageRecallState
typealias IMMessageEdit = MessageEdit
typealias IMMessageReaction = MessageReaction
typealias IMMessagePrimaryContent = MessagePrimaryContent
typealias IMMessageAggregate = MessageAggregate
typealias IMMessagePresentation = MessagePresentation

extension IMMessageContent {
    var primaryContent: MessagePrimaryContent? {
        switch self {
        case .text(let text):
            return .text(text)
        case .reply(let reference, let text):
            return .reply(reference: reference, text: text)
        case .system(let event):
            return .system(event)
        case .image(let asset):
            return .image(asset)
        case .audio(let asset):
            return .audio(asset)
        case .file(let asset):
            return .file(asset)
        case .recalled:
            return nil
        }
    }

    var derivedState: MessageDerivedState {
        MessageDerivedState(recallState: self == .recalled ? .recalled : .active)
    }

    func aggregate(derivedState override: MessageDerivedState? = nil) -> MessageAggregate {
        MessageAggregate(
            primaryContent: primaryContent,
            derivedState: normalizedDerivedState(override: override)
        )
    }

    var aggregate: MessageAggregate {
        aggregate(derivedState: nil)
    }

    var presentation: MessagePresentation {
        MessagePresentation(aggregate: aggregate)
    }

    private func normalizedDerivedState(override: MessageDerivedState?) -> MessageDerivedState {
        let base = derivedState
        guard let override else {
            return base
        }

        return MessageDerivedState(
            recallState: base.isRecalled ? .recalled : override.recallState,
            edits: override.edits,
            reactions: override.reactions,
            streamState: override.streamState
        )
    }
}

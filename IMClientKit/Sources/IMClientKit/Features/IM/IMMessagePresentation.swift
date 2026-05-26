import Foundation

public struct MessageDerivedState: Codable, Equatable, Sendable {
    public let recallState: MessageRecallState
    public let edits: [MessageEdit]
    public let reactions: [MessageReaction]
    public let streamState: MessageStreamState?

    public init(
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

    public var isRecalled: Bool {
        recallState != .active
    }
}

public enum MessageStreamLifecycleState: String, Codable, Equatable, Sendable {
    case streaming
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        self != .streaming
    }
}

public struct MessageStreamState: Codable, Equatable, Sendable {
    public let streamID: String
    public let state: MessageStreamLifecycleState
    public let lastChunkIndex: Int
    public let partialText: String
    public let errorCode: String?
    public let errorMessage: String?
    public let updatedAt: Date
    public let isAIGenerated: Bool

    public init(
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

public enum MessageRecallState: Codable, Equatable, Sendable {
    case active
    case recalled
}

public struct MessageEdit: Codable, Equatable, Sendable {
    public let editedAt: Date?
    public let body: IMRichTextContent

    public init(editedAt: Date?, body: IMRichTextContent) {
        self.editedAt = editedAt
        self.body = body
    }
}

public struct MessageReaction: Codable, Equatable, Sendable {
    public let emoji: String
    public let actorUserIDs: [UUID]

    public init(emoji: String, actorUserIDs: [UUID]) {
        self.emoji = emoji
        self.actorUserIDs = actorUserIDs
    }
}

public enum MessagePrimaryContent: Equatable, Sendable {
    case richText(IMRichTextContent)
    case reply(reference: IMReplyReference, body: IMRichTextContent)
    case system(IMSystemEvent)
    case image(IMMediaAsset)
    case audio(IMMediaAsset)
    case file(IMMediaAsset)
}

public struct MessageAggregate: Equatable, Sendable {
    public let primaryContent: MessagePrimaryContent?
    public let derivedState: MessageDerivedState

    public init(
        primaryContent: MessagePrimaryContent?,
        derivedState: MessageDerivedState
    ) {
        self.primaryContent = primaryContent
        self.derivedState = derivedState
    }
}

public struct MessagePresentation: Equatable, Sendable {
    public let primaryContent: MessagePrimaryContent?
    public let derivedState: MessageDerivedState

    public init(aggregate: MessageAggregate) {
        self.primaryContent = aggregate.primaryContent
        self.derivedState = aggregate.derivedState
    }

    public var previewText: String {
        guard !derivedState.isRecalled else {
            return "撤回了一条消息"
        }

        switch primaryContent {
        case .richText(let body):
            return effectiveText(fallback: body.text)
        case .reply(_, let body):
            return effectiveText(fallback: body.text)
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

    public var textValue: String? {
        guard !derivedState.isRecalled else {
            return nil
        }

        switch primaryContent {
        case .richText(let body):
            return effectiveText(fallback: body.text)
        case .reply(_, let body):
            return effectiveText(fallback: body.text)
        case .system(let event):
            return event.displayText
        case .image(let asset):
            return "[图片] \(asset.filename)"
        case .audio(let asset):
            return "[语音] \(asset.filename)"
        case .file(let asset):
            return "[文件] \(asset.filename)"
        case nil:
            return nil
        }
    }

    public var replyReference: IMReplyReference? {
        guard case .reply(let reference, _) = primaryContent else {
            return nil
        }
        return reference
    }

    public var mediaAsset: IMMediaAsset? {
        switch primaryContent {
        case .image(let asset), .audio(let asset), .file(let asset):
            return asset
        case .richText, .reply, .system, .none:
            return nil
        }
    }

    public var isUserComposable: Bool {
        guard !derivedState.isRecalled else {
            return false
        }

        switch primaryContent {
        case .richText, .reply, .image, .audio, .file:
            return true
        case .system, .none:
            return false
        }
    }

    public var searchableTexts: [String] {
        guard !derivedState.isRecalled else {
            return [previewText]
        }

        switch primaryContent {
        case .richText(let body):
            return [effectiveText(fallback: body.text)]
        case .reply(let reference, let body):
            return [effectiveText(fallback: body.text), reference.previewText]
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
        let latestEditedText = derivedState.edits.last?.body.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let latestEditedText, !latestEditedText.isEmpty else {
            return fallback
        }
        return latestEditedText
    }
}

public typealias IMMessageDerivedState = MessageDerivedState
public typealias IMMessageRecallState = MessageRecallState
public typealias IMMessageEdit = MessageEdit
public typealias IMMessageReaction = MessageReaction
public typealias IMMessagePrimaryContent = MessagePrimaryContent
public typealias IMMessageAggregate = MessageAggregate
public typealias IMMessagePresentation = MessagePresentation

public extension IMMessageContent {
    var primaryContent: MessagePrimaryContent? {
        switch self {
        case .richText(let body):
            return .richText(body)
        case .reply(let reference, let body):
            return .reply(reference: reference, body: body)
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
        let mergedState = normalizedDerivedState(override: override)
        return MessageAggregate(
            primaryContent: primaryContent,
            derivedState: mergedState
        )
    }

    var aggregate: MessageAggregate {
        aggregate(derivedState: nil)
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

    var presentation: MessagePresentation {
        MessagePresentation(aggregate: aggregate)
    }

    func presentation(derivedState override: MessageDerivedState?) -> MessagePresentation {
        MessagePresentation(aggregate: aggregate(derivedState: override))
    }
}

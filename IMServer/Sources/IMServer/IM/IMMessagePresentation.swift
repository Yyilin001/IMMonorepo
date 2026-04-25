import Foundation

struct IMMessageDerivedState: Equatable, Sendable {
    let isRecalled: Bool
}

enum IMMessagePrimaryContent: Equatable, Sendable {
    case text(String)
    case reply(reference: IMReplyReference, text: String)
    case system(IMSystemEvent)
    case image(IMMediaAsset)
    case audio(IMMediaAsset)
    case file(IMMediaAsset)
}

struct IMMessagePresentation: Equatable, Sendable {
    let primaryContent: IMMessagePrimaryContent?
    let derivedState: IMMessageDerivedState

    var previewText: String {
        guard !derivedState.isRecalled else {
            return "撤回了一条消息"
        }

        switch primaryContent {
        case .text(let text):
            return text
        case .reply(_, let text):
            return text
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
            return [text]
        case .reply(let reference, let text):
            return [text, reference.previewText]
        case .system(let event):
            return [event.displayText]
        case .image(let asset), .audio(let asset), .file(let asset):
            return [asset.filename, previewText]
        case nil:
            return [previewText]
        }
    }
}

extension IMMessageContent {
    var primaryContent: IMMessagePrimaryContent? {
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

    var derivedState: IMMessageDerivedState {
        IMMessageDerivedState(isRecalled: self == .recalled)
    }

    var presentation: IMMessagePresentation {
        IMMessagePresentation(primaryContent: primaryContent, derivedState: derivedState)
    }
}

import IMClientKit
import SwiftUI

struct IMMessageContentBody: View {
    let message: IMConversationMessage
    let replyReference: IMReplyReferenceResolution?
    let mediaDownloadState: IMMediaDownloadState?
    let onJumpToReplyReference: () -> Void
    let onDownloadMedia: () -> Void
    let onCancelMediaDownload: () -> Void
    let onRetryMediaDownload: () -> Void
    let onOpenDownloadedMedia: (URL) -> Void
    let onDeleteDownloadedMedia: () -> Void

    var body: some View {
        let aggregate = message.aggregate
        let presentation = MessagePresentation(aggregate: aggregate)

        switch aggregate.primaryContent {
        case .richText(let body):
            Text(attributedText(for: body, fallback: presentation.textValue ?? message.text))
                .font(.body)
        case .reply(_, let body):
            VStack(alignment: .leading, spacing: 8) {
                Button(action: onJumpToReplyReference) {
                    IMReplyReferencePreview(replyReference: replyReference)
                }
                .buttonStyle(.plain)

                Text(attributedText(for: body, fallback: presentation.textValue ?? message.text))
                    .font(.body)
            }
        case .image(let asset):
            IMMessageMediaBubble(
                title: asset.filename,
                subtitle: mediaSubtitle(for: asset),
                mediaDownloadState: mediaDownloadState,
                header: Label("图片", systemImage: "photo").font(.headline),
                onDownloadMedia: onDownloadMedia,
                onCancelMediaDownload: onCancelMediaDownload,
                onRetryMediaDownload: onRetryMediaDownload,
                onOpenDownloadedMedia: onOpenDownloadedMedia,
                onDeleteDownloadedMedia: onDeleteDownloadedMedia
            )
        case .audio(let asset):
            IMMessageMediaBubble(
                title: asset.filename,
                subtitle: mediaSubtitle(for: asset),
                mediaDownloadState: mediaDownloadState,
                header: Label("语音", systemImage: "waveform").font(.headline),
                onDownloadMedia: onDownloadMedia,
                onCancelMediaDownload: onCancelMediaDownload,
                onRetryMediaDownload: onRetryMediaDownload,
                onOpenDownloadedMedia: onOpenDownloadedMedia,
                onDeleteDownloadedMedia: onDeleteDownloadedMedia
            )
        case .file(let asset):
            IMMessageMediaBubble(
                title: asset.filename,
                subtitle: mediaSubtitle(for: asset),
                mediaDownloadState: mediaDownloadState,
                header: Label("文件", systemImage: "doc").font(.headline),
                onDownloadMedia: onDownloadMedia,
                onCancelMediaDownload: onCancelMediaDownload,
                onRetryMediaDownload: onRetryMediaDownload,
                onOpenDownloadedMedia: onOpenDownloadedMedia,
                onDeleteDownloadedMedia: onDeleteDownloadedMedia
            )
        case nil:
            Text(message.direction == .outgoing ? "你撤回了一条消息" : "对方撤回了一条消息")
                .font(.body)
                .italic()
                .foregroundStyle(.secondary)
        }
    }

    private func attributedText(for body: IMRichTextContent, fallback: String) -> AttributedString {
        var attributed = AttributedString(fallback)
        guard fallback == body.text else {
            return attributed
        }

        for entity in body.entities {
            guard let range = attributedRange(for: entity.range, in: body.text, attributed: attributed) else {
                continue
            }

            switch entity {
            case .link(_, let url):
                if let url = URL(string: url) {
                    attributed[range].link = url
                    attributed[range].foregroundColor = .blue
                    attributed[range].underlineStyle = .single
                }
            case .mention:
                attributed[range].foregroundColor = .accentColor
            case .hashtag:
                attributed[range].foregroundColor = .teal
            case .inlineCode:
                attributed[range].font = .system(.body, design: .monospaced)
                attributed[range].backgroundColor = Color.secondary.opacity(0.12)
            }
        }

        return attributed
    }

    private func attributedRange(
        for range: IMTextRange,
        in text: String,
        attributed: AttributedString
    ) -> Range<AttributedString.Index>? {
        guard range.location >= 0,
              range.length > 0,
              range.location + range.length <= text.utf16.count
        else {
            return nil
        }

        let lowerUTF16 = text.utf16.index(text.utf16.startIndex, offsetBy: range.location)
        let upperUTF16 = text.utf16.index(text.utf16.startIndex, offsetBy: range.location + range.length)
        guard let lowerStringIndex = String.Index(lowerUTF16, within: text),
              let upperStringIndex = String.Index(upperUTF16, within: text),
              let lower = AttributedString.Index(lowerStringIndex, within: attributed),
              let upper = AttributedString.Index(upperStringIndex, within: attributed)
        else {
            return nil
        }
        return lower..<upper
    }

    private func mediaSubtitle(for asset: IMMediaAsset) -> String {
        var parts: [String] = []
        if asset.byteSize > 0 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            parts.append(formatter.string(fromByteCount: asset.byteSize))
        }
        if let width = asset.width, let height = asset.height {
            parts.append("\(width)×\(height)")
        }
        if let durationMillis = asset.durationMillis, durationMillis > 0 {
            parts.append(formatDuration(durationMillis))
        }
        return parts.joined(separator: " · ")
    }

    private func formatDuration(_ durationMillis: Int) -> String {
        let totalSeconds = max(0, durationMillis / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct IMReplyReferencePreview: View {
    let replyReference: IMReplyReferenceResolution?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("回复")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if replyReference?.state == .recalled {
                Text(replyReference?.text ?? "原消息暂不可用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
                    .lineLimit(2)
            } else {
                Text(replyReference?.text ?? "原消息暂不可用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

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
        case .text:
            Text(presentation.textValue ?? message.text)
                .font(.body)
        case .reply:
            VStack(alignment: .leading, spacing: 8) {
                Button(action: onJumpToReplyReference) {
                    IMReplyReferencePreview(replyReference: replyReference)
                }
                .buttonStyle(.plain)

                Text(presentation.textValue ?? message.text)
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
        case .system:
            EmptyView()
        }
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

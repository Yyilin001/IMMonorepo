import IMClientKit
import SwiftUI

struct IMMessageBubble: View {
    private static let reactionEmojiOptions = ["👍", "❤️", "😂", "😮", "👎"]

    let message: IMConversationMessage
    let replyReference: IMReplyReferenceResolution?
    let isHighlighted: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let canSelect: Bool
    let canRetry: Bool
    let canCancel: Bool
    let canReply: Bool
    let canRecall: Bool
    let canEdit: Bool
    let canReact: Bool
    let isFavorited: Bool
    let mediaDownloadState: IMMediaDownloadState?
    let deliveryOverrideText: String?
    let currentUserID: UUID?
    let onToggleSelection: () -> Void
    let onEnterSelection: () -> Void
    let onJumpToReplyReference: () -> Void
    let onCancel: () -> Void
    let onReply: () -> Void
    let onEdit: () -> Void
    let onRecall: () -> Void
    let onRetry: () -> Void
    let onForward: () -> Void
    let onToggleFavorite: () -> Void
    let onToggleReaction: (String) -> Void
    let onDownloadMedia: () -> Void
    let onCancelMediaDownload: () -> Void
    let onRetryMediaDownload: () -> Void
    let onOpenDownloadedMedia: (URL) -> Void
    let onDeleteDownloadedMedia: () -> Void

    var body: some View {
        if case .system(let event) = message.content {
            Text(event.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
        } else {
        HStack {
            if message.direction == .outgoing {
                Spacer(minLength: 24)
            }

            if isSelectionMode, canSelect {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 28)
            }

            VStack(alignment: .leading, spacing: 6) {
                messageBody

                if !message.derivedState.reactions.isEmpty {
                    reactionRow
                }

                HStack(spacing: 8) {
                    Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    if let deliveryDisplay {
                        Label(deliveryDisplay.text, systemImage: deliveryDisplay.icon)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(deliveryDisplay.tint)
                            .lineLimit(1)
                    }
                    if !message.derivedState.edits.isEmpty {
                        Text("已编辑")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if canCancel {
                    Button {
                        onCancel()
                    } label: {
                        Label("取消发送", systemImage: "xmark.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if canRecall {
                    Button {
                        onRecall()
                    } label: {
                        Label("撤回", systemImage: "arrow.uturn.backward.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if canRetry {
                    Button {
                        onRetry()
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(bubbleColor)
            .overlay {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.accentColor.opacity(0.45), lineWidth: 2)
                } else if isSelected {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.accentColor.opacity(0.75), lineWidth: 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture {
                if isSelectionMode, canSelect {
                    onToggleSelection()
                }
            }
            .contextMenu {
                if canSelect {
                    Button(isSelectionMode ? "切换选择" : "选择", systemImage: isSelected ? "checkmark.circle.fill" : "checkmark.circle") {
                        if isSelectionMode {
                            onToggleSelection()
                        } else {
                            onEnterSelection()
                        }
                    }
                }

                if canReply {
                    Button("回复", systemImage: "arrowshape.turn.up.left") {
                        onReply()
                    }
                }

                if canSelect {
                    Button("转发", systemImage: "arrowshape.turn.up.right") {
                        onForward()
                    }

                    Button(isFavorited ? "取消收藏" : "收藏", systemImage: isFavorited ? "star.slash" : "star") {
                        onToggleFavorite()
                    }
                }

                if canEdit {
                    Button("编辑", systemImage: "square.and.pencil") {
                        onEdit()
                    }
                }

                if canReact {
                    ForEach(Self.reactionEmojiOptions, id: \.self) { emoji in
                        Button(emoji) {
                            onToggleReaction(emoji)
                        }
                    }
                }

                if canRecall {
                    Button("撤回", systemImage: "arrow.uturn.backward.circle") {
                        onRecall()
                    }
                }
            }

            if message.direction == .incoming {
                Spacer(minLength: 24)
            }
        }
        }
    }

    private var bubbleColor: Color {
        switch message.direction {
        case .incoming:
            return Color(.secondarySystemGroupedBackground)
        case .outgoing:
            return Color.accentColor.opacity(0.16)
        }
    }

    private var deliveryDisplay: (icon: String, text: String, tint: Color)? {
        guard message.direction == .outgoing else {
            return nil
        }

        if let deliveryOverrideText {
            return ("checkmark.circle", deliveryOverrideText, .secondary)
        }

        switch message.deliveryState {
        case .preparing(let message):
            return ("clock", shortStatus("准备中", detail: message), .secondary)
        case .uploading(let message):
            return ("icloud.and.arrow.up", shortStatus("上传中", detail: message), .blue)
        case .uploaded:
            return ("icloud.and.arrow.up.fill", "上传完成", .blue)
        case .queued(let message):
            return ("clock.badge.exclamationmark", shortStatus("待发送", detail: message), .orange)
        case .sending:
            return ("paperplane", "发送中", .secondary)
        case .sent:
            return ("checkmark", "已发送", .secondary)
        case .received:
            return ("checkmark.circle", "已送达", .secondary)
        case .unknown(let message):
            return ("questionmark.circle", shortStatus("未确认", detail: message), .orange)
        case .failed(let message):
            return ("exclamationmark.circle.fill", shortStatus("失败", detail: message), .red)
        }
    }

    private func shortStatus(_ prefix: String, detail: String) -> String {
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDetail.isEmpty else {
            return prefix
        }
        return "\(prefix): \(trimmedDetail)"
    }

    @ViewBuilder
    private var messageBody: some View {
        let aggregate = message.aggregate
        let presentation = MessagePresentation(aggregate: aggregate)

        switch aggregate.primaryContent {
        case .text:
            Text(presentation.textValue ?? message.text)
                .font(.body)
        case .reply:
            VStack(alignment: .leading, spacing: 8) {
                Button(action: onJumpToReplyReference) {
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
                .buttonStyle(.plain)

                Text(presentation.textValue ?? message.text)
                    .font(.body)
            }
        case .image(let asset):
            mediaBubble(
                title: asset.filename,
                subtitle: mediaSubtitle(for: asset)
            ) {
                Label("图片", systemImage: "photo")
                    .font(.headline)
            }
        case .audio(let asset):
            mediaBubble(
                title: asset.filename,
                subtitle: mediaSubtitle(for: asset)
            ) {
                Label("语音", systemImage: "waveform")
                    .font(.headline)
            }
        case .file(let asset):
            mediaBubble(
                title: asset.filename,
                subtitle: mediaSubtitle(for: asset)
            ) {
                Label("文件", systemImage: "doc")
                    .font(.headline)
            }
        case nil:
            Text(message.direction == .outgoing ? "你撤回了一条消息" : "对方撤回了一条消息")
                .font(.body)
                .italic()
                .foregroundStyle(.secondary)
        case .system:
            EmptyView()
        }
    }

    private var reactionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(message.derivedState.reactions, id: \.emoji) { reaction in
                    let didReact = currentUserID.map(reaction.actorUserIDs.contains) ?? false
                    HStack(spacing: 4) {
                        Text(reaction.emoji)
                        Text("\(reaction.actorUserIDs.count)")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(didReact ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemGroupedBackground))
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func mediaBubble<Header: View>(
        title: String,
        subtitle: String,
        @ViewBuilder header: () -> Header
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header()
            Text(title)
                .font(.body.weight(.medium))
                .lineLimit(2)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            mediaDownloadControls
        }
    }

    @ViewBuilder
    private var mediaDownloadControls: some View {
        switch mediaDownloadState ?? .idle {
        case .idle:
            Button {
                onDownloadMedia()
            } label: {
                Label("下载附件", systemImage: "arrow.down.circle")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let fractionCompleted = progress?.fractionCompleted {
                        ProgressView(value: fractionCompleted)
                            .controlSize(.small)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(downloadStatusText(for: progress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    onCancelMediaDownload()
                } label: {
                    Label("暂停下载", systemImage: "pause.circle")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .paused(let progress):
            VStack(alignment: .leading, spacing: 6) {
                Text(pausedStatusText(for: progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button {
                        onDownloadMedia()
                    } label: {
                        Label("继续下载", systemImage: "arrow.clockwise.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        onDeleteDownloadedMedia()
                    } label: {
                        Label("重新开始", systemImage: "trash")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        case .downloaded(let fileURL):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Label("已下载", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)

                    Text(fileURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Button {
                        onOpenDownloadedMedia(fileURL)
                    } label: {
                        Label("打开预览", systemImage: "eye")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    ShareLink(item: fileURL) {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        onDeleteDownloadedMedia()
                    } label: {
                        Label("删除", systemImage: "trash")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    onRetryMediaDownload()
                } label: {
                    Label("重试下载", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func downloadStatusText(for progress: FileTransferProgress?) -> String {
        guard let progress else {
            return "正在下载…"
        }

        if let fractionCompleted = progress.fractionCompleted {
            let percentage = Int((fractionCompleted * 100).rounded())
            return "下载中 \(percentage)%"
        }

        return "已接收 \(ByteCountFormatter.string(fromByteCount: progress.transferredBytes, countStyle: .file))"
    }

    private func pausedStatusText(for progress: FileTransferProgress?) -> String {
        guard let progress else {
            return "下载已暂停"
        }

        if let fractionCompleted = progress.fractionCompleted {
            let percentage = Int((fractionCompleted * 100).rounded())
            return "下载已暂停 \(percentage)%"
        }

        return "已暂停，已接收 \(ByteCountFormatter.string(fromByteCount: progress.transferredBytes, countStyle: .file))"
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
        case .text, .reply, .image, .audio, .file:
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
        case .text, .reply, .image, .audio, .file:
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
        case .text, .reply:
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
        case .text, .reply, .image, .audio, .file:
            return true
        case .recalled, .system:
            return false
        }
    }
}

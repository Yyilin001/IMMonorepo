import IMClientKit
import SwiftUI

struct IMMessageDeliveryDisplay {
    let icon: String
    let text: String
    let tint: Color
}

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
                    IMMessageContentBody(
                        message: message,
                        replyReference: replyReference,
                        mediaDownloadState: mediaDownloadState,
                        onJumpToReplyReference: onJumpToReplyReference,
                        onDownloadMedia: onDownloadMedia,
                        onCancelMediaDownload: onCancelMediaDownload,
                        onRetryMediaDownload: onRetryMediaDownload,
                        onOpenDownloadedMedia: onOpenDownloadedMedia,
                        onDeleteDownloadedMedia: onDeleteDownloadedMedia
                    )

                    if !message.derivedState.reactions.isEmpty {
                        IMMessageReactionRow(
                            reactions: message.derivedState.reactions,
                            currentUserID: currentUserID
                        )
                    }

                    HStack(spacing: 8) {
                        Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                        if let deliveryDisplay {
                            IMMessageDeliveryLabel(display: deliveryDisplay)
                        }
                        if !message.derivedState.edits.isEmpty {
                            Text("已编辑")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    IMMessageSendActionButton(
                        canCancel: canCancel,
                        canRecall: canRecall,
                        canRetry: canRetry,
                        onCancel: onCancel,
                        onRecall: onRecall,
                        onRetry: onRetry
                    )
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
                    contextMenuContent
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

    private var deliveryDisplay: IMMessageDeliveryDisplay? {
        guard message.direction == .outgoing else {
            return nil
        }

        if let deliveryOverrideText {
            return IMMessageDeliveryDisplay(icon: "checkmark.circle", text: deliveryOverrideText, tint: .secondary)
        }

        switch message.deliveryState {
        case .preparing(let message):
            return IMMessageDeliveryDisplay(icon: "clock", text: shortStatus("准备中", detail: message), tint: .secondary)
        case .uploading(let message):
            return IMMessageDeliveryDisplay(icon: "icloud.and.arrow.up", text: shortStatus("上传中", detail: message), tint: .blue)
        case .uploaded:
            return IMMessageDeliveryDisplay(icon: "icloud.and.arrow.up.fill", text: "上传完成", tint: .blue)
        case .queued(let message):
            return IMMessageDeliveryDisplay(icon: "clock.badge.exclamationmark", text: shortStatus("待发送", detail: message), tint: .orange)
        case .sending:
            return IMMessageDeliveryDisplay(icon: "paperplane", text: "发送中", tint: .secondary)
        case .sent:
            return IMMessageDeliveryDisplay(icon: "checkmark", text: "已发送", tint: .secondary)
        case .received:
            return IMMessageDeliveryDisplay(icon: "checkmark.circle", text: "已送达", tint: .secondary)
        case .unknown(let message):
            return IMMessageDeliveryDisplay(icon: "questionmark.circle", text: shortStatus("未确认", detail: message), tint: .orange)
        case .failed(let message):
            return IMMessageDeliveryDisplay(icon: "exclamationmark.circle.fill", text: shortStatus("失败", detail: message), tint: .red)
        }
    }

    private var contextMenuContent: some View {
        Group {
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
    }

    private func shortStatus(_ prefix: String, detail: String) -> String {
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDetail.isEmpty else {
            return prefix
        }
        return "\(prefix): \(trimmedDetail)"
    }
}

private struct IMMessageDeliveryLabel: View {
    let display: IMMessageDeliveryDisplay

    var body: some View {
        Label(display.text, systemImage: display.icon)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(display.tint)
            .lineLimit(1)
    }
}

private struct IMMessageSendActionButton: View {
    let canCancel: Bool
    let canRecall: Bool
    let canRetry: Bool
    let onCancel: () -> Void
    let onRecall: () -> Void
    let onRetry: () -> Void

    var body: some View {
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
}

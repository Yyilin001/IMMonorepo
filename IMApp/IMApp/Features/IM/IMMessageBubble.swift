import IMClientKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct IMMessageDeliveryDisplay {
    let icon: String
    let text: String
    let tint: Color
}

struct IMMessageBubble: View {
    private static let reactionEmojiOptions = ["👍", "❤️", "😂", "😮", "👎"]

    let rowSnapshot: IMChatMessageRowSnapshot
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
    let onDelete: () -> Void
    let onToggleReaction: (String) -> Void
    let onDownloadMedia: () -> Void
    let onCancelMediaDownload: () -> Void
    let onRetryMediaDownload: () -> Void
    let onOpenDownloadedMedia: (URL) -> Void
    let onDeleteDownloadedMedia: () -> Void

    var body: some View {
        HStack {
            if rowSnapshot.direction == .outgoing {
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
                    content: rowSnapshot.content,
                    replyReference: rowSnapshot.replyReference,
                    mediaDownloadState: mediaDownloadState,
                    onJumpToReplyReference: onJumpToReplyReference,
                    onDownloadMedia: onDownloadMedia,
                    onCancelMediaDownload: onCancelMediaDownload,
                    onRetryMediaDownload: onRetryMediaDownload,
                    onOpenDownloadedMedia: onOpenDownloadedMedia,
                    onDeleteDownloadedMedia: onDeleteDownloadedMedia
                )

                if !rowSnapshot.reactions.isEmpty {
                    IMMessageReactionRow(
                        reactions: rowSnapshot.reactions,
                        currentUserID: currentUserID
                    )
                }

                HStack(spacing: 8) {
                    Text(rowSnapshot.createdAtText)
                    if let deliveryDisplay {
                        IMMessageDeliveryLabel(display: deliveryDisplay)
                    }
                    if rowSnapshot.isEdited {
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
            .accessibilityIdentifier("conversation.message.moreActions")

            if rowSnapshot.direction == .incoming {
                Spacer(minLength: 24)
            }
        }
    }

    private var bubbleColor: Color {
        switch rowSnapshot.direction {
        case .incoming:
            return Color(.secondarySystemGroupedBackground)
        case .outgoing:
            return Color.accentColor.opacity(0.16)
        }
    }

    private var deliveryDisplay: IMMessageDeliveryDisplay? {
        rowSnapshot.deliveryDisplay.map(IMMessageDeliveryDisplay.init(snapshot:))
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

            if rowSnapshot.copyableText != nil {
                Button("复制", systemImage: "doc.on.doc") {
                    copyMessageText()
                }
            }

            if canSelect {
                Button("转发", systemImage: "arrowshape.turn.up.right") {
                    onForward()
                }

                Button(isFavorited ? "取消收藏" : "收藏", systemImage: isFavorited ? "star.slash" : "star") {
                    onToggleFavorite()
                }

                Button("删除", systemImage: "trash", role: .destructive) {
                    onDelete()
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

    private func copyMessageText() {
        #if canImport(UIKit)
        if let copyableText = rowSnapshot.copyableText {
            UIPasteboard.general.string = copyableText
        }
        #endif
    }
}

extension IMMessageDeliveryDisplay {
    init(snapshot: IMChatMessageDeliverySnapshot) {
        self.init(
            icon: snapshot.icon,
            text: snapshot.text,
            tint: snapshot.tone.tint
        )
    }
}

private extension IMChatMessageDeliverySnapshot.Tone {
    var tint: Color {
        switch self {
        case .secondary:
            return .secondary
        case .blue:
            return .blue
        case .orange:
            return .orange
        case .red:
            return .red
        }
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
            .accessibilityIdentifier("conversation.message.cancelSend")
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
            .accessibilityIdentifier("conversation.message.retry")
        }
    }
}

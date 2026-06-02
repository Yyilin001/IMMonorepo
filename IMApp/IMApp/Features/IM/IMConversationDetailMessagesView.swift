import SwiftUI
import IMClientKit

struct ConversationNewMessagePill: View {
    let unseenCount: Int
    let showsJumpOnly: Bool
    let onTap: () -> Void

    var body: some View {
        if unseenCount > 0 || showsJumpOnly {
            Button {
                onTap()
            } label: {
                Label(title, systemImage: "arrow.down.circle.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .shadow(radius: 8, y: 3)
            .accessibilityIdentifier(unseenCount > 0 ? "conversation.newMessagePill" : "conversation.jumpLatestButton")
        }
    }

    private var title: String {
        if unseenCount > 0 {
            return unseenCount == 1 ? "1 条新消息" : "\(unseenCount) 条新消息"
        }
        return "回到底部"
    }
}

extension IMConversationDetailView {
    var detailScrollView: some View {
        ScrollView {
            detailMessageStack
        }
        .defaultScrollAnchor(.bottom)
        .background(AppSurface.groupedBackground)
    }

    var detailMessageStack: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            conversationContextStrip

            if queueSummary.hasPendingWork {
                IMConversationQueueBanner(
                    summary: queueSummary,
                    isFlushing: runtimeStore.isFlushingQueuedTextMessages
                )
            }

            if let message = conversationStore.statusMessage, !message.isEmpty {
                AppStatusBanner(message: message, tone: .info)
                    .accessibilityIdentifier("conversation.status")
            }

            detailMessagesContent
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    var detailMessagesContent: some View {
        if shouldShowLoadingState {
            ProgressView("正在拉取消息…")
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
        } else if timelineItems.isEmpty {
            IMDetailEmptyState()
        } else {
            if conversation?.hasMoreHistory == true {
                Button {
                    conversationStore.openConversation(id: conversationID)
                    Task {
                        await runtimeStore.loadOlderMessages()
                    }
                } label: {
                    Label("加载更早消息", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(conversationStore.isLoadingMessages)
                .accessibilityIdentifier("conversation.loadOlderMessagesButton")
            }

            ForEach(timelineItems) { item in
                switch item {
                case .message(let message):
                    detailMessageRow(message)
                        .id(item.id)
                case .notice(let notice):
                    timelineNoticeRow(notice)
                        .id(item.id)
                case .pendingMessage(let message):
                    pendingMessageRow(message)
                        .id(item.id)
                }
            }
        }
    }

    func timelineNoticeRow(_ notice: IMTimelineNotice) -> some View {
        Text(timelineNoticeText(notice))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(AppSurface.secondaryGrouped, in: Capsule())
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityIdentifier("conversation.timelineNotice.\(notice.id)")
    }

    func timelineNoticeText(_ notice: IMTimelineNotice) -> String {
        switch notice.noticeKind {
        case "member_added":
            return "成员已加入会话"
        case "member_removed":
            return "成员已离开会话"
        case "member_role_updated":
            return "成员角色已更新"
        case "metadata_updated":
            return "会话信息已更新"
        case "direct_peer_updated":
            return "联系人状态已更新"
        case "conversation_visibility_changed":
            return "会话可见性已更新"
        case "conversation_settings_changed":
            return "会话设置已更新"
        case "invite_changed":
            return "邀请链接已更新"
        default:
            return notice.fallbackText
        }
    }

    func detailMessageRow(_ message: IMConversationMessage) -> some View {
        let mediaAsset = message.mediaAsset
        let selectableID = selectableMessageID(for: message)
        return IMMessageBubble(
            message: message,
            replyReference: message.resolvedReplyReference(in: messages),
            isHighlighted: highlightedMessageID == message.id,
            isSelectionMode: isSelectionMode,
            isSelected: selectableID.map(selectedMessageIDs.contains) ?? false,
            canSelect: selectableID != nil,
            canRetry: conversationStore.isRetryableFailure(message),
            canCancel: message.canCancelQueuedSend,
            canReply: message.canReply,
            canRecall: message.canRecall,
            canEdit: message.canEdit,
            canReact: message.canReact,
            isFavorited: selectableID.map(favoritedMessageIDs.contains) ?? false,
            mediaDownloadState: resolvedMediaDownloadState(for: message),
            deliveryOverrideText: deliveryOverrideText(for: message),
            currentUserID: runtimeStore.currentUserID,
            onToggleSelection: {
                guard let selectableID else {
                    return
                }
                toggleSelectedMessage(selectableID)
            },
            onEnterSelection: {
                guard let selectableID else {
                    return
                }
                isSelectionMode = true
                selectedMessageIDs.insert(selectableID)
            },
            onJumpToReplyReference: {
                guard case .reply(let reference, _) = message.content else {
                    return
                }

                Task {
                    await runtimeStore.jumpToReferencedMessage(
                        reference.messageID,
                        in: conversationID
                    )
                }
            },
            onCancel: {
                _ = runtimeStore.cancelQueuedTextMessage(
                    localMessageID: message.id,
                    in: conversationID
                )
            },
            onReply: {
                editingTarget = nil
                replyTarget = message
            },
            onEdit: {
                replyTarget = nil
                editingTarget = message
                composerText = MessagePresentation(aggregate: message.aggregate).textValue ?? ""
            },
            onRecall: {
                Task {
                    let didRecall = await runtimeStore.recallMessage(
                        messageID: message.serverMessageID,
                        in: conversationID
                    )
                    if didRecall, replyTarget?.id == message.id {
                        replyTarget = nil
                    }
                }
            },
            onRetry: {
                Task {
                    await runtimeStore.retryTextMessage(
                        localMessageID: message.id,
                        in: conversationID
                    )
                }
            },
            onForward: {
                guard let selectableID else {
                    return
                }
                pendingForwardMessageIDs = [selectableID]
                isPresentingForwardPicker = true
            },
            onToggleFavorite: {
                guard let selectableID else {
                    return
                }
                Task {
                    await toggleFavorite(messageID: selectableID)
                }
            },
            onDelete: {
                guard let selectableID else {
                    return
                }
                Task {
                    _ = await runtimeStore.deleteMessagesForSelf(messageIDs: [selectableID], in: conversationID)
                }
            },
            onToggleReaction: { emoji in
                Task {
                    _ = await runtimeStore.toggleMessageReaction(
                        messageID: message.serverMessageID,
                        emoji: emoji,
                        in: conversationID
                    )
                }
            },
            onDownloadMedia: {
                guard let mediaAsset else {
                    return
                }
                startMediaDownload(mediaAsset)
            },
            onCancelMediaDownload: {
                guard let assetID = mediaAsset?.assetID else {
                    return
                }
                pauseMediaDownload(for: assetID)
            },
            onRetryMediaDownload: {
                guard let mediaAsset else {
                    return
                }
                startMediaDownload(mediaAsset)
            },
            onOpenDownloadedMedia: { fileURL in
                previewedMediaItem = IMDownloadedMediaPreviewItem(
                    url: fileURL,
                    title: mediaAsset?.filename ?? fileURL.lastPathComponent
                )
            },
            onDeleteDownloadedMedia: {
                guard let mediaAsset else {
                    return
                }
                deleteDownloadedMedia(mediaAsset)
            }
        )
    }

    func pendingMessageRow(_ message: IMPendingConversationMessage) -> some View {
        HStack {
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(message.text)
                    .font(.body)
                HStack(spacing: 8) {
                    Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    let display = deliveryDisplay(for: message.deliveryState)
                    Label(display.text, systemImage: display.icon)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(display.tint)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if message.canCancelQueuedSend {
                    Button {
                        _ = runtimeStore.cancelQueuedTextMessage(
                            localMessageID: message.id,
                            in: conversationID
                        )
                    } label: {
                        Label("取消发送", systemImage: "xmark.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("conversation.message.cancelSend")
                } else if conversationStore.isRetryableFailure(message) {
                    Button {
                        Task {
                            await runtimeStore.retryTextMessage(
                                localMessageID: message.id,
                                in: conversationID
                            )
                        }
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("conversation.message.retry")
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .accessibilityIdentifier("conversation.pendingMessage.\(message.id)")
    }

    func deliveryDisplay(for state: IMMessageDeliveryState) -> IMMessageDeliveryDisplay {
        switch state {
        case .preparing(let message):
            return IMMessageDeliveryDisplay(icon: "clock", text: message.isEmpty ? "准备中" : message, tint: .secondary)
        case .uploading(let message):
            return IMMessageDeliveryDisplay(icon: "icloud.and.arrow.up", text: message.isEmpty ? "上传中" : message, tint: .blue)
        case .uploaded:
            return IMMessageDeliveryDisplay(icon: "icloud.and.arrow.up.fill", text: "上传完成", tint: .blue)
        case .queued(let message):
            return IMMessageDeliveryDisplay(icon: "clock.badge.exclamationmark", text: message.isEmpty ? "待发送" : message, tint: .orange)
        case .sending:
            return IMMessageDeliveryDisplay(icon: "paperplane", text: "发送中", tint: .secondary)
        case .sent:
            return IMMessageDeliveryDisplay(icon: "checkmark", text: "已发送", tint: .secondary)
        case .received:
            return IMMessageDeliveryDisplay(icon: "checkmark.circle", text: "已送达", tint: .secondary)
        case .unknown(let message):
            return IMMessageDeliveryDisplay(icon: "questionmark.circle", text: message.isEmpty ? "未确认" : message, tint: .orange)
        case .failed(let message):
            return IMMessageDeliveryDisplay(icon: "exclamationmark.circle.fill", text: message.isEmpty ? "失败" : message, tint: .red)
        }
    }

}

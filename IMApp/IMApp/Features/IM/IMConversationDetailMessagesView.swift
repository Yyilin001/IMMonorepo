import SwiftUI
import IMClientKit

extension IMConversationDetailView {
    var detailScrollView: some View {
        ScrollView {
            detailMessageStack
        }
        .defaultScrollAnchor(.bottom)
        .background(Color(.systemGroupedBackground))
    }

    var detailMessageStack: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            conversationSummaryCard

            if queueSummary.hasPendingWork {
                IMConversationQueueBanner(
                    summary: queueSummary,
                    isFlushing: runtimeStore.isFlushingQueuedTextMessages
                )
            }

            if let message = conversationStore.statusMessage, !message.isEmpty {
                IMInlineStatusBanner(message: message)
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
        } else if messages.isEmpty {
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
            }

            ForEach(messages) { message in
                detailMessageRow(message)
                    .id(message.id)
            }
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
                        messageID: message.serverMessageID ?? message.id,
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
            onToggleReaction: { emoji in
                Task {
                    _ = await runtimeStore.toggleMessageReaction(
                        messageID: message.serverMessageID ?? message.id,
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

}

import Foundation

struct IMConversationMessageState: Sendable {
    var conversations: [IMConversation]
    var selectedConversationID: String?
    var statusMessage: String?
    var pendingStreamSnapshotTargets: Set<IMActiveMessageStreamTarget>
}

enum IMConversationMessageStateEvent: Sendable {
    case applyCreatedMessage(IMConversationMessage, clientMessageID: String?)
    case applyUpdatedMessage(IMConversationMessage)
    case applyMessageStreamState(IMTCPMessageStreamPayload)
    case queueStreamSnapshotTarget(IMActiveMessageStreamTarget)
    case removePendingStreamSnapshotTarget(IMActiveMessageStreamTarget)
    case removeMessages(ids: Set<String>, conversationID: String)
    case clearMessages(conversationID: String)
    case updateLocalDownloadState(messageID: String, state: IMMessageLocalDownloadState?)
}

struct IMConversationMessageCursorRefresh: Sendable {
    let conversationID: String
    let timelineItems: [IMConversationTimelineItem]
}

struct IMConversationMessageStateEffect: Sendable {
    var didMutate = false
    var shouldSortConversations = false
    var cursorRefreshes: [IMConversationMessageCursorRefresh] = []
}

struct IMConversationMessageStateReducer: Sendable {
    func reduce(
        _ event: IMConversationMessageStateEvent,
        state: inout IMConversationMessageState,
        ensureConversationIndex: (String, inout [IMConversation]) -> Int,
        latestMessagePreviewText: ([IMConversationMessage], String) -> String,
        latestMessageUpdatedAt: ([IMConversationMessage], Date) -> Date,
        messageComparator: (IMConversationMessage, IMConversationMessage) -> Bool
    ) -> IMConversationMessageStateEffect {
        switch event {
        case let .applyCreatedMessage(message, clientMessageID):
            return applyCreatedMessage(
                message,
                clientMessageID: clientMessageID,
                state: &state,
                ensureConversationIndex: ensureConversationIndex,
                messageComparator: messageComparator
            )
        case let .applyUpdatedMessage(message):
            return applyUpdatedMessage(
                message,
                state: &state,
                ensureConversationIndex: ensureConversationIndex,
                messageComparator: messageComparator
            )
        case let .applyMessageStreamState(stream):
            return applyMessageStreamState(
                stream,
                state: &state,
                ensureConversationIndex: ensureConversationIndex
            )
        case let .queueStreamSnapshotTarget(target):
            return queueStreamSnapshotTarget(target, state: &state)
        case let .removePendingStreamSnapshotTarget(target):
            return removePendingStreamSnapshotTarget(target, state: &state)
        case let .removeMessages(messageIDs, conversationID):
            return removeMessages(
                ids: messageIDs,
                conversationID: conversationID,
                state: &state,
                latestMessagePreviewText: latestMessagePreviewText,
                latestMessageUpdatedAt: latestMessageUpdatedAt
            )
        case let .clearMessages(conversationID):
            return clearMessages(conversationID: conversationID, state: &state)
        case let .updateLocalDownloadState(messageID, downloadState):
            return updateLocalDownloadState(
                messageID: messageID,
                downloadState: downloadState,
                state: &state,
                latestMessagePreviewText: latestMessagePreviewText,
                latestMessageUpdatedAt: latestMessageUpdatedAt
            )
        }
    }

    private func applyCreatedMessage(
        _ message: IMConversationMessage,
        clientMessageID: String?,
        state: inout IMConversationMessageState,
        ensureConversationIndex: (String, inout [IMConversation]) -> Int,
        messageComparator: (IMConversationMessage, IMConversationMessage) -> Bool
    ) -> IMConversationMessageStateEffect {
        let conversationID = message.conversationID
        let serverMessageID = message.serverMessageID
        let index = ensureConversationIndex(conversationID, &state.conversations)

        if message.direction == .outgoing {
            state.conversations[index].pendingMessages.removeAll { pendingMessage in
                if pendingMessage.serverMessageID == serverMessageID {
                    return true
                }
                guard let clientMessageID else {
                    return false
                }
                return pendingMessage.clientMessageID == clientMessageID
            }
        }

        if let existingIndex = state.conversations[index].messages.firstIndex(where: {
            $0.id == serverMessageID
                || $0.serverMessageID == serverMessageID
                || ($0.clientMessageID != nil && $0.clientMessageID == clientMessageID)
        }) {
            state.conversations[index].messages[existingIndex] = message
        } else {
            state.conversations[index].messages.append(message)
        }

        state.conversations[index].messages.sort(by: messageComparator)
        state.conversations[index].lastMessagePreviewText = message.text
        state.conversations[index].updatedAt = max(state.conversations[index].updatedAt, message.createdAt)
        applyIncomingMessageUnreadState(for: conversationID, state: &state)
        state.statusMessage = nil

        return IMConversationMessageStateEffect(
            didMutate: true,
            shouldSortConversations: true,
            cursorRefreshes: [
                IMConversationMessageCursorRefresh(
                    conversationID: conversationID,
                    timelineItems: state.conversations[index].timelineItems
                )
            ]
        )
    }

    private func applyUpdatedMessage(
        _ message: IMConversationMessage,
        state: inout IMConversationMessageState,
        ensureConversationIndex: (String, inout [IMConversation]) -> Int,
        messageComparator: (IMConversationMessage, IMConversationMessage) -> Bool
    ) -> IMConversationMessageStateEffect {
        let conversationID = message.conversationID
        let stableMessageID = message.serverMessageID
        let index = ensureConversationIndex(conversationID, &state.conversations)

        if let messageIndex = state.conversations[index].messages.firstIndex(where: {
            $0.id == stableMessageID || $0.serverMessageID == stableMessageID
        }) {
            state.conversations[index].messages[messageIndex] = message
        } else {
            state.conversations[index].messages.append(message)
        }

        state.conversations[index].messages.sort(by: messageComparator)
        state.conversations[index].lastMessagePreviewText = state.conversations[index].messages.last?.text
            ?? state.conversations[index].lastMessagePreviewText
        state.conversations[index].updatedAt = max(state.conversations[index].updatedAt, message.createdAt)
        return IMConversationMessageStateEffect(didMutate: true, shouldSortConversations: true)
    }

    private func applyMessageStreamState(
        _ stream: IMTCPMessageStreamPayload,
        state: inout IMConversationMessageState,
        ensureConversationIndex: (String, inout [IMConversation]) -> Int
    ) -> IMConversationMessageStateEffect {
        let conversationID = stream.conversationID
        let index = ensureConversationIndex(conversationID, &state.conversations)
        guard let messageIndex = state.conversations[index].messages.firstIndex(where: { message in
            message.serverMessageID == stream.messageID ||
                message.id == stream.messageID ||
                message.derivedState.streamState?.streamID == stream.streamID
        }) else {
            return IMConversationMessageStateEffect()
        }

        var message = state.conversations[index].messages[messageIndex]
        let existingStreamState = message.derivedState.streamState
        if existingStreamState?.state.isTerminal == true, stream.state == .streaming {
            return IMConversationMessageStateEffect()
        }
        if let existingStreamState,
           stream.state == .streaming,
           stream.chunkIndex <= existingStreamState.lastChunkIndex {
            return IMConversationMessageStateEffect()
        }
        if let existingStreamState,
           stream.state == .streaming,
           stream.chunkIndex > existingStreamState.lastChunkIndex + 1 {
            state.pendingStreamSnapshotTargets.insert(
                IMActiveMessageStreamTarget(
                    conversationID: conversationID,
                    messageID: stream.messageID,
                    streamID: stream.streamID
                )
            )
            return IMConversationMessageStateEffect(didMutate: true)
        }
        if existingStreamState == nil,
           stream.state == .streaming,
           stream.chunkIndex > 1 {
            state.pendingStreamSnapshotTargets.insert(
                IMActiveMessageStreamTarget(
                    conversationID: conversationID,
                    messageID: stream.messageID,
                    streamID: stream.streamID
                )
            )
            return IMConversationMessageStateEffect(didMutate: true)
        }

        let existingText = message.content.presentation(derivedState: message.derivedState).textValue ?? ""
        let nextText: String
        if let deltaText = stream.deltaText, stream.state == .streaming {
            nextText = existingText + deltaText
        } else {
            nextText = existingText
        }

        message.content = .richText(.plain(nextText))
        message.derivedState = MessageDerivedState(
            recallState: message.derivedState.recallState,
            edits: message.derivedState.edits,
            reactions: message.derivedState.reactions,
            streamState: MessageStreamState(
                streamID: stream.streamID,
                state: stream.state,
                lastChunkIndex: stream.chunkIndex,
                partialText: nextText,
                updatedAt: stream.serverTimestamp
            )
        )
        state.conversations[index].messages[messageIndex] = message
        state.conversations[index].lastMessagePreviewText = message.text
        state.conversations[index].updatedAt = max(state.conversations[index].updatedAt, stream.serverTimestamp)
        return IMConversationMessageStateEffect(didMutate: true, shouldSortConversations: true)
    }

    private func queueStreamSnapshotTarget(
        _ target: IMActiveMessageStreamTarget,
        state: inout IMConversationMessageState
    ) -> IMConversationMessageStateEffect {
        let didInsert = state.pendingStreamSnapshotTargets.insert(target).inserted
        return IMConversationMessageStateEffect(didMutate: didInsert)
    }

    private func removePendingStreamSnapshotTarget(
        _ target: IMActiveMessageStreamTarget,
        state: inout IMConversationMessageState
    ) -> IMConversationMessageStateEffect {
        let didRemove = state.pendingStreamSnapshotTargets.remove(target) != nil
        return IMConversationMessageStateEffect(didMutate: didRemove)
    }

    private func removeMessages(
        ids messageIDs: Set<String>,
        conversationID: String,
        state: inout IMConversationMessageState,
        latestMessagePreviewText: ([IMConversationMessage], String) -> String,
        latestMessageUpdatedAt: ([IMConversationMessage], Date) -> Date
    ) -> IMConversationMessageStateEffect {
        guard let index = state.conversations.firstIndex(where: { $0.id == conversationID }),
              !messageIDs.isEmpty
        else {
            return IMConversationMessageStateEffect()
        }

        state.conversations[index].messages.removeAll { message in
            messageIDs.contains(message.id) ||
                messageIDs.contains(message.serverMessageID)
        }
        state.conversations[index].lastMessagePreviewText = latestMessagePreviewText(
            state.conversations[index].messages,
            ""
        )
        state.conversations[index].updatedAt = latestMessageUpdatedAt(
            state.conversations[index].messages,
            state.conversations[index].updatedAt
        )
        return IMConversationMessageStateEffect(didMutate: true)
    }

    private func clearMessages(
        conversationID: String,
        state: inout IMConversationMessageState
    ) -> IMConversationMessageStateEffect {
        guard let index = state.conversations.firstIndex(where: { $0.id == conversationID }) else {
            return IMConversationMessageStateEffect()
        }

        state.conversations[index].messages.removeAll()
        state.conversations[index].lastMessagePreviewText = ""
        state.conversations[index].serverUnreadCount = 0
        state.conversations[index].localUnreadDelta = 0
        return IMConversationMessageStateEffect(didMutate: true)
    }

    private func updateLocalDownloadState(
        messageID: String,
        downloadState: IMMessageLocalDownloadState?,
        state: inout IMConversationMessageState,
        latestMessagePreviewText: ([IMConversationMessage], String) -> String,
        latestMessageUpdatedAt: ([IMConversationMessage], Date) -> Date
    ) -> IMConversationMessageStateEffect {
        for conversationIndex in state.conversations.indices {
            guard let messageIndex = state.conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID }) else {
                continue
            }

            state.conversations[conversationIndex].messages[messageIndex].localDownloadState = downloadState
            if let taskID = downloadState?.taskID {
                state.conversations[conversationIndex].messages[messageIndex].transferTaskID = taskID
            }
            state.conversations[conversationIndex].updatedAt = latestMessageUpdatedAt(
                state.conversations[conversationIndex].messages,
                state.conversations[conversationIndex].messages[messageIndex].createdAt
            )
            state.conversations[conversationIndex].lastMessagePreviewText = latestMessagePreviewText(
                state.conversations[conversationIndex].messages,
                state.conversations[conversationIndex].lastMessagePreviewText
            )
            return IMConversationMessageStateEffect(didMutate: true, shouldSortConversations: true)
        }
        return IMConversationMessageStateEffect()
    }

    private func applyIncomingMessageUnreadState(
        for conversationID: String,
        state: inout IMConversationMessageState
    ) {
        if state.selectedConversationID == nil {
            state.selectedConversationID = conversationID
        }

        guard state.selectedConversationID != conversationID,
              let index = state.conversations.firstIndex(where: { $0.id == conversationID })
        else {
            return
        }

        state.conversations[index].localUnreadDelta += 1
    }
}

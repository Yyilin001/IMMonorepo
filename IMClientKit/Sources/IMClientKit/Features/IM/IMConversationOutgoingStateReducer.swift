import Foundation

struct IMConversationOutgoingState: Sendable {
    var conversations: [IMConversation]
    var selectedConversationID: String?
    var statusMessage: String?
    var outgoingQueueState: OutgoingQueueState
}

enum IMConversationOutgoingStateEvent: Sendable {
    case appendOutgoingMessage(
        content: IMMessageContent,
        conversationID: String,
        senderUserID: UUID,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool,
        localTransferState: IMMessageLocalTransferState?,
        requestID: UUID,
        clientMessageID: String,
        createdAt: Date
    )
    case retryOutgoingMessage(
        localMessageID: String,
        conversationID: String,
        requestID: UUID
    )
    case queueRetryableOutgoingMessage(
        localMessageID: String,
        conversationID: String,
        message: String
    )
    case cancelQueuedOutgoingMessage(
        localMessageID: String,
        conversationID: String
    )
    case startQueuedOutgoingMessage(
        localMessageID: String,
        conversationID: String,
        requestID: UUID
    )
    case markOutgoingQueued(
        requestID: UUID,
        message: String
    )
    case markOutgoingFailure(
        requestID: UUID,
        message: String
    )
    case markAllPendingMessagesFailed(message: String)
    case markAllPendingMessagesUnknown(message: String)
    case applyAcceptedOutgoingAcknowledgement(
        localMessageID: String,
        serverMessageID: String
    )
    case applyRejectedOutgoingAcknowledgement(
        localMessageID: String,
        message: String
    )
    case markOutgoingPreparing(
        localMessageID: String,
        message: String,
        uploadID: String?
    )
    case markOutgoingUploading(
        localMessageID: String,
        message: String,
        uploadID: String?
    )
    case markOutgoingUploadFailed(
        localMessageID: String,
        message: String
    )
    case abandonRecoverableOutgoingMediaUpload(
        localMessageID: String,
        message: String
    )
    case updateUploadedOutgoingMedia(
        content: IMMessageContent,
        localMessageID: String,
        conversationID: String,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool,
        requestID: UUID
    )
}

struct IMConversationOutgoingStateEffect: Sendable {
    var placeholder: IMOutgoingMediaPlaceholder?
    var request: IMOutgoingMessageRequest?
    var didMutate = false
    var didApply = false
    var shouldSortConversations = false
    var missingPendingMessageID: String?
}

struct IMConversationOutgoingStateReducer: Sendable {
    func reduce(
        _ event: IMConversationOutgoingStateEvent,
        state: inout IMConversationOutgoingState,
        ensureConversationIndex: (String, inout [IMConversation]) -> Int,
        latestMessagePreviewText: ([IMConversationMessage], String) -> String,
        latestMessageUpdatedAt: ([IMConversationMessage], Date) -> Date,
        isRetryableFailure: (IMPendingConversationMessage) -> Bool
    ) -> IMConversationOutgoingStateEffect {
        switch event {
        case let .appendOutgoingMessage(
            content,
            conversationID,
            senderUserID,
            deliveryState,
            shouldRegisterPendingRequest,
            localTransferState,
            requestID,
            clientMessageID,
            createdAt
        ):
            return appendOutgoingMessage(
                content,
                conversationID: conversationID,
                senderUserID: senderUserID,
                deliveryState: deliveryState,
                shouldRegisterPendingRequest: shouldRegisterPendingRequest,
                localTransferState: localTransferState,
                requestID: requestID,
                clientMessageID: clientMessageID,
                createdAt: createdAt,
                state: &state,
                ensureConversationIndex: ensureConversationIndex
            )
        case let .retryOutgoingMessage(localMessageID, conversationID, requestID):
            return retryOutgoingMessage(
                localMessageID: localMessageID,
                conversationID: conversationID,
                requestID: requestID,
                state: &state,
                isRetryableFailure: isRetryableFailure
            )
        case let .queueRetryableOutgoingMessage(localMessageID, conversationID, message):
            return queueRetryableOutgoingMessage(
                localMessageID: localMessageID,
                conversationID: conversationID,
                queueMessage: message,
                state: &state,
                isRetryableFailure: isRetryableFailure
            )
        case let .cancelQueuedOutgoingMessage(localMessageID, conversationID):
            return cancelQueuedOutgoingMessage(
                localMessageID: localMessageID,
                conversationID: conversationID,
                state: &state,
                latestMessagePreviewText: latestMessagePreviewText,
                latestMessageUpdatedAt: latestMessageUpdatedAt
            )
        case let .startQueuedOutgoingMessage(localMessageID, conversationID, requestID):
            return startQueuedOutgoingMessage(
                localMessageID: localMessageID,
                conversationID: conversationID,
                requestID: requestID,
                state: &state
            )
        case let .markOutgoingQueued(requestID, message):
            guard let localMessageID = state.outgoingQueueState.removePendingRequest(requestID) else {
                return IMConversationOutgoingStateEffect()
            }
            return mutatePendingMessage(
                id: localMessageID,
                state: &state,
                update: { $0.deliveryState = .queued(message: message) }
            )
        case let .markOutgoingFailure(requestID, message):
            guard let localMessageID = state.outgoingQueueState.removePendingRequest(requestID) else {
                state.statusMessage = message
                return IMConversationOutgoingStateEffect()
            }
            var effect = mutatePendingMessage(
                id: localMessageID,
                state: &state,
                update: { $0.deliveryState = .failed(message: message) }
            )
            state.statusMessage = message
            effect.didApply = true
            return effect
        case let .markAllPendingMessagesFailed(message):
            return markAllPendingMessages(
                state: &state,
                deliveryState: .failed(message: message),
                statusMessage: message
            )
        case let .markAllPendingMessagesUnknown(message):
            return markAllPendingMessages(
                state: &state,
                deliveryState: .unknown(message: message),
                statusMessage: message
            )
        case let .applyAcceptedOutgoingAcknowledgement(localMessageID, serverMessageID):
            let effect = mutatePendingMessage(
                id: localMessageID,
                state: &state,
                update: { message in
                    message.deliveryState = .sent
                    let trimmedServerMessageID = serverMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedServerMessageID.isEmpty {
                        message.serverMessageID = trimmedServerMessageID
                    }
                }
            )
            state.statusMessage = nil
            return effect
        case let .applyRejectedOutgoingAcknowledgement(localMessageID, message):
            var effect = mutatePendingMessage(
                id: localMessageID,
                state: &state,
                update: { $0.deliveryState = .failed(message: message) }
            )
            state.statusMessage = message
            effect.didApply = true
            return effect
        case let .markOutgoingPreparing(localMessageID, message, uploadID):
            return mutatePendingMessage(
                id: localMessageID,
                state: &state,
                update: { item in
                    item.deliveryState = .preparing(message: message)
                    if let uploadID, let transferState = item.localTransferState {
                        item.localTransferState = transferState.withUploadID(uploadID)
                    }
                }
            )
        case let .markOutgoingUploading(localMessageID, message, uploadID):
            return mutatePendingMessage(
                id: localMessageID,
                state: &state,
                update: { item in
                    item.deliveryState = .uploading(message: message)
                    if let uploadID, let transferState = item.localTransferState {
                        item.localTransferState = transferState.withUploadID(uploadID)
                    }
                }
            )
        case let .markOutgoingUploadFailed(localMessageID, message):
            var effect = mutatePendingMessage(
                id: localMessageID,
                state: &state,
                update: { $0.deliveryState = .failed(message: message) }
            )
            state.statusMessage = message
            effect.didApply = true
            return effect
        case let .abandonRecoverableOutgoingMediaUpload(localMessageID, message):
            var effect = mutatePendingMessage(
                id: localMessageID,
                state: &state,
                update: { item in
                    item.deliveryState = .failed(message: message)
                    item.localTransferState = nil
                }
            )
            state.statusMessage = message
            effect.didApply = true
            return effect
        case let .updateUploadedOutgoingMedia(
            content,
            localMessageID,
            conversationID,
            deliveryState,
            shouldRegisterPendingRequest,
            requestID
        ):
            return updateUploadedOutgoingMedia(
                content: content,
                localMessageID: localMessageID,
                conversationID: conversationID,
                deliveryState: deliveryState,
                shouldRegisterPendingRequest: shouldRegisterPendingRequest,
                requestID: requestID,
                state: &state
            )
        }
    }

    private func appendOutgoingMessage(
        _ content: IMMessageContent,
        conversationID: String,
        senderUserID: UUID,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool,
        localTransferState: IMMessageLocalTransferState?,
        requestID: UUID,
        clientMessageID: String,
        createdAt: Date,
        state: inout IMConversationOutgoingState,
        ensureConversationIndex: (String, inout [IMConversation]) -> Int
    ) -> IMConversationOutgoingStateEffect {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            state.statusMessage = "当前没有可用会话。"
            return IMConversationOutgoingStateEffect()
        }

        guard content.isUserComposable else {
            state.statusMessage = "当前消息类型不支持发送。"
            return IMConversationOutgoingStateEffect()
        }

        guard !content.previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state.statusMessage = "消息内容不能为空。"
            return IMConversationOutgoingStateEffect()
        }

        let index = ensureConversationIndex(trimmedConversationID, &state.conversations)
        let localMessageID = clientMessageID
        let message = IMPendingConversationMessage(
            localMessageID: localMessageID,
            clientMessageID: clientMessageID,
            conversationID: trimmedConversationID,
            senderUserID: senderUserID,
            content: content,
            createdAt: createdAt,
            deliveryState: deliveryState,
            localTransferState: localTransferState
        )

        state.conversations[index].pendingMessages.append(message)
        state.conversations[index].lastMessagePreviewText = content.previewText
        state.conversations[index].updatedAt = createdAt
        state.conversations[index].draftText = ""
        state.conversations[index].draftUpdatedAt = nil
        state.conversations[index].serverUnreadCount = 0
        state.conversations[index].localUnreadDelta = 0
        state.selectedConversationID = trimmedConversationID
        if shouldRegisterPendingRequest {
            state.outgoingQueueState.registerPendingRequest(requestID, localMessageID: localMessageID)
        }
        state.statusMessage = nil

        let payload = IMTCPMessagePayload(
            clientMessageID: clientMessageID,
            messageID: nil,
            conversationID: trimmedConversationID,
            senderUserID: nil,
            serverSequence: nil,
            serverTimestamp: nil,
            content: content
        )
        return IMConversationOutgoingStateEffect(
            placeholder: IMOutgoingMediaPlaceholder(localMessageID: localMessageID, clientMessageID: clientMessageID),
            request: shouldRegisterPendingRequest
                ? IMOutgoingMessageRequest(
                    requestID: requestID,
                    localMessageID: localMessageID,
                    payload: payload
                )
                : nil,
            didMutate: true,
            didApply: true,
            shouldSortConversations: true
        )
    }

    private func retryOutgoingMessage(
        localMessageID: String,
        conversationID: String,
        requestID: UUID,
        state: inout IMConversationOutgoingState,
        isRetryableFailure: (IMPendingConversationMessage) -> Bool
    ) -> IMConversationOutgoingStateEffect {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = localMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            state.statusMessage = "消息重试失败：会话或消息无效。"
            return IMConversationOutgoingStateEffect()
        }

        guard let conversationIndex = state.conversations.firstIndex(where: { $0.id == trimmedConversationID }),
              let messageIndex = state.conversations[conversationIndex].pendingMessages.firstIndex(where: { $0.id == trimmedMessageID })
        else {
            state.statusMessage = "消息重试失败：本地消息不存在。"
            return IMConversationOutgoingStateEffect()
        }

        var message = state.conversations[conversationIndex].pendingMessages[messageIndex]
        guard message.direction == .outgoing, message.content.isUserComposable else {
            state.statusMessage = "只能重试自己发送的消息。"
            return IMConversationOutgoingStateEffect()
        }

        guard isRetryableFailure(message) else {
            state.statusMessage = "该消息失败原因不可重试。"
            return IMConversationOutgoingStateEffect()
        }

        message.deliveryState = .sending
        state.conversations[conversationIndex].pendingMessages[messageIndex] = message
        state.outgoingQueueState.registerPendingRequest(requestID, localMessageID: message.id)
        state.selectedConversationID = trimmedConversationID
        state.statusMessage = nil

        return IMConversationOutgoingStateEffect(
            request: outgoingRequest(
                requestID: requestID,
                message: message,
                conversationID: trimmedConversationID
            ),
            didMutate: true,
            didApply: true,
            shouldSortConversations: true
        )
    }

    private func queueRetryableOutgoingMessage(
        localMessageID: String,
        conversationID: String,
        queueMessage: String,
        state: inout IMConversationOutgoingState,
        isRetryableFailure: (IMPendingConversationMessage) -> Bool
    ) -> IMConversationOutgoingStateEffect {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = localMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            state.statusMessage = "消息排队失败：会话或消息无效。"
            return IMConversationOutgoingStateEffect()
        }

        guard let conversationIndex = state.conversations.firstIndex(where: { $0.id == trimmedConversationID }),
              let messageIndex = state.conversations[conversationIndex].pendingMessages.firstIndex(where: { $0.id == trimmedMessageID })
        else {
            state.statusMessage = "消息排队失败：本地消息不存在。"
            return IMConversationOutgoingStateEffect()
        }

        var message = state.conversations[conversationIndex].pendingMessages[messageIndex]
        guard isRetryableFailure(message) else {
            state.statusMessage = "该消息失败原因不可排队重试。"
            return IMConversationOutgoingStateEffect()
        }

        state.outgoingQueueState.removePendingRequests(for: message.id)
        message.deliveryState = .queued(message: queueMessage)
        state.conversations[conversationIndex].pendingMessages[messageIndex] = message
        state.selectedConversationID = trimmedConversationID
        state.statusMessage = nil
        return IMConversationOutgoingStateEffect(didMutate: true, didApply: true, shouldSortConversations: true)
    }

    private func cancelQueuedOutgoingMessage(
        localMessageID: String,
        conversationID: String,
        state: inout IMConversationOutgoingState,
        latestMessagePreviewText: ([IMConversationMessage], String) -> String,
        latestMessageUpdatedAt: ([IMConversationMessage], Date) -> Date
    ) -> IMConversationOutgoingStateEffect {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = localMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            state.statusMessage = "取消发送失败：会话或消息无效。"
            return IMConversationOutgoingStateEffect()
        }

        guard let conversationIndex = state.conversations.firstIndex(where: { $0.id == trimmedConversationID }),
              let messageIndex = state.conversations[conversationIndex].pendingMessages.firstIndex(where: { $0.id == trimmedMessageID })
        else {
            state.statusMessage = "取消发送失败：本地消息不存在。"
            return IMConversationOutgoingStateEffect()
        }

        let message = state.conversations[conversationIndex].pendingMessages[messageIndex]
        guard message.direction == .outgoing, message.content.isUserComposable, message.isQueued else {
            state.statusMessage = "只能取消尚未发送的消息。"
            return IMConversationOutgoingStateEffect()
        }

        state.outgoingQueueState.removePendingRequests(for: message.id)
        state.conversations[conversationIndex].pendingMessages.remove(at: messageIndex)
        refreshConversationPresentationAfterLocalMessageRemoval(
            at: conversationIndex,
            state: &state,
            latestMessagePreviewText: latestMessagePreviewText,
            latestMessageUpdatedAt: latestMessageUpdatedAt
        )
        state.selectedConversationID = trimmedConversationID
        state.statusMessage = nil
        return IMConversationOutgoingStateEffect(didMutate: true, didApply: true, shouldSortConversations: true)
    }

    private func startQueuedOutgoingMessage(
        localMessageID: String,
        conversationID: String,
        requestID: UUID,
        state: inout IMConversationOutgoingState
    ) -> IMConversationOutgoingStateEffect {
        guard let conversationIndex = state.conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = state.conversations[conversationIndex].pendingMessages.firstIndex(where: { $0.id == localMessageID })
        else {
            return IMConversationOutgoingStateEffect()
        }

        var message = state.conversations[conversationIndex].pendingMessages[messageIndex]
        guard message.direction == .outgoing, message.isQueued else {
            return IMConversationOutgoingStateEffect()
        }

        message.deliveryState = .sending
        state.conversations[conversationIndex].pendingMessages[messageIndex] = message
        state.outgoingQueueState.registerPendingRequest(requestID, localMessageID: message.id)
        return IMConversationOutgoingStateEffect(
            request: outgoingRequest(
                requestID: requestID,
                message: message,
                conversationID: conversationID
            ),
            didMutate: true,
            didApply: true,
            shouldSortConversations: true
        )
    }

    private func updateUploadedOutgoingMedia(
        content: IMMessageContent,
        localMessageID: String,
        conversationID: String,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool,
        requestID: UUID,
        state: inout IMConversationOutgoingState
    ) -> IMConversationOutgoingStateEffect {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocalMessageID = localMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedLocalMessageID.isEmpty else {
            return IMConversationOutgoingStateEffect()
        }
        guard let conversationIndex = state.conversations.firstIndex(where: { $0.id == trimmedConversationID }),
              let messageIndex = state.conversations[conversationIndex].pendingMessages.firstIndex(where: { $0.id == trimmedLocalMessageID })
        else {
            state.statusMessage = "附件消息不存在。"
            return IMConversationOutgoingStateEffect()
        }

        guard content.isUserComposable else {
            state.statusMessage = "当前消息类型不支持发送。"
            return IMConversationOutgoingStateEffect()
        }

        var message = state.conversations[conversationIndex].pendingMessages[messageIndex]
        message.content = content
        message.deliveryState = deliveryState
        message.localTransferState = nil
        state.conversations[conversationIndex].pendingMessages[messageIndex] = message
        state.conversations[conversationIndex].lastMessagePreviewText = content.previewText
        state.conversations[conversationIndex].updatedAt = message.createdAt
        state.selectedConversationID = trimmedConversationID
        if shouldRegisterPendingRequest {
            state.outgoingQueueState.registerPendingRequest(requestID, localMessageID: message.id)
        }
        state.statusMessage = nil

        return IMConversationOutgoingStateEffect(
            request: shouldRegisterPendingRequest
                ? outgoingRequest(
                    requestID: requestID,
                    message: message,
                    conversationID: trimmedConversationID
                )
                : nil,
            didMutate: true,
            didApply: true,
            shouldSortConversations: true
        )
    }

    private func markAllPendingMessages(
        state: inout IMConversationOutgoingState,
        deliveryState: IMMessageDeliveryState,
        statusMessage: String
    ) -> IMConversationOutgoingStateEffect {
        let pendingMessageIDs = state.outgoingQueueState.drainPendingMessageIDs()
        var effect = IMConversationOutgoingStateEffect()

        for localMessageID in pendingMessageIDs {
            let nextEffect = mutatePendingMessage(
                id: localMessageID,
                state: &state,
                update: { $0.deliveryState = deliveryState }
            )
            effect.didMutate = effect.didMutate || nextEffect.didMutate
            effect.didApply = effect.didApply || nextEffect.didApply
            effect.shouldSortConversations = effect.shouldSortConversations || nextEffect.shouldSortConversations
            effect.missingPendingMessageID = effect.missingPendingMessageID ?? nextEffect.missingPendingMessageID
        }

        if !pendingMessageIDs.isEmpty {
            state.statusMessage = statusMessage
        }

        return effect
    }

    private func mutatePendingMessage(
        id: String,
        state: inout IMConversationOutgoingState,
        update: (inout IMPendingConversationMessage) -> Void
    ) -> IMConversationOutgoingStateEffect {
        for conversationIndex in state.conversations.indices {
            guard let messageIndex = state.conversations[conversationIndex].pendingMessages.firstIndex(where: { $0.id == id }) else {
                continue
            }

            update(&state.conversations[conversationIndex].pendingMessages[messageIndex])
            let updatedMessage = state.conversations[conversationIndex].pendingMessages[messageIndex]
            state.conversations[conversationIndex].updatedAt = updatedMessage.createdAt
            state.conversations[conversationIndex].lastMessagePreviewText = updatedMessage.text
            return IMConversationOutgoingStateEffect(didMutate: true, didApply: true, shouldSortConversations: true)
        }

        return IMConversationOutgoingStateEffect(missingPendingMessageID: id)
    }

    private func refreshConversationPresentationAfterLocalMessageRemoval(
        at conversationIndex: Int,
        state: inout IMConversationOutgoingState,
        latestMessagePreviewText: ([IMConversationMessage], String) -> String,
        latestMessageUpdatedAt: ([IMConversationMessage], Date) -> Date
    ) {
        guard state.conversations.indices.contains(conversationIndex) else {
            return
        }

        if let latestPending = state.conversations[conversationIndex].pendingMessages.last {
            state.conversations[conversationIndex].lastMessagePreviewText = latestPending.text
            state.conversations[conversationIndex].updatedAt = latestPending.createdAt
        } else if let latestMessage = state.conversations[conversationIndex].messages.last {
            state.conversations[conversationIndex].lastMessagePreviewText = latestMessagePreviewText(
                state.conversations[conversationIndex].messages,
                latestMessage.text
            )
            state.conversations[conversationIndex].updatedAt = latestMessageUpdatedAt(
                state.conversations[conversationIndex].messages,
                latestMessage.createdAt
            )
        } else {
            state.conversations[conversationIndex].lastMessagePreviewText = ""
        }
    }

    private func outgoingRequest(
        requestID: UUID,
        message: IMPendingConversationMessage,
        conversationID: String
    ) -> IMOutgoingMessageRequest {
        IMOutgoingMessageRequest(
            requestID: requestID,
            localMessageID: message.id,
            payload: IMTCPMessagePayload(
                clientMessageID: message.clientMessageID,
                messageID: nil,
                conversationID: conversationID,
                senderUserID: nil,
                serverSequence: nil,
                serverTimestamp: nil,
                content: message.content
            )
        )
    }
}

private extension IMPendingConversationMessage {
    var isQueued: Bool {
        if case .queued = deliveryState {
            return true
        }
        return false
    }
}

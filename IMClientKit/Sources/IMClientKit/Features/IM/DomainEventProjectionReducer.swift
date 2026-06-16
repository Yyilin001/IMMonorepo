import Foundation

struct DomainEventProjectionReducer: Sendable {
    struct DependencySnapshot: Equatable, Sendable {
        var processedEventIDs: Set<UUID>
        var ownerAggregateHighWatermarks: [IMOwnerAggregateKey: UInt64]
        var existingMessageKeys: Set<MessageKey>

        init(
            processedEventIDs: Set<UUID>,
            ownerAggregateHighWatermarks: [IMOwnerAggregateKey: UInt64],
            existingMessageKeys: Set<MessageKey>
        ) {
            self.processedEventIDs = processedEventIDs
            self.ownerAggregateHighWatermarks = ownerAggregateHighWatermarks
            self.existingMessageKeys = existingMessageKeys
        }
    }

    struct MessageKey: Hashable, Sendable {
        let conversationID: String
        let messageID: String
    }

    enum DeferReason: String, Equatable, Sendable {
        case ownerAggregateGap
        case missingMessage
        case missingConversation
        case missingStreamMessage
    }

    enum Operation: Equatable, Sendable {
        case ignoreDuplicate
        case applyMessageCreated(
            message: IMConversationMessage,
            clientMessageID: String?,
            notice: IMTimelineNotice?,
            summary: IMConversationSummaryResponseBody?
        )
        case applyMessageMutation(
            messageID: UUID,
            message: IMConversationMessage?,
            notice: IMTimelineNotice?,
            summary: IMConversationSummaryResponseBody?
        )
        case applyVisibility(
            conversationID: String,
            messageIDs: [UUID],
            message: IMConversationMessage?,
            action: IMTCPConversationVisibilityAction?,
            notice: IMTimelineNotice?,
            summary: IMConversationSummaryResponseBody?
        )
        case applyMessageFavorite(
            messageID: UUID,
            isFavorited: Bool,
            notice: IMTimelineNotice?,
            summary: IMConversationSummaryResponseBody?
        )
        case applyMessageStream(
            stream: IMTCPMessageStreamPayload,
            message: IMConversationMessage?,
            notice: IMTimelineNotice?,
            summary: IMConversationSummaryResponseBody?
        )
        case applyConversationChange(
            notice: IMTimelineNotice?,
            summary: IMConversationSummaryResponseBody?
        )
        case removeConversation(
            conversationID: String,
            notice: IMTimelineNotice?
        )
        case applyConversationVisibility(
            conversationID: String,
            action: IMTCPConversationVisibilityAction,
            messageIDs: [UUID],
            notice: IMTimelineNotice?,
            summary: IMConversationSummaryResponseBody?
        )
        case applyMemberChange(
            conversationID: String,
            memberUserIDs: [UUID],
            notice: IMTimelineNotice?,
            summary: IMConversationSummaryResponseBody?
        )
        case applyContactChange(
            notice: IMTimelineNotice?,
            summary: IMConversationSummaryResponseBody?
        )
        case deferEvent(reason: DeferReason, missingKey: IMDeferredDomainEventMissingKey?, conversationID: String?)
        case requestCatchUp(String)
        case rejectInvalid(String)
    }

    func reduce(
        event: IMTCPChatDomainEventPayload,
        currentUserID: UUID,
        dependencies: DependencySnapshot
    ) -> Operation {
        if dependencies.processedEventIDs.contains(event.eventID) {
            return .ignoreDuplicate
        }

        if event.requiresTimelineNotice, event.timelineNotice == nil {
            return .requestCatchUp("required timeline notice is missing")
        }
        let notice: IMTimelineNotice?
        do {
            notice = try event.timelineNotice.map(Self.makeNotice)
        } catch {
            return .rejectInvalid("invalid timeline notice: \(error)")
        }

        if hasOwnerAggregateGap(event, dependencies: dependencies) {
            return .deferEvent(
                reason: .ownerAggregateGap,
                missingKey: deferredMissingKey(for: event),
                conversationID: deferredConversationID(for: event)
            )
        }

        switch event.body {
        case .messageCreated(let message, let clientMessageID):
            let canonicalMessage: IMConversationMessage
            do {
                canonicalMessage = try Self.makeMessage(from: message, currentUserID: currentUserID)
            } catch {
                return .rejectInvalid("invalid message_created canonical message: \(error)")
            }
            return .applyMessageCreated(
                message: canonicalMessage,
                clientMessageID: clientMessageID ?? message.clientMessageID,
                notice: notice,
                summary: event.conversation
            )
        case .messageEdited(let messageID, _, _, let message),
             .messageRevoked(let messageID, _, _, let message):
            let conversationID = message?.conversationID.uuidString ?? event.aggregateID.uuidString
            guard dependencies.existingMessageKeys.contains(
                MessageKey(conversationID: conversationID, messageID: messageID.uuidString)
            ) else {
                return .deferEvent(
                    reason: .missingMessage,
                    missingKey: .message(messageID.uuidString),
                    conversationID: conversationID
                )
            }
            let canonicalMessage: IMConversationMessage?
            do {
                canonicalMessage = try message.map { try Self.makeMessage(from: $0, currentUserID: currentUserID) }
            } catch {
                return .rejectInvalid("invalid message mutation canonical message: \(error)")
            }
            return .applyMessageMutation(
                messageID: messageID,
                message: canonicalMessage,
                notice: notice,
                summary: event.conversation
            )
        case .messageVisibilityChanged(let messageIDs, let message, let visibilityAction):
            let canonicalMessage: IMConversationMessage?
            do {
                canonicalMessage = try message.map { try Self.makeMessage(from: $0, currentUserID: currentUserID) }
            } catch {
                return .rejectInvalid("invalid visibility canonical message: \(error)")
            }
            return .applyVisibility(
                conversationID: event.conversation?.id.uuidString ?? canonicalMessage?.conversationID ?? message?.conversationID.uuidString ?? event.aggregateID.uuidString,
                messageIDs: messageIDs,
                message: canonicalMessage,
                action: visibilityAction,
                notice: notice,
                summary: event.conversation
            )
        case .messageFavoriteChanged(let messageID, let isFavorited):
            return .applyMessageFavorite(
                messageID: messageID,
                isFavorited: isFavorited,
                notice: notice,
                summary: event.conversation
            )
        case .messageStream(let stream, let message):
            let canonicalMessage: IMConversationMessage?
            do {
                canonicalMessage = try message.map { try Self.makeMessage(from: $0, currentUserID: currentUserID) }
            } catch {
                return .rejectInvalid("invalid stream canonical message: \(error)")
            }
            if canonicalMessage != nil {
                return .applyMessageStream(
                    stream: stream,
                    message: canonicalMessage,
                    notice: notice,
                    summary: event.conversation
                )
            }
            return dependencies.existingMessageKeys.contains(
                MessageKey(conversationID: stream.conversationID, messageID: stream.messageID)
            )
                ? .applyMessageStream(
                    stream: stream,
                    message: canonicalMessage,
                    notice: notice,
                    summary: event.conversation
                )
                : .deferEvent(
                    reason: .missingStreamMessage,
                    missingKey: .stream(conversationID: stream.conversationID, messageID: stream.messageID),
                    conversationID: stream.conversationID
                )
        case .conversationChanged:
            return .applyConversationChange(notice: notice, summary: event.conversation)
        case .conversationActivityHint(let hint):
            return .applyConversationChange(
                notice: notice,
                summary: Self.activityOnlySummary(from: hint, event: event)
            )
        case .conversationRemovedForSelf:
            return .removeConversation(conversationID: event.aggregateID.uuidString, notice: notice)
        case .conversationVisibilityChanged(let visibilityAction, let messageIDs):
            return .applyConversationVisibility(
                conversationID: event.conversation?.id.uuidString ?? event.aggregateID.uuidString,
                action: visibilityAction,
                messageIDs: messageIDs,
                notice: notice,
                summary: event.conversation
            )
        case .memberChanged(let memberUserIDs):
            return .applyMemberChange(
                conversationID: event.conversation?.id.uuidString ?? event.aggregateID.uuidString,
                memberUserIDs: memberUserIDs,
                notice: notice,
                summary: event.conversation
            )
        case .contactChanged:
            return .applyContactChange(notice: notice, summary: event.conversation)
        }
    }

    private static func makeMessage(
        from response: IMConversationMessageResponseBody,
        currentUserID: UUID
    ) throws -> IMConversationMessage {
        try IMConversationMessage(
            id: response.id.uuidString,
            conversationID: response.conversationID.uuidString,
            clientMessageID: response.clientMessageID,
            serverMessageID: response.id.uuidString,
            senderUserID: response.senderUserID,
            serverSequence: UInt64(response.serverSequence),
            timelineSequence: UInt64(response.timelineSequence),
            content: response.content,
            derivedState: response.derivedState,
            direction: response.senderUserID == currentUserID ? .outgoing : .incoming,
            createdAt: response.createdAt ?? Date(),
            deliveryState: response.senderUserID == currentUserID ? .sent : .received
        )
    }

    private static func activityOnlySummary(
        from hint: IMConversationActivityHintResponseBody,
        event: IMTCPChatDomainEventPayload
    ) -> IMConversationSummaryResponseBody {
        IMConversationSummaryResponseBody(
            id: event.aggregateID,
            title: nil,
            kind: IMConversationKind.group.rawValue,
            memberCount: 0,
            memberUserIDs: [],
            lastMessage: IMMessagePreviewResponseBody(
                id: hint.messageID,
                senderUserID: hint.senderUserID,
                serverSequence: hint.serverSequence,
                timelineSequence: hint.timelineSequence,
                content: .richText(.plain(hint.previewText)),
                derivedState: IMMessageDerivedState(),
                createdAt: hint.messageCreatedAt
            ),
            lastReadSequence: 0,
            unreadCount: 0,
            createdAt: nil,
            updatedAt: hint.updatedAt
        )
    }

    private static func makeNotice(from response: IMTimelineNoticeResponseBody) throws -> IMTimelineNotice {
        guard response.timelineSequence > 0 else {
            throw IMConversationMessageValidationError.invalidTimelineSequence(response.timelineSequence)
        }
        return try IMTimelineNotice(
            id: response.id.uuidString,
            conversationID: response.conversationID.uuidString,
            timelineSequence: UInt64(response.timelineSequence),
            eventType: response.eventType,
            actorUserID: response.actorUserID,
            targetUserIDs: response.targetUserIDs,
            noticeKind: response.noticeKind,
            params: response.params,
            fallbackText: response.fallbackText,
            createdAt: response.createdAt
        )
    }

    private func hasOwnerAggregateGap(
        _ event: IMTCPChatDomainEventPayload,
        dependencies: DependencySnapshot
    ) -> Bool {
        guard let ownerAggregateSequence = event.ownerAggregateSequence,
              ownerAggregateSequence > 0
        else {
            return false
        }
        let key = IMOwnerAggregateKey(
            aggregateType: event.aggregateType,
            aggregateID: event.aggregateID.uuidString
        )
        let highWatermark = dependencies.ownerAggregateHighWatermarks[key] ?? 0
        return ownerAggregateSequence > highWatermark + 1
    }

    private func deferredMissingKey(for event: IMTCPChatDomainEventPayload) -> IMDeferredDomainEventMissingKey? {
        switch event.body {
        case .messageEdited(let messageID, _, _, _),
             .messageRevoked(let messageID, _, _, _),
             .messageFavoriteChanged(let messageID, _):
            return .message(messageID.uuidString)
        case .messageVisibilityChanged(let messageIDs, let message, _):
            return message.map { .message($0.id.uuidString) } ?? messageIDs.first.map { .message($0.uuidString) }
        case .messageStream(let stream, _):
            return .stream(conversationID: stream.conversationID, messageID: stream.messageID)
        case .conversationChanged,
             .conversationActivityHint,
             .conversationRemovedForSelf,
             .conversationVisibilityChanged,
             .memberChanged:
            return .conversation(event.aggregateID.uuidString)
        case .messageCreated,
             .contactChanged:
            return nil
        }
    }

    private func deferredConversationID(for event: IMTCPChatDomainEventPayload) -> String? {
        if let conversationID = event.conversation?.id.uuidString {
            return conversationID
        }
        switch event.body {
        case .messageCreated(let message, _):
            return message.conversationID.uuidString
        case .messageEdited(_, _, _, let message),
             .messageRevoked(_, _, _, let message),
             .messageVisibilityChanged(_, let message, _):
            return message?.conversationID.uuidString ?? event.aggregateID.uuidString
        case .messageStream(let stream, _):
            return stream.conversationID
        case .conversationChanged,
             .conversationActivityHint,
             .conversationRemovedForSelf,
             .conversationVisibilityChanged,
             .memberChanged:
            return event.aggregateID.uuidString
        case .messageFavoriteChanged,
             .contactChanged:
            return event.conversation?.id.uuidString
        }
    }
}

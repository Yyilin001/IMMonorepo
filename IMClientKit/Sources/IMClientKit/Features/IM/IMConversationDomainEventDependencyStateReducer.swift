import Foundation

struct IMConversationDomainEventDependencyStateReducer: Sendable {
    func snapshot(
        conversations: [IMConversation],
        processedEventIDs: Set<UUID>,
        ownerAggregateHighWatermarks: [IMOwnerAggregateKey: UInt64]
    ) -> DomainEventProjectionReducer.DependencySnapshot {
        var existingMessageKeys = Set<DomainEventProjectionReducer.MessageKey>()
        for conversation in conversations {
            for message in conversation.messages {
                existingMessageKeys.formUnion(messageKeys(for: message))
            }
        }
        return DomainEventProjectionReducer.DependencySnapshot(
            processedEventIDs: processedEventIDs,
            ownerAggregateHighWatermarks: ownerAggregateHighWatermarks,
            existingMessageKeys: existingMessageKeys
        )
    }

    func reduce(
        payload: IMTCPChatDomainEventPayload,
        operation: DomainEventProjectionReducer.Operation,
        state: inout DomainEventProjectionReducer.DependencySnapshot
    ) {
        state.processedEventIDs.insert(payload.eventID)
        recordOwnerAggregateHighWatermark(payload, state: &state)

        switch operation {
        case .applyMessageCreated(let message, _, _, _):
            state.existingMessageKeys.formUnion(messageKeys(for: message))
        case .applyMessageMutation(_, let message, _, _):
            if let message {
                state.existingMessageKeys.formUnion(messageKeys(for: message))
            }
        case .applyVisibility(let conversationID, let messageIDs, let message, let action, _, _):
            if let message {
                state.existingMessageKeys.formUnion(messageKeys(for: message))
            }
            if action == .messageHidden {
                removeMessageKeys(
                    conversationID: conversationID,
                    messageIDs: Set(messageIDs.map(\.uuidString)),
                    state: &state
                )
            }
        case .applyMessageStream(_, let message, _, _):
            if let message {
                state.existingMessageKeys.formUnion(messageKeys(for: message))
            }
        case .removeConversation(let conversationID, _):
            removeMessageKeys(conversationID: conversationID, state: &state)
        case .applyConversationVisibility(let conversationID, let action, let messageIDs, _, _):
            switch action {
            case .conversationCleared, .conversationDeleted:
                removeMessageKeys(conversationID: conversationID, state: &state)
            case .messageHidden:
                removeMessageKeys(
                    conversationID: conversationID,
                    messageIDs: Set(messageIDs.map(\.uuidString)),
                    state: &state
                )
            }
        case .ignoreDuplicate,
             .requestCatchUp,
             .rejectInvalid,
             .deferEvent,
             .applyMessageFavorite,
             .applyConversationChange,
             .applyMemberChange,
             .applyContactChange:
            break
        }
    }

    func messageKeys(for message: IMConversationMessage) -> Set<DomainEventProjectionReducer.MessageKey> {
        var keys: Set<DomainEventProjectionReducer.MessageKey> = [
            DomainEventProjectionReducer.MessageKey(
                conversationID: message.conversationID,
                messageID: message.id
            )
        ]
        keys.insert(
            DomainEventProjectionReducer.MessageKey(
                conversationID: message.conversationID,
                messageID: message.serverMessageID
            )
        )
        return keys
    }

    private func recordOwnerAggregateHighWatermark(
        _ payload: IMTCPChatDomainEventPayload,
        state: inout DomainEventProjectionReducer.DependencySnapshot
    ) {
        guard let ownerAggregateSequence = payload.ownerAggregateSequence,
              ownerAggregateSequence > 0
        else {
            return
        }
        let key = IMOwnerAggregateKey(
            aggregateType: payload.aggregateType,
            aggregateID: payload.aggregateID.uuidString
        )
        state.ownerAggregateHighWatermarks[key] = max(
            state.ownerAggregateHighWatermarks[key] ?? 0,
            ownerAggregateSequence
        )
    }

    private func removeMessageKeys(
        conversationID: String,
        messageIDs: Set<String>,
        state: inout DomainEventProjectionReducer.DependencySnapshot
    ) {
        guard !messageIDs.isEmpty else {
            return
        }
        state.existingMessageKeys = state.existingMessageKeys.filter { key in
            key.conversationID != conversationID || !messageIDs.contains(key.messageID)
        }
    }

    private func removeMessageKeys(
        conversationID: String,
        state: inout DomainEventProjectionReducer.DependencySnapshot
    ) {
        state.existingMessageKeys = state.existingMessageKeys.filter { $0.conversationID != conversationID }
    }
}

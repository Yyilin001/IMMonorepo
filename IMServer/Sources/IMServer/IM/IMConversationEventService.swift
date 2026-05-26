import Foundation
import Vapor

struct IMConversationEventService {
    let app: Application
    let strongReadService: ConversationStrongReadService

    init(app: Application, strongReadService: ConversationStrongReadService? = nil) {
        self.app = app
        self.strongReadService = strongReadService ?? IMConversationService.strongRead(app: app)
    }

    func publishMessageCreated(
        _ result: IMRealtimeMessagePersistenceResult,
        actorUserID: UUID?
    ) async {
        guard let messageID = result.message.messageID.flatMap(UUID.init(uuidString:)),
              let senderUserID = result.message.senderUserID,
              let serverSequence = result.message.serverSequence,
              let serverTimestamp = result.message.serverTimestamp
        else {
            return
        }

        let message = IMMessageResponse(
            id: messageID,
            conversationID: result.conversationID,
            senderUserID: senderUserID,
            clientMessageID: result.message.clientMessageID,
            serverSequence: Int(serverSequence),
            content: result.message.content,
            derivedState: result.message.derivedState,
            createdAt: serverTimestamp
        )
        let uniqueRecipientUserIDs = Array(Set(result.recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }

        for recipientUserID in uniqueRecipientUserIDs {
            do {
                let conversation = try await strongReadService.conversationSummary(
                    conversationID: result.conversationID,
                    for: recipientUserID
                )
                await app.gatewaySessionService.sendDomainEvent(
                    IMTCPChatDomainEventPayload(
                        eventID: messageID,
                        eventType: .messageCreated,
                        aggregateType: "conversation",
                        aggregateID: result.conversationID,
                        aggregateSequence: UInt64(message.serverSequence),
                        occurredAt: serverTimestamp,
                        actorUserID: actorUserID,
                        conversation: conversation,
                        body: .messageCreated(message: message, clientMessageID: message.clientMessageID)
                    ),
                    toUserIDs: [recipientUserID]
                )
            } catch {
                app.logger.warning(
                    "Failed to publish IM message_created domain event",
                    metadata: [
                        "conversationID": .string(result.conversationID.uuidString),
                        "recipientUserID": .string(recipientUserID.uuidString),
                        "error": .string(String(describing: error))
                    ]
                )
            }
        }
    }

    func publish(
        eventType: IMTCPConversationEventType,
        conversationID: UUID,
        recipientUserIDs: [UUID],
        message: IMMessageResponse? = nil,
        stream: IMTCPMessageStreamPayload? = nil,
        actorUserID: UUID? = nil,
        messageIDs: [UUID] = [],
        favoriteChangedMessageID: UUID? = nil,
        isFavorited: Bool? = nil,
        visibilityAction: ConversationVisibilityAction? = nil
    ) async {
        let uniqueRecipientUserIDs = Array(Set(recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueRecipientUserIDs.isEmpty else {
            return
        }

        let timestamp = Date()

        for recipientUserID in uniqueRecipientUserIDs {
            do {
                let conversation = try await strongReadService.conversationSummary(
                    conversationID: conversationID,
                    for: recipientUserID
                )
                await app.gatewaySessionService.sendDomainEvent(
                    IMTCPChatDomainEventPayload(
                        eventID: domainEventID(
                            eventType: eventType,
                            message: message,
                            favoriteChangedMessageID: favoriteChangedMessageID
                        ),
                        eventType: eventType.chatDomainEventType,
                        aggregateType: "conversation",
                        aggregateID: conversationID,
                        aggregateSequence: UInt64(max(conversation.lastMessage?.serverSequence ?? conversation.lastReadSequence, 0)),
                        occurredAt: timestamp,
                        actorUserID: actorUserID,
                        conversation: conversation,
                        body: domainEventBody(
                            eventType: eventType,
                            message: message,
                            stream: stream,
                            messageIDs: messageIDs,
                            favoriteChangedMessageID: favoriteChangedMessageID,
                            isFavorited: isFavorited,
                            visibilityAction: visibilityAction
                        )
                    ),
                    toUserIDs: [recipientUserID]
                )
            } catch let error as any AbortError where error.status == .notFound {
                continue
            } catch {
                app.logger.warning(
                    "Failed to publish IM conversation event",
                    metadata: [
                        "eventType": .string(eventType.rawValue),
                        "conversationID": .string(conversationID.uuidString),
                        "recipientUserID": .string(recipientUserID.uuidString),
                        "error": .string(String(describing: error))
                    ]
                )
            }
        }
    }

    func publishRemovedForSelf(
        conversation: IMConversationResponse,
        recipientUserID: UUID,
        actorUserID: UUID? = nil
    ) async {
        await app.gatewaySessionService.sendDomainEvent(
            IMTCPChatDomainEventPayload(
                eventID: UUID(),
                eventType: .conversationRemovedForSelf,
                aggregateType: "conversation",
                aggregateID: conversation.id,
                aggregateSequence: UInt64(max(conversation.lastMessage?.serverSequence ?? conversation.lastReadSequence, 0)),
                occurredAt: Date(),
                actorUserID: actorUserID,
                conversation: conversation,
                body: .conversationRemovedForSelf
            ),
            toUserIDs: [recipientUserID]
        )
    }

    private func domainEventID(
        eventType: IMTCPConversationEventType,
        message: IMMessageResponse?,
        favoriteChangedMessageID: UUID?
    ) -> UUID {
        switch eventType {
        case .messageUpdated, .messageRecalled:
            return message?.id ?? UUID()
        case .messageFavoriteChanged:
            return favoriteChangedMessageID ?? UUID()
        default:
            return UUID()
        }
    }

    private func domainEventBody(
        eventType: IMTCPConversationEventType,
        message: IMMessageResponse?,
        stream: IMTCPMessageStreamPayload?,
        messageIDs: [UUID],
        favoriteChangedMessageID: UUID?,
        isFavorited: Bool?,
        visibilityAction: ConversationVisibilityAction?
    ) -> IMTCPChatDomainEventBody {
        switch eventType {
        case .messageUpdated:
            let body = IMRichTextContent.plain(message?.content.previewText ?? "")
            return .messageEdited(
                messageID: message?.id ?? UUID(),
                body: body,
                editedAt: message?.derivedState.edits.last?.editedAt ?? Date(),
                message: message
            )
        case .messageRecalled:
            return .messageRevoked(
                messageID: message?.id ?? UUID(),
                revokedAt: Date(),
                revokedByUserID: nil,
                message: message
            )
        case .messageVisibilityChanged:
            return .messageVisibilityChanged(
                messageIDs: messageIDs,
                message: message,
                visibilityAction: visibilityAction
            )
        case .messageFavoriteChanged:
            return .messageFavoriteChanged(
                messageID: favoriteChangedMessageID ?? message?.id ?? UUID(),
                isFavorited: isFavorited ?? false
            )
        case .messageStreamStarted,
             .messageStreamChunk,
             .messageStreamCompleted,
             .messageStreamFailed,
             .messageStreamCancelled:
            return .messageStream(
                stream ?? IMTCPMessageStreamPayload(
                    streamID: "",
                    messageID: message?.id.uuidString ?? "",
                    conversationID: message?.conversationID.uuidString ?? "",
                    chunkIndex: 0,
                    deltaText: nil,
                    partialTextLength: 0,
                    state: .failed,
                    serverTimestamp: Date()
                ),
                message: message
            )
        case .conversationRemovedForSelf:
            return .conversationRemovedForSelf
        case .conversationVisibilityChanged:
            return .conversationVisibilityChanged(
                visibilityAction: visibilityAction ?? .conversationDeleted,
                messageIDs: messageIDs
            )
        case .membersAdded:
            return .memberChanged(memberUserIDs: [])
        case .memberLeft:
            return .memberChanged(memberUserIDs: [])
        case .membersUpdated:
            return .memberChanged(memberUserIDs: [])
        case .conversationCreated,
             .summaryUpdated,
             .conversationSettingsChanged,
             .inviteChanged:
            return .conversationChanged
        }
    }
}

private extension IMTCPConversationEventType {
    var chatDomainEventType: IMTCPChatDomainEventType {
        switch self {
        case .conversationCreated:
            return .conversationCreated
        case .membersAdded:
            return .memberAdded
        case .memberLeft:
            return .memberRemoved
        case .membersUpdated:
            return .memberRoleUpdated
        case .conversationRemovedForSelf:
            return .conversationRemovedForSelf
        case .summaryUpdated:
            return .conversationUpdated
        case .messageUpdated:
            return .messageEdited
        case .messageRecalled:
            return .messageRevoked
        case .messageVisibilityChanged:
            return .messageVisibilityChanged
        case .messageFavoriteChanged:
            return .messageFavoriteChanged
        case .conversationVisibilityChanged:
            return .conversationVisibilityChanged
        case .conversationSettingsChanged, .inviteChanged:
            return .conversationSettingsChanged
        case .messageStreamStarted:
            return .messageStreamStarted
        case .messageStreamChunk:
            return .messageStreamChunk
        case .messageStreamCompleted:
            return .messageStreamCompleted
        case .messageStreamFailed:
            return .messageStreamFailed
        case .messageStreamCancelled:
            return .messageStreamCancelled
        }
    }
}

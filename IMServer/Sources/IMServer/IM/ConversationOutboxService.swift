import Fluent
import Foundation
import Vapor

struct ConversationOutboxService {
    let db: any Database

    func enqueue(
        type: ConversationDomainEventType,
        conversationID: UUID,
        payload: ConversationDomainEventPayload,
        on database: (any Database)? = nil
    ) async throws {
        let database = database ?? db
        let event = try ConversationDomainEvent(
            conversationID: conversationID,
            eventType: type,
            payload: payload
        )
        try await event.create(on: database)
    }

    @discardableResult
    func processPendingBatch(
        app: Application,
        configuration: ConversationOutboxConfiguration? = nil
    ) async throws -> Int {
        try await ConversationOutboxProcessor(db: db).processPendingBatch(
            app: app,
            configuration: configuration
        )
    }

    @discardableResult
    func requeueFailedEvents(
        maxRetryCount: Int? = nil,
        eventTypes: Set<ConversationDomainEventType> = []
    ) async throws -> Int {
        try await ConversationOutboxRetryService(db: db).requeueFailedEvents(
            maxRetryCount: maxRetryCount,
            eventTypes: eventTypes
        )
    }
}

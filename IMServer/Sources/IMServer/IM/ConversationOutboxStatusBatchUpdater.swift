import Fluent
import Foundation
import SQLKit

struct ConversationOutboxStatusBatchUpdater {
    let db: any Database

    func markProcessing(_ events: [ConversationDomainEvent], startedAt: Date) async throws {
        guard !events.isEmpty else { return }
        for event in events {
            event.statusEnum = .processing
            event.processingStartedAt = startedAt
            event.errorMessage = nil
        }
        guard let sql = db as? any SQLDatabase else {
            for event in events {
                try await event.update(on: db)
            }
            return
        }

        let idList = try idList(for: events)
        try await sql.raw("""
            UPDATE \(ident: ConversationDomainEvent.schema)
            SET
                \(ident: "status") = \(bind: ConversationDomainEventStatus.processing.rawValue),
                \(ident: "processing_started_at") = \(bind: startedAt),
                \(ident: "error_message") = NULL
            WHERE \(ident: "id") IN (\(idList))
            """).run()
    }

    func markProcessed(_ events: [ConversationDomainEvent], processedAt: Date) async throws {
        guard !events.isEmpty else { return }
        for event in events {
            event.statusEnum = .processed
            event.processedAt = processedAt
            event.errorMessage = nil
        }
        guard let sql = db as? any SQLDatabase else {
            for event in events {
                try await event.update(on: db)
            }
            return
        }

        let idList = try idList(for: events)
        try await sql.raw("""
            UPDATE \(ident: ConversationDomainEvent.schema)
            SET
                \(ident: "status") = \(bind: ConversationDomainEventStatus.processed.rawValue),
                \(ident: "processed_at") = \(bind: processedAt),
                \(ident: "error_message") = NULL
            WHERE \(ident: "id") IN (\(idList))
            """).run()
    }

    func markFailed(_ events: [ConversationDomainEvent], errorMessage: String) async throws {
        guard !events.isEmpty else { return }
        for event in events {
            event.statusEnum = .failed
            event.retryCount += 1
            event.errorMessage = errorMessage
        }
        guard let sql = db as? any SQLDatabase else {
            for event in events {
                try await event.update(on: db)
            }
            return
        }

        let idList = try idList(for: events)
        try await sql.raw("""
            UPDATE \(ident: ConversationDomainEvent.schema)
            SET
                \(ident: "status") = \(bind: ConversationDomainEventStatus.failed.rawValue),
                \(ident: "retry_count") = \(ident: "retry_count") + 1,
                \(ident: "error_message") = \(bind: errorMessage)
            WHERE \(ident: "id") IN (\(idList))
            """).run()
    }

    private func idList(for events: [ConversationDomainEvent]) throws -> SQLQueryString {
        try events.map { event -> SQLQueryString in
            "\(bind: try event.requireID())"
        }.joined(separator: ", ")
    }
}

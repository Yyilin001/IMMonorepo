import Fluent
import Foundation
import Vapor

protocol ConversationSearchIndexWriter: Sendable {
    func reindexMessage(messageID: UUID, on database: any Database) async throws
}

struct DatabaseConversationSearchIndexWriter: ConversationSearchIndexWriter {
    func reindexMessage(messageID: UUID, on database: any Database) async throws {
        try await ConversationSearchIndexWorker(db: database).reindexMessage(messageID: messageID, on: database)
    }
}

struct OpenSearchConversationSearchIndexWriter: ConversationSearchIndexWriter {
    private struct Document: Content {
        let messageID: UUID
        let conversationID: UUID
        let serverSequence: Int
        let searchableText: String
        let messageType: String
        let createdAt: Date
    }

    let app: Application
    let endpoint: String
    let indexName: String

    func reindexMessage(messageID: UUID, on database: any Database) async throws {
        let documentID = ConversationMessageSearchIndex.recordID(messageID: messageID)
        guard let message = try await ConversationMessage.find(messageID, on: database) else {
            try await deleteDocument(documentID: documentID)
            return
        }

        let aggregate = try message.decodedAggregate()
        let searchableText = MessagePresentation(aggregate: aggregate)
            .searchableTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let document = Document(
            messageID: messageID,
            conversationID: message.$conversation.id,
            serverSequence: message.serverSequence,
            searchableText: searchableText,
            messageType: message.kind,
            createdAt: message.createdAt ?? Date()
        )

        let baseEndpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let uri = URI(string: "\(baseEndpoint)/\(indexName)/_doc/\(documentID)")
        let response = try await app.client.put(uri) { request in
            try request.content.encode(document)
        }

        guard response.status == .ok || response.status == .created else {
            throw Abort(.badGateway, reason: "OpenSearch index update failed.")
        }
    }

    private func deleteDocument(documentID: String) async throws {
        let baseEndpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let uri = URI(string: "\(baseEndpoint)/\(indexName)/_doc/\(documentID)")
        let response = try await app.client.delete(uri)
        guard response.status == .ok || response.status == .notFound else {
            throw Abort(.badGateway, reason: "OpenSearch index delete failed.")
        }
    }
}

private struct ConversationSearchIndexWriterStorageKey: StorageKey {
    typealias Value = any ConversationSearchIndexWriter
}

extension Application {
    var conversationSearchIndexWriter: any ConversationSearchIndexWriter {
        get {
            if let writer = storage[ConversationSearchIndexWriterStorageKey.self] {
                return writer
            }

            let writer: any ConversationSearchIndexWriter
            if environment == .production || searchIndexConfiguration.driver == .openSearch {
                writer = OpenSearchConversationSearchIndexWriter(
                    app: self,
                    endpoint: searchIndexConfiguration.endpoint ?? "",
                    indexName: searchIndexConfiguration.indexName
                )
            } else {
                writer = DatabaseConversationSearchIndexWriter()
            }

            storage[ConversationSearchIndexWriterStorageKey.self] = writer
            return writer
        }
        set { storage[ConversationSearchIndexWriterStorageKey.self] = newValue }
    }
}

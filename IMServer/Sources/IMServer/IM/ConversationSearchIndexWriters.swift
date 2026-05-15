import Fluent
import Foundation
import Vapor

protocol ConversationSearchIndexWriter: Sendable {
    func reindexMessage(messageID: UUID, on database: any Database) async throws
    func reindexMessages(messageIDs: [UUID], on database: any Database) async throws
}

extension ConversationSearchIndexWriter {
    func reindexMessages(messageIDs: [UUID], on database: any Database) async throws {
        for messageID in messageIDs {
            try await reindexMessage(messageID: messageID, on: database)
        }
    }
}

struct DatabaseConversationSearchIndexWriter: ConversationSearchIndexWriter {
    func reindexMessage(messageID: UUID, on database: any Database) async throws {
        try await ConversationSearchIndexWorker(db: database).reindexMessage(messageID: messageID, on: database)
    }

    func reindexMessages(messageIDs: [UUID], on database: any Database) async throws {
        try await ConversationSearchIndexWorker(db: database).reindexMessages(messageIDs: messageIDs, on: database)
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

    func reindexMessages(messageIDs: [UUID], on database: any Database) async throws {
        let uniqueMessageIDs = Array(Set(messageIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueMessageIDs.isEmpty else {
            return
        }

        let messages = try await ConversationMessage.query(on: database)
            .filter(\.$id ~~ uniqueMessageIDs)
            .all()
        let documents = try messages.map { message -> (String, Document) in
            let messageID = try message.requireID()
            let aggregate = try message.decodedAggregate()
            let searchableText = MessagePresentation(aggregate: aggregate)
                .searchableTexts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return (
                ConversationMessageSearchIndex.recordID(messageID: messageID),
                Document(
                    messageID: messageID,
                    conversationID: message.$conversation.id,
                    serverSequence: message.serverSequence,
                    searchableText: searchableText,
                    messageType: message.kind,
                    createdAt: message.createdAt ?? Date()
                )
            )
        }
        guard !documents.isEmpty else {
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bodyLines = try documents.flatMap { documentID, document -> [String] in
            let action = #"{"index":{"_id":"\#(documentID)"}}"#
            let data = try encoder.encode(document)
            guard let source = String(data: data, encoding: .utf8) else {
                throw ConversationProjectionCodingError.invalidJSON
            }
            return [action, source]
        }.joined(separator: "\n") + "\n"

        let baseEndpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let uri = URI(string: "\(baseEndpoint)/\(indexName)/_bulk")
        let response = try await app.client.post(uri) { request in
            request.headers.contentType = HTTPMediaType(type: "application", subType: "x-ndjson")
            request.body = .init(string: bodyLines)
        }

        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "OpenSearch bulk index update failed.")
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
            if searchIndexConfiguration.driver == .openSearch {
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

import Fluent
import Foundation
import Vapor

enum ConversationShardMigrationSearchIndexRebuilder {
    static func rebuild(
        app: Application,
        conversationID: UUID,
        database: any Database,
        pageSize: Int
    ) async throws {
        try await ConversationMessageSearchIndex.query(on: database)
            .filter(\.$conversationID == conversationID)
            .delete()

        var offset = 0
        while true {
            let messageIDs = try await ConversationMessage.query(on: database)
                .filter(\.$conversation.$id == conversationID)
                .sort(\.$timelineSequence, .ascending)
                .sort(\.$id, .ascending)
                .range(offset..<(offset + pageSize))
                .all()
                .compactMap(\.id)
            guard !messageIDs.isEmpty else { return }
            try await app.conversationSearchIndexWriter.reindexMessages(messageIDs: messageIDs, on: database)
            offset += messageIDs.count
        }
    }
}

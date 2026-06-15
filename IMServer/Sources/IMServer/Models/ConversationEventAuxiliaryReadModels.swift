import Crypto
import Fluent
import Foundation
import SQLKit

final class ConversationDomainEventRecipientSet: Model, @unchecked Sendable {
    static let schema = "conversation_domain_event_recipient_sets"

    @ID(custom: "recipient_hash", generatedBy: .user)
    var id: String?

    @Field(key: "recipient_user_ids_json")
    private var recipientUserIDsJSON: String

    @Field(key: "recipient_count")
    var recipientCount: Int

    @Field(key: "created_at")
    var createdAt: Date

    init() {}

    init(
        recipientHash: String,
        recipientUserIDs: [UUID],
        createdAt: Date = Date()
    ) throws {
        let uniqueRecipients = Self.uniqueSorted(recipientUserIDs)
        self.id = recipientHash
        self.recipientUserIDsJSON = try Self.encode(uniqueRecipients)
        self.recipientCount = uniqueRecipients.count
        self.createdAt = createdAt
    }

    func recipientUserIDs() throws -> [UUID] {
        try Self.decode(recipientUserIDsJSON)
    }

    static func recipientHash(for ids: [UUID]) -> String {
        let normalized = uniqueSorted(ids)
            .map { $0.uuidString.lowercased() }
            .joined(separator: ",")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func encode(_ ids: [UUID]) throws -> String {
        let data = try JSONEncoder().encode(ids)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ConversationProjectionCodingError.invalidJSON
        }
        return json
    }

    fileprivate static func decode(_ json: String) throws -> [UUID] {
        guard let data = json.data(using: .utf8) else {
            throw ConversationProjectionCodingError.invalidJSON
        }
        return try JSONDecoder().decode([UUID].self, from: data)
    }

    fileprivate static func uniqueSorted(_ ids: [UUID]) -> [UUID] {
        Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
    }
}

final class ConversationDomainEventRecipientSetMember: Model, @unchecked Sendable {
    static let schema = "conversation_domain_event_recipient_set_members"

    @ID(custom: "id", generatedBy: .user)
    var id: String?

    @Field(key: "recipient_hash")
    var recipientHash: String

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "created_at")
    var createdAt: Date

    init() {}

    init(
        recipientHash: String,
        userID: UUID,
        createdAt: Date = Date()
    ) {
        self.id = Self.recordID(recipientHash: recipientHash, userID: userID)
        self.recipientHash = recipientHash
        self.userID = userID
        self.createdAt = createdAt
    }

    static func recordID(recipientHash: String, userID: UUID) -> String {
        "\(recipientHash):\(userID.uuidString.lowercased())"
    }

    static func matchingUserIDs(
        recipientHash: String,
        candidateUserIDs: [UUID],
        on database: any Database
    ) async throws -> [UUID] {
        let candidates = ConversationDomainEventRecipientSet.uniqueSorted(candidateUserIDs)
        guard !candidates.isEmpty else {
            return []
        }
        let rows = try await ConversationDomainEventRecipientSetMember.query(on: database)
            .filter(\.$recipientHash == recipientHash)
            .filter(\.$userID ~~ candidates)
            .all()
        return ConversationDomainEventRecipientSet.uniqueSorted(rows.map(\.userID))
    }

    static func hasMemberIndex(
        recipientHash: String,
        on database: any Database
    ) async throws -> Bool {
        try await ConversationDomainEventRecipientSetMember.query(on: database)
            .filter(\.$recipientHash == recipientHash)
            .first() != nil
    }

    @discardableResult
    static func writeMemberIndex(
        recipientHash: String,
        recipientUserIDs: [UUID],
        createdAt: Date,
        on database: any Database
    ) async throws -> Int {
        let uniqueRecipients = ConversationDomainEventRecipientSet.uniqueSorted(recipientUserIDs)
        guard !uniqueRecipients.isEmpty else {
            return 0
        }
        if let sql = database as? any SQLDatabase,
           sql.dialect.name == "postgresql"
        {
            var insertedCount = 0
            for chunk in uniqueRecipients.chunked(into: 1_000) {
                let values = chunk.map { userID -> SQLQueryString in
                    """
                    (
                        \(bind: recordID(recipientHash: recipientHash, userID: userID)),
                        \(bind: recipientHash),
                        \(bind: userID),
                        \(bind: createdAt)
                    )
                    """ as SQLQueryString
                }.joined(separator: ", ")
                let rows = try await sql.raw("""
                    INSERT INTO \(ident: schema) (
                        \(ident: "id"),
                        \(ident: "recipient_hash"),
                        \(ident: "user_id"),
                        \(ident: "created_at")
                    )
                    VALUES \(values)
                    ON CONFLICT (\(ident: "id")) DO NOTHING
                    RETURNING \(ident: "id")
                    """).all(decoding: InsertedRecipientSetMemberRow.self)
                insertedCount += rows.count
            }
            return insertedCount
        }

        var insertedCount = 0
        for userID in uniqueRecipients {
            let id = recordID(recipientHash: recipientHash, userID: userID)
            if try await ConversationDomainEventRecipientSetMember.find(id, on: database) == nil {
                try await ConversationDomainEventRecipientSetMember(
                    recipientHash: recipientHash,
                    userID: userID,
                    createdAt: createdAt
                ).create(on: database)
                insertedCount += 1
            }
        }
        return insertedCount
    }
}

private struct InsertedRecipientSetMemberRow: Decodable {
    let id: String
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else {
            return [self]
        }
        var chunks: [[Element]] = []
        chunks.reserveCapacity((count + size - 1) / size)
        var index = startIndex
        while index < endIndex {
            let next = Swift.min(index + size, endIndex)
            chunks.append(Array(self[index..<next]))
            index = next
        }
        return chunks
    }
}

final class ConversationDomainEventRecipientSnapshot: Model, @unchecked Sendable {
    static let schema = "conversation_domain_event_recipient_snapshots"

    @ID(custom: "event_id", generatedBy: .user)
    var id: UUID?

    @Field(key: "conversation_id")
    var conversationID: UUID

    @Field(key: "recipient_user_ids_json")
    private var recipientUserIDsJSON: String

    @Field(key: "recipient_count")
    var recipientCount: Int

    @OptionalField(key: "recipient_hash")
    var recipientHash: String?

    @Field(key: "created_at")
    var createdAt: Date

    init() {}

    init(
        eventID: UUID,
        conversationID: UUID,
        recipientUserIDs: [UUID],
        createdAt: Date = Date(),
        storesRecipientIDsInline: Bool = true
    ) throws {
        let uniqueRecipients = Self.uniqueSorted(recipientUserIDs)
        self.id = eventID
        self.conversationID = conversationID
        self.recipientUserIDsJSON = try storesRecipientIDsInline ? Self.encode(uniqueRecipients) : Self.encode([])
        self.recipientCount = uniqueRecipients.count
        self.recipientHash = Self.recipientHash(for: uniqueRecipients)
        self.createdAt = createdAt
    }

    func recipientUserIDs() throws -> [UUID] {
        try Self.decode(recipientUserIDsJSON)
    }

    func recipientUserIDs(on database: any Database) async throws -> [UUID] {
        let inlineRecipients = try recipientUserIDs()
        if !inlineRecipients.isEmpty || recipientCount == 0 {
            return inlineRecipients
        }
        guard let recipientHash,
              let recipientSet = try await ConversationDomainEventRecipientSet.find(recipientHash, on: database)
        else {
            throw ConversationProjectionCodingError.missingRecipientSet
        }
        return try recipientSet.recipientUserIDs()
    }

    static func recipientHash(for ids: [UUID]) -> String {
        ConversationDomainEventRecipientSet.recipientHash(for: ids)
    }

    private static func encode(_ ids: [UUID]) throws -> String {
        try ConversationDomainEventRecipientSet.encode(ids)
    }

    private static func decode(_ json: String) throws -> [UUID] {
        try ConversationDomainEventRecipientSet.decode(json)
    }

    private static func uniqueSorted(_ ids: [UUID]) -> [UUID] {
        ConversationDomainEventRecipientSet.uniqueSorted(ids)
    }
}

final class ConversationNotificationEntry: Model, @unchecked Sendable {
    static let schema = "conversation_notification_events"

    @ID(custom: .id, generatedBy: .user)
    var id: String?

    @Field(key: "owner_user_id")
    var ownerUserID: UUID

    @Field(key: "event_id")
    var eventID: UUID

    @Field(key: "conversation_id")
    var conversationID: UUID

    @Field(key: "event_type")
    var eventType: String

    @Field(key: "payload_json")
    private var payloadJSON: String

    @Field(key: "created_at")
    var createdAt: Date

    @Field(key: "updated_at")
    var updatedAt: Date

    init() {}

    init(
        ownerUserID: UUID,
        eventID: UUID,
        conversationID: UUID,
        eventType: String,
        payload: ConversationDomainEventPayload,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        self.id = Self.recordID(ownerUserID: ownerUserID, eventID: eventID)
        self.ownerUserID = ownerUserID
        self.eventID = eventID
        self.conversationID = conversationID
        self.eventType = eventType
        self.payloadJSON = try Self.encode(payload)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func decodedPayload() throws -> ConversationDomainEventPayload {
        try Self.decode(payloadJSON)
    }

    func replacePayload(_ payload: ConversationDomainEventPayload) throws {
        payloadJSON = try Self.encode(payload)
    }

    static func recordID(ownerUserID: UUID, eventID: UUID) -> String {
        "\(ownerUserID.uuidString.lowercased()):\(eventID.uuidString.lowercased())"
    }

    private static func encode(_ payload: ConversationDomainEventPayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ConversationProjectionCodingError.invalidJSON
        }
        return json
    }

    private static func decode(_ json: String) throws -> ConversationDomainEventPayload {
        guard let data = json.data(using: .utf8) else {
            throw ConversationProjectionCodingError.invalidJSON
        }
        return try JSONDecoder().decode(ConversationDomainEventPayload.self, from: data)
    }
}

enum ConversationReplayStatus: String, Codable, Sendable {
    case pending
    case replayed
    case failed
}

final class ConversationReplayRecord: Model, @unchecked Sendable {
    static let schema = "conversation_event_replay_records"

    @ID(custom: .id, generatedBy: .user)
    var id: String?

    @Field(key: "event_id")
    var eventID: UUID

    @Field(key: "consumer_group_id")
    var consumerGroupID: String

    @Field(key: "source_topic")
    var sourceTopic: String

    @Field(key: "conversation_id")
    var conversationID: UUID

    @Field(key: "event_type")
    var eventType: String

    @Field(key: "aggregate_sequence")
    var aggregateSequence: Int

    @Field(key: "producer_shard")
    var producerShard: String

    @Field(key: "payload_json")
    private var payloadJSON: String

    @Field(key: "status")
    var status: String

    @OptionalField(key: "last_error")
    var lastError: String?

    @Field(key: "receive_count")
    var receiveCount: Int

    @OptionalField(key: "replayed_at")
    var replayedAt: Date?

    @Field(key: "created_at")
    var createdAt: Date

    @Field(key: "updated_at")
    var updatedAt: Date

    init() {}

    init(
        eventID: UUID,
        consumerGroupID: String,
        sourceTopic: String,
        conversationID: UUID,
        eventType: String,
        aggregateSequence: Int,
        producerShard: String,
        payload: ConversationDomainEventPayload,
        status: ConversationReplayStatus = .pending,
        lastError: String?,
        receiveCount: Int = 1,
        replayedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        self.id = Self.recordID(consumerGroupID: consumerGroupID, eventID: eventID)
        self.eventID = eventID
        self.consumerGroupID = consumerGroupID
        self.sourceTopic = sourceTopic
        self.conversationID = conversationID
        self.eventType = eventType
        self.aggregateSequence = aggregateSequence
        self.producerShard = producerShard
        self.payloadJSON = try Self.encode(payload)
        self.status = status.rawValue
        self.lastError = lastError
        self.receiveCount = receiveCount
        self.replayedAt = replayedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var statusEnum: ConversationReplayStatus {
        get { ConversationReplayStatus(rawValue: status) ?? .pending }
        set { status = newValue.rawValue }
    }

    func decodedPayload() throws -> ConversationDomainEventPayload {
        try Self.decode(payloadJSON)
    }

    func replacePayload(_ payload: ConversationDomainEventPayload) throws {
        payloadJSON = try Self.encode(payload)
    }

    static func recordID(consumerGroupID: String, eventID: UUID) -> String {
        "\(consumerGroupID.lowercased()):\(eventID.uuidString.lowercased())"
    }

    private static func encode(_ payload: ConversationDomainEventPayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ConversationProjectionCodingError.invalidJSON
        }
        return json
    }

    private static func decode(_ json: String) throws -> ConversationDomainEventPayload {
        guard let data = json.data(using: .utf8) else {
            throw ConversationProjectionCodingError.invalidJSON
        }
        return try JSONDecoder().decode(ConversationDomainEventPayload.self, from: data)
    }
}

import Fluent
import Foundation

enum ConversationDomainEventType: String, Codable, CaseIterable, Sendable {
    case messageCreated = "message_created"
    case messageUpdated = "message_updated"
    case messageRecalled = "message_recalled"
    case readAdvanced = "read_advanced"
    case metadataUpdated = "metadata_updated"
    case membershipAdded = "membership_added"
    case membershipRemoved = "membership_removed"
    case membershipRoleUpdated = "membership_role_updated"
    case conversationRemovedForUser = "conversation_removed_for_user"
    case directPeerUpdated = "direct_peer_updated"
}

enum ConversationDomainEventStatus: String, Codable, Sendable {
    case pending
    case processing
    case processed
    case failed
}

struct ConversationDomainEventPayload: Codable, Equatable, Sendable {
    var recipientUserIDs: [UUID]
    var affectedUserID: UUID?
    var messageID: UUID?

    init(
        recipientUserIDs: [UUID] = [],
        affectedUserID: UUID? = nil,
        messageID: UUID? = nil
    ) {
        self.recipientUserIDs = recipientUserIDs
        self.affectedUserID = affectedUserID
        self.messageID = messageID
    }
}

struct ConversationEventStreamEnvelope: Codable, Equatable, Sendable {
    let eventID: UUID
    let eventVersion: Int
    let aggregateType: String
    let conversationID: UUID
    let eventType: String
    let payload: ConversationDomainEventPayload
    let occurredAt: Date
    let producerShard: String

    init(
        eventID: UUID,
        eventVersion: Int = 1,
        aggregateType: String = "conversation",
        conversationID: UUID,
        eventType: String,
        payload: ConversationDomainEventPayload,
        occurredAt: Date,
        producerShard: String
    ) {
        self.eventID = eventID
        self.eventVersion = eventVersion
        self.aggregateType = aggregateType
        self.conversationID = conversationID
        self.eventType = eventType
        self.payload = payload
        self.occurredAt = occurredAt
        self.producerShard = producerShard
    }
}

final class ConversationDomainEvent: Model, @unchecked Sendable {
    static let schema = "conversation_domain_events"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "conversation_id")
    var conversationID: UUID

    @Field(key: "event_type")
    var eventType: String

    @Field(key: "payload_json")
    private var payloadJSON: String

    @Field(key: "status")
    var status: String

    @OptionalField(key: "error_message")
    var errorMessage: String?

    @Field(key: "created_at")
    var createdAt: Date

    @OptionalField(key: "processing_started_at")
    var processingStartedAt: Date?

    @OptionalField(key: "processed_at")
    var processedAt: Date?

    @OptionalField(key: "stream_published_at")
    var streamPublishedAt: Date?

    @OptionalField(key: "stream_publish_error")
    var streamPublishError: String?

    @OptionalField(key: "stream_publish_started_at")
    var streamPublishStartedAt: Date?

    @OptionalField(key: "stream_publish_claimed_by")
    var streamPublishClaimedBy: String?

    @Field(key: "retry_count")
    var retryCount: Int

    init() { }

    init(
        id: UUID? = nil,
        conversationID: UUID,
        eventType: ConversationDomainEventType,
        payload: ConversationDomainEventPayload,
        status: ConversationDomainEventStatus = .pending,
        createdAt: Date = Date()
    ) throws {
        self.id = id
        self.conversationID = conversationID
        self.eventType = eventType.rawValue
        self.payloadJSON = try Self.encodePayload(payload)
        self.status = status.rawValue
        self.createdAt = createdAt
        self.retryCount = 0
    }

    var eventTypeEnum: ConversationDomainEventType {
        get { ConversationDomainEventType(rawValue: eventType) ?? .metadataUpdated }
        set { eventType = newValue.rawValue }
    }

    var statusEnum: ConversationDomainEventStatus {
        get { ConversationDomainEventStatus(rawValue: status) ?? .pending }
        set { status = newValue.rawValue }
    }

    func decodedPayload() throws -> ConversationDomainEventPayload {
        guard let data = payloadJSON.data(using: .utf8) else {
            throw ConversationProjectionCodingError.invalidJSON
        }
        return try JSONDecoder().decode(ConversationDomainEventPayload.self, from: data)
    }

    func replacePayload(_ payload: ConversationDomainEventPayload) throws {
        payloadJSON = try Self.encodePayload(payload)
    }

    private static func encodePayload(_ payload: ConversationDomainEventPayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ConversationProjectionCodingError.invalidJSON
        }
        return json
    }
}

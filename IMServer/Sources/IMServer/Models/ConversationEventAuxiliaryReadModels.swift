import Fluent
import Foundation

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

    var payload: ConversationDomainEventPayload {
        get { (try? Self.decode(payloadJSON)) ?? .init() }
        set { payloadJSON = (try? Self.encode(newValue)) ?? "{}" }
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

    var payload: ConversationDomainEventPayload {
        get { (try? Self.decode(payloadJSON)) ?? .init() }
        set { payloadJSON = (try? Self.encode(newValue)) ?? "{}" }
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

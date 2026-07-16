import Fluent
import Foundation
import Vapor

final class ConversationDomainEventSequence: Model, Content, @unchecked Sendable {
    static let schema = "conversation_domain_event_sequences"

    @ID(custom: "conversation_id", generatedBy: .user)
    var id: UUID?

    @Field(key: "last_sequence")
    var lastSequence: Int

    init() { }

    init(conversationID: UUID, lastSequence: Int = 0) {
        self.id = conversationID
        self.lastSequence = lastSequence
    }

    func migrationCopy() -> ConversationDomainEventSequence {
        let copy = ConversationDomainEventSequence()
        copy.id = id
        copy.lastSequence = lastSequence
        return copy
    }

    var migrationFingerprintFields: [String?] {
        [id?.uuidString, String(lastSequence)]
    }
}

final class OwnerContactEventSequence: Model, @unchecked Sendable {
    static let schema = "owner_contact_event_sequences"

    @ID(custom: "owner_user_id", generatedBy: .user)
    var id: UUID?

    @Field(key: "last_sequence")
    var lastSequence: Int

    init() { }

    init(ownerUserID: UUID, lastSequence: Int = 0) {
        self.id = ownerUserID
        self.lastSequence = lastSequence
    }
}

final class OwnerDomainEventDeliveryCursor: Model, @unchecked Sendable {
    static let schema = "owner_domain_event_delivery_cursors"

    @ID(custom: "owner_user_id", generatedBy: .user)
    var id: UUID?

    @Field(key: "last_cursor")
    var lastCursor: Int

    init() { }

    init(ownerUserID: UUID, lastCursor: Int = 0) {
        self.id = ownerUserID
        self.lastCursor = lastCursor
    }
}

final class OwnerDomainEventAggregateSequence: Model, @unchecked Sendable {
    static let schema = "owner_domain_event_aggregate_sequences"

    @ID(custom: .id, generatedBy: .user)
    var id: String?

    @Field(key: "owner_user_id")
    var ownerUserID: UUID

    @Field(key: "aggregate_type")
    var aggregateType: String

    @Field(key: "aggregate_id")
    var aggregateID: UUID

    @Field(key: "last_sequence")
    var lastSequence: Int

    init() { }

    init(
        ownerUserID: UUID,
        aggregateType: String,
        aggregateID: UUID,
        lastSequence: Int = 0
    ) {
        self.id = Self.sequenceID(ownerUserID: ownerUserID, aggregateType: aggregateType, aggregateID: aggregateID)
        self.ownerUserID = ownerUserID
        self.aggregateType = aggregateType
        self.aggregateID = aggregateID
        self.lastSequence = lastSequence
    }

    static func sequenceID(ownerUserID: UUID, aggregateType: String, aggregateID: UUID) -> String {
        [
            ownerUserID.uuidString.lowercased(),
            aggregateType.lowercased(),
            aggregateID.uuidString.lowercased()
        ].joined(separator: ":")
    }
}

final class ConversationTimelineNotice: Model, Content, @unchecked Sendable {
    static let schema = "conversation_timeline_notices"

    @ID(custom: "event_id", generatedBy: .user)
    var id: UUID?

    @Field(key: "conversation_id")
    var conversationID: UUID

    @Field(key: "timeline_sequence")
    var timelineSequence: Int

    @Field(key: "event_type")
    var eventType: String

    @OptionalField(key: "actor_user_id")
    var actorUserID: UUID?

    @Field(key: "target_user_ids_json")
    private var targetUserIDsJSON: String

    @Field(key: "notice_kind")
    var noticeKind: String

    @Field(key: "params_json")
    private var paramsJSON: String

    @Field(key: "fallback_text")
    var fallbackText: String

    @Field(key: "created_at")
    var createdAt: Date

    init() { }

    init(
        eventID: UUID,
        conversationID: UUID,
        timelineSequence: Int,
        eventType: String,
        actorUserID: UUID?,
        targetUserIDs: [UUID],
        noticeKind: String,
        params: [String: String],
        fallbackText: String,
        createdAt: Date
    ) throws {
        self.id = eventID
        self.conversationID = conversationID
        self.timelineSequence = timelineSequence
        self.eventType = eventType
        self.actorUserID = actorUserID
        self.targetUserIDsJSON = try Self.encodeTargetUserIDs(targetUserIDs)
        self.noticeKind = noticeKind
        self.paramsJSON = try Self.encodeParams(params)
        self.fallbackText = fallbackText
        self.createdAt = createdAt
    }

    var targetUserIDs: [UUID] {
        get throws {
            try Self.decodeTargetUserIDs(targetUserIDsJSON)
        }
    }

    var eventID: UUID? {
        id
    }

    func replaceTargetUserIDs(_ targetUserIDs: [UUID]) throws {
        targetUserIDsJSON = try Self.encodeTargetUserIDs(targetUserIDs)
    }

    var params: [String: String] {
        get throws {
            try Self.decodeParams(paramsJSON)
        }
    }

    func replaceParams(_ params: [String: String]) throws {
        paramsJSON = try Self.encodeParams(params)
    }

    private static func encodeTargetUserIDs(_ targetUserIDs: [UUID]) throws -> String {
        let data = try JSONEncoder().encode(targetUserIDs)
        guard let json = String(data: data, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "Timeline notice target 编码失败。")
        }
        return json
    }

    private static func decodeTargetUserIDs(_ json: String) throws -> [UUID] {
        guard let data = json.data(using: .utf8) else {
            throw Abort(.internalServerError, reason: "Timeline notice target 编码无效。")
        }
        return try JSONDecoder().decode([UUID].self, from: data)
    }

    private static func encodeParams(_ params: [String: String]) throws -> String {
        let data = try JSONEncoder().encode(params)
        guard let json = String(data: data, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "Timeline notice params 编码失败。")
        }
        return json
    }

    private static func decodeParams(_ json: String) throws -> [String: String] {
        guard let data = json.data(using: .utf8) else {
            throw Abort(.internalServerError, reason: "Timeline notice params 编码无效。")
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    func migrationCopy() -> ConversationTimelineNotice {
        let copy = ConversationTimelineNotice()
        copy.id = id
        copy.conversationID = conversationID
        copy.timelineSequence = timelineSequence
        copy.eventType = eventType
        copy.actorUserID = actorUserID
        copy.targetUserIDsJSON = targetUserIDsJSON
        copy.noticeKind = noticeKind
        copy.paramsJSON = paramsJSON
        copy.fallbackText = fallbackText
        copy.createdAt = createdAt
        return copy
    }

    var migrationFingerprintFields: [String?] {
        [
            id?.uuidString,
            conversationID.uuidString,
            String(timelineSequence),
            eventType,
            actorUserID?.uuidString,
            targetUserIDsJSON,
            noticeKind,
            paramsJSON,
            fallbackText,
            String(createdAt.timeIntervalSince1970)
        ]
    }
}

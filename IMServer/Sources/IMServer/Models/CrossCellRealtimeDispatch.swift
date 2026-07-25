import Crypto
import Fluent
import Foundation

enum CrossCellRealtimeDispatchStatus: String, Codable, Sendable {
    case pending
    case processing
    case delivered
}

/// Durable source-Cell record for a realtime packet that must reach another
/// Cell. Delivery is deliberately at-least-once: a crash after the remote HTTP
/// request succeeds but before this row is marked delivered can resend a packet.
final class CrossCellRealtimeDispatch: Model, @unchecked Sendable {
    static let schema = "im_cross_cell_realtime_dispatches"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "origin_cell_id")
    var originCellID: String

    @Field(key: "target_cell_id")
    var targetCellID: String

    /// Stable identity for a source event handoff. Kafka may replay after this
    /// row commits but before its offset commits, so the database must reject a
    /// second record for the same target Cell and envelope.
    @Field(key: "dedupe_key")
    var dedupeKey: String

    @Field(key: "envelope_json")
    var envelopeJSON: String

    @Field(key: "status")
    var status: String

    @Field(key: "retry_count")
    var retryCount: Int

    @Field(key: "next_attempt_at")
    var nextAttemptAt: Date

    @OptionalField(key: "processing_started_at")
    var processingStartedAt: Date?

    @OptionalField(key: "delivered_at")
    var deliveredAt: Date?

    @OptionalField(key: "error_message")
    var errorMessage: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        originCellID: String,
        targetCellID: String,
        envelope: NodeMessageDispatchEnvelope,
        now: Date = Date()
    ) throws {
        id = UUID()
        self.originCellID = originCellID
        self.targetCellID = targetCellID
        envelopeJSON = try Self.canonicalEnvelopeJSON(envelope)
        dedupeKey = Self.dedupeKey(
            originCellID: originCellID,
            targetCellID: targetCellID,
            envelopeJSON: envelopeJSON
        )
        status = CrossCellRealtimeDispatchStatus.pending.rawValue
        retryCount = 0
        nextAttemptAt = now
        processingStartedAt = nil
        deliveredAt = nil
        errorMessage = nil
    }

    var statusEnum: CrossCellRealtimeDispatchStatus {
        get { CrossCellRealtimeDispatchStatus(rawValue: status) ?? .pending }
        set { status = newValue.rawValue }
    }

    func decodedEnvelope() throws -> NodeMessageDispatchEnvelope {
        try JSONDecoder().decode(NodeMessageDispatchEnvelope.self, from: Data(envelopeJSON.utf8))
    }

    static func dedupeKey(
        originCellID: String,
        targetCellID: String,
        envelopeJSON: String
    ) -> String {
        let input = "\(originCellID)\u{1F}\(targetCellID)\u{1F}\(envelopeJSON)"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalDedupeKey(
        originCellID: String,
        targetCellID: String,
        storedEnvelopeJSON: String
    ) throws -> String {
        let envelope = try JSONDecoder().decode(
            NodeMessageDispatchEnvelope.self,
            from: Data(storedEnvelopeJSON.utf8)
        )
        return dedupeKey(
            originCellID: originCellID,
            targetCellID: targetCellID,
            envelopeJSON: try canonicalEnvelopeJSON(envelope)
        )
    }

    private static func canonicalEnvelopeJSON(_ envelope: NodeMessageDispatchEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try String(decoding: encoder.encode(envelope), as: UTF8.self)
    }
}

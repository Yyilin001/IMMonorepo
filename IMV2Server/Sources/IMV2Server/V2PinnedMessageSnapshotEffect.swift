import Foundation

/// Pin order comes from the source room log. A recipient's cursor and the
/// wall-clock timestamp cannot provide this order for legacy payloads.
struct V2PinnedMessageSnapshotEffect: Equatable {
    let roomID: UUID
    let messageID: UUID
    let isPinned: Bool
    let roomSequence: Int64?
    let actorID: UUID?
    let updatedAtMilliseconds: Int64

    var entityKey: String { "pin:\(roomID.uuidString):\(messageID.uuidString)" }

    init(payload: Data) throws {
        struct Wire: Decodable {
            let event_type: String
            let room_id: UUID
            let message_id: UUID
            let is_pinned: Bool
            let room_sequence: Int64?
            let actor_user_id: UUID?
            let server_created_at_ms: Int64
        }
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: payload)
            guard wire.event_type == "message.pinned_changed",
                  wire.room_sequence.map({ $0 > 0 }) ?? true,
                  wire.server_created_at_ms >= 0
            else { throw V2UserProjectionWorkerError.invalidPayload }
            roomID = wire.room_id
            messageID = wire.message_id
            isPinned = wire.is_pinned
            roomSequence = wire.room_sequence
            actorID = wire.actor_user_id
            updatedAtMilliseconds = wire.server_created_at_ms
        } catch { throw V2UserProjectionWorkerError.invalidPayload }
    }

    func shouldReplace(_ prior: Self, sourceEventID: UUID, priorSourceEventID: UUID) throws -> Bool {
        guard roomID == prior.roomID, messageID == prior.messageID else {
            throw V2UserProjectionWorkerError.invalidPayload
        }
        if sourceEventID == priorSourceEventID {
            guard isPinned == prior.isPinned, actorID == prior.actorID,
                  updatedAtMilliseconds == prior.updatedAtMilliseconds,
                  roomSequence == nil || prior.roomSequence == nil || roomSequence == prior.roomSequence
            else { throw V2UserProjectionWorkerError.invalidPayload }
            // A later observation may supply missing source metadata. Never
            // drop a known source fence when replaying an older encoding.
            return prior.roomSequence == nil && roomSequence != nil
        }
        switch (prior.roomSequence, roomSequence) {
        case let (.some(old), .some(new)):
            guard old != new else { throw V2UserProjectionWorkerError.invalidPayload }
            return new > old
        case (.some, .none): return false
        case (.none, .some): return true
        case (.none, .none):
            // Compatibility with pre-source-version writers. This preserves
            // their observations, including unpin, but does not reconstruct
            // legacy order. Recovery/cutover must resolve that separately.
            return true
        }
    }
}

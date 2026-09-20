import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

struct V2MessageProjectionStateTests {
    @Test("accepted timestamps reject rounded Int64 overflow", arguments: [
        Double(Int64.max) / 1_000, Double(Int64.min).nextDown / 1_000,
        Double.infinity, -Double.infinity, Double.nan
    ])
    func rejectsUnrepresentableTimestamp(seconds: Double) throws {
        #expect(throws: V2MessageProjectionStateError.invalidPayload) {
            try makeState(createdAt: Date(timeIntervalSince1970: seconds))
        }
    }

    @Test("accepted timestamps preserve floor rounding", arguments: [
        (1_750_000_000.1239, Int64(1_750_000_000_123)), (-0.5001, Int64(-501)),
        (0.0, Int64(0)), (9_000_000_000_000_000.0, Int64(9_000_000_000_000_000_000))
    ])
    func preservesTimestamp(sample: (Double, Int64)) throws {
        #expect(try makeState(createdAt: Date(timeIntervalSince1970: sample.0)).acceptedAtUnixMilliseconds == sample.1)
    }

    @Test("shared message state identity is deterministic across shards")
    func deterministicIdentity() throws {
        let messageID = UUID(uuidString: "00000000-0000-0000-0000-000000000040")!
        #expect(
            try v2MessageProjectionStateID(messageID: messageID, messageRevision: 1)
                == UUID(uuidString: "0dac7d59-2012-5d48-bcb9-aa3612e6194a")!
        )
        #expect(
            try v2MessageProjectionStateID(messageID: messageID, messageRevision: 2)
                != v2MessageProjectionStateID(messageID: messageID, messageRevision: 1)
        )
        #expect(throws: V2MessageProjectionStateError.invalidPayload) {
            _ = try v2MessageProjectionStateID(messageID: messageID, messageRevision: 0)
        }
    }

    @Test("accepted state round-trips and edits preserve immutable envelope fields")
    func roundTripAndEdit() throws {
        let original = try makeState()
        let decoded = try V2MessageProjectionState(
            payloadJSON: original.encodedPayloadJSON()
        )
        #expect(decoded == original)

        let editedEntity = try V2MessageEntity(
            offsetUTF16: 0, lengthUTF16: 6, kind: .bold
        )
        let edited = try original.applyingEdit(
            revision: 2,
            text: "edited",
            entities: [editedEntity]
        )
        #expect(edited.messageRevision == 2)
        #expect(edited.text == "edited")
        #expect(edited.entities == [editedEntity])
        #expect(edited.messageID == original.messageID)
        #expect(edited.roomID == original.roomID)
        #expect(edited.senderUserID == original.senderUserID)
        #expect(edited.acceptedRoomSequence == original.acceptedRoomSequence)
        #expect(edited.timelineSequence == original.timelineSequence)
        #expect(edited.acceptedAtUnixMilliseconds == original.acceptedAtUnixMilliseconds)

        #expect(throws: V2MessageProjectionStateError.invalidTransition) {
            _ = try original.applyingEdit(revision: 3, text: "skip", entities: [])
        }
    }

    @Test("removal strips every content-bearing field and is terminal")
    func removalIsContentFreeAndTerminal() throws {
        let original = try makeState()
        let removed = try original.applyingRemoval(revision: 2)
        #expect(removed.isWithdrawn)
        #expect(removed.text == "[removed]")
        #expect(removed.mediaIDs.isEmpty)
        #expect(removed.mediaPresentations.isEmpty)
        #expect(removed.mentionUserIDs.isEmpty)
        #expect(!removed.mentionsEveryone)
        #expect(removed.entities.isEmpty)
        #expect(removed.replyToMessageID == nil)
        #expect(removed.forwardedFromMessageID == nil)
        #expect(removed.forwardedFromUserID == nil)
        #expect(
            try V2MessageProjectionState(payloadJSON: removed.encodedPayloadJSON())
                == removed
        )
        #expect(throws: V2MessageProjectionStateError.invalidTransition) {
            _ = try removed.applyingEdit(revision: 3, text: "resurrect", entities: [])
        }
    }

    @Test("projection payload integers must fit persisted positive bigint", arguments:
          ["room_sequence", "timeline_sequence", "message_revision"],
          [UInt64(0), UInt64(Int64.max) - 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func projectionIntegerDecodeBounds(field: String, value: UInt64) throws {
        let original = try makeState()
        let prior = field == "room_sequence" ? 7 : field == "timeline_sequence" ? 9 : 1
        let json = try original.encodedPayloadJSON().replacingOccurrences(of: "\"\(field)\":\(prior)", with: "\"\(field)\":\(value)")
        if value == 0 || value > UInt64(Int64.max) {
            #expect(throws: V2MessageProjectionStateError.invalidPayload) {
                _ = try V2MessageProjectionState(payloadJSON: json)
            }
        } else {
            let decoded = try V2MessageProjectionState(payloadJSON: json)
            let actual = field == "room_sequence" ? decoded.acceptedRoomSequence : field == "timeline_sequence" ? decoded.timelineSequence : decoded.messageRevision
            #expect(actual == value)
            #expect(try V2MessageProjectionState(payloadJSON: decoded.encodedPayloadJSON()) == decoded)
        }
    }

    @Test("restoring a projection rejects revisions outside the persisted range", arguments: [UInt64(Int64.max) + 1, UInt64.max])
    func projectionRestoreBounds(revision: UInt64) throws {
        let original = try makeState()
        #expect(throws: V2MessageProjectionStateError.invalidPayload) {
            _ = try original.restoringActiveRevision(revision, text: "restored", entities: [])
        }
    }

    @Test("the final persisted revision is usable but cannot advance")
    func projectionRevisionExhaustion() throws {
        let penultimate = try makeState().restoringActiveRevision(UInt64(Int64.max) - 1, text: "last active", entities: [])
        let edited = try penultimate.applyingEdit(revision: UInt64(Int64.max), text: "final edit", entities: [])
        let removed = try penultimate.applyingRemoval(revision: UInt64(Int64.max))
        #expect(edited.messageRevision == UInt64(Int64.max) && removed.messageRevision == UInt64(Int64.max))
        #expect(removed.isWithdrawn)
        #expect(try V2MessageProjectionState(payloadJSON: edited.encodedPayloadJSON()) == edited)
        #expect(throws: V2MessageProjectionStateError.invalidTransition) {
            _ = try edited.applyingEdit(revision: UInt64(Int64.max) + 1, text: "overflow", entities: [])
        }
        #expect(throws: V2MessageProjectionStateError.invalidTransition) {
            _ = try edited.applyingRemoval(revision: UInt64(Int64.max) + 1)
        }
    }

    @Test("corrupt stored revisions throw before signed-to-unsigned conversion", arguments: [Int64.min, -1, 0])
    func storedProjectionRejectsInvalidRevision(revision: Int64) throws {
        let state = try makeState()
        let stored = try V2StoredMessageProjectionState(state: state, originEventID: UUID(), stateEventID: nil, createdAt: .now)
        let corrupt = V2StoredMessageProjectionState(stateID: stored.stateID, messageID: stored.messageID, roomID: stored.roomID,
            messageRevision: revision, variantKey: stored.variantKey, originEventID: stored.originEventID, stateEventID: stored.stateEventID,
            isWithdrawn: stored.isWithdrawn, payloadSchemaVersion: stored.payloadSchemaVersion, payloadJSON: stored.payloadJSON, createdAt: stored.createdAt)
        #expect(throws: V2MessageProjectionStatePersistenceError.corruptPersistence) { _ = try corrupt.state }
        #expect(try stored.state == state)
    }

    @Test("accepted projections reject sequence overflow", arguments: [false, true])
    func acceptedProjectionSequenceBounds(timeline: Bool) throws {
        #expect(throws: V2MessageProjectionStateError.invalidPayload) {
            _ = try makeState(roomSequence: timeline ? 7 : UInt64.max, timelineSequence: timeline ? UInt64.max : 9)
        }
        let largest = try makeState(roomSequence: UInt64(Int64.max), timelineSequence: UInt64(Int64.max))
        #expect(largest.acceptedRoomSequence == UInt64(Int64.max) && largest.timelineSequence == UInt64(Int64.max))
    }

    private func makeState(createdAt: Date = Date(timeIntervalSince1970: 1_750_000_000.123), roomSequence: UInt64 = 7, timelineSequence: UInt64 = 9) throws -> V2MessageProjectionState {
        let sender = try UserID("00000000-0000-0000-0000-000000000041")
        let accepted = V2AcceptedMessage(
            messageID: try .init("00000000-0000-0000-0000-000000000040"),
            roomID: try .init("00000000-0000-0000-0000-000000000042"),
            roomSequence: roomSequence,
            timelineSequence: timelineSequence,
            senderUserID: sender,
            clientMessageID: try .init("00000000-0000-0000-0000-000000000043"),
            text: "hello",
            mediaPresentations: [],
            mentions: [.user(sender), .everyone],
            replyTo: .init(
                messageID: try .init("00000000-0000-0000-0000-000000000044")
            ),
            createdAt: createdAt
        )
        return try .init(
            accepted: accepted,
            forwardedFromMessageID: try .init(
                "00000000-0000-0000-0000-000000000045"
            ),
            forwardedFromUserID: try .init(
                "00000000-0000-0000-0000-000000000046"
            )
        )
    }
}

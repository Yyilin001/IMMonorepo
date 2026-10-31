import Foundation
import IMV2Core
import Testing

@Suite("Ephemeral author delta recipient and payload contracts")
struct AuthorPresentationDeltaTests {
    @Test("round trip preserves stream ordering and recipient-specific room proof")
    func roundTrip() throws {
        let value = try fixture()
        #expect(try V2AuthorPresentationDelta.decode(value.encoded()) == value)
        for field in ["actorUserID", "deviceID"] {
            var object = try #require(JSONSerialization.jsonObject(with: value.encoded()) as? [String: Any])
            object[field] = ["rawValue": UUID().uuidString]
            #expect(throws: V2ResourceValidationError.invalidPresentationLease) {
                try V2AuthorPresentationDelta.decode(JSONSerialization.data(withJSONObject: object))
            }
        }
        #expect(throws: V2ResourceValidationError.invalidPresentationLease) {
            try V2AuthorPresentationDelta(streamID: value.streamID, viewID: value.viewID, sequence: 0, actorUserID: value.actorUserID,
                deviceID: value.deviceID, serverViewAgeMilliseconds: 0, batch: value.batch)
        }
    }

    @Test("pending requires bounded retry-after and admits independently authorized contexts")
    func pending() throws {
        let value = try fixture(), key = try #require(value.batch.results.first?.key)
        let batch = try V2ProfilePresentationBatchResponse(serverNowUnixMilliseconds: value.batch.serverNowUnixMilliseconds,
                                                          results: [.retryable(key)])
        for retry: Int64? in [nil, 0, 60_001] {
            #expect(throws: V2ResourceValidationError.invalidPresentationLease) {
                try V2AuthorPresentationDelta(streamID: value.streamID, viewID: value.viewID, sequence: 1, actorUserID: value.actorUserID,
                    deviceID: value.deviceID, serverViewAgeMilliseconds: 0, batch: batch, retryAfterMilliseconds: retry)
            }
        }
        let pending = try V2AuthorPresentationDelta(streamID: value.streamID, viewID: value.viewID, sequence: 1, actorUserID: value.actorUserID,
            deviceID: value.deviceID, serverViewAgeMilliseconds: 0, batch: batch, retryAfterMilliseconds: 1_000)
        #expect(try V2AuthorPresentationDelta.decode(pending.encoded()) == pending)
        let other = try V2ProfilePresentationBatchResponse(serverNowUnixMilliseconds: batch.serverNowUnixMilliseconds,
            results: [.unavailable(.init(userID: key.userID, context: .relationship))])
        let mixed = try V2ProfilePresentationBatchResponse(serverNowUnixMilliseconds: batch.serverNowUnixMilliseconds,
            results: value.batch.results + other.results)
        let delta = try V2AuthorPresentationDelta(streamID: value.streamID, viewID: value.viewID, sequence: 1,
            actorUserID: value.actorUserID, deviceID: value.deviceID, serverViewAgeMilliseconds: 0, batch: mixed)
        #expect(try V2AuthorPresentationDelta.decode(delta.encoded()) == delta)
        #expect(Set(delta.batch.results.map(\.key)).count == 2)
    }

    @Test("wire key order and caller byte mutations do not change an immutable delta")
    func encodedValueSemantics() throws {
        let value = try fixture(), original = try value.encoded()
        var callerBytes = original
        callerBytes[0] ^= 1
        #expect(try value.encoded() == original && callerBytes != original)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let reordered = try V2AuthorPresentationDelta.decode(encoder.encode(value))
        #expect(reordered == value)
        #expect(try V2AuthorPresentationDelta.decode(reordered.encoded()) == value)
        let fields = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        #expect(fields["encodedPayload"] == nil)
    }

    @Test("raw and decoded item budgets both reject oversized deltas")
    func limits() throws {
        let value = try fixture()
        var object = try #require(JSONSerialization.jsonObject(with: value.encoded()) as? [String: Any])
        object["unknownField"] = String(repeating: "x", count: V2AuthorPresentationDelta.maximumEncodedBytes)
        #expect(throws: V2ResourceValidationError.invalidPresentationLease) {
            try V2AuthorPresentationDelta.decode(JSONSerialization.data(withJSONObject: object))
        }
        let entries = (0..<17).map { _ in V2ProfilePresentationBatchEntry.unavailable(
            .init(userID: .init(uuid: UUID()), context: .relationship)) }
        let batch = try V2ProfilePresentationBatchResponse(serverNowUnixMilliseconds: value.batch.serverNowUnixMilliseconds, results: entries)
        #expect(throws: V2ResourceValidationError.invalidPresentationLease) {
            try V2AuthorPresentationDelta(streamID: value.streamID, viewID: value.viewID, sequence: 1, actorUserID: value.actorUserID,
                deviceID: value.deviceID, serverViewAgeMilliseconds: 0, batch: batch)
        }
    }

    @Test("monotonic view age is mandatory and bounded")
    func timingContract() throws {
        let value = try fixture()
        for age in [Int64(-1), 30_000, Int64.max] {
            #expect(throws: V2ResourceValidationError.invalidPresentationLease) {
                try V2AuthorPresentationDelta(streamID: value.streamID, viewID: value.viewID, sequence: 1,
                    actorUserID: value.actorUserID, deviceID: value.deviceID,
                    serverViewAgeMilliseconds: age, batch: value.batch)
            }
        }
        var fields = try #require(JSONSerialization.jsonObject(with: value.encoded()) as? [String: Any])
        fields.removeValue(forKey: "serverViewAgeMilliseconds")
        #expect(throws: (any Error).self) {
            try V2AuthorPresentationDelta.decode(JSONSerialization.data(withJSONObject: fields))
        }
    }

    private func fixture() throws -> V2AuthorPresentationDelta {
        let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID())
        let key = V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: .room(room))
        let revision = try #require(V2ProfileRevision(rawValue: 1)), now = Date(timeIntervalSince1970: 2_000_000_000)
        let view = try V2ProfileView(userID: key.userID, publicIdentity: nil, avatar: nil, state: .hidden,
            revision: revision, visibilityRevision: revision)
        let lease = try V2PresentationAccessLease(actorUserID: actor, deviceID: device, key: key,
            profileRevision: revision, visibilityRevision: revision, contextRevision: 3,
            observedAt: now, validUntil: now.addingTimeInterval(120))
        return try .init(streamID: UUID(), viewID: UUID(), sequence: 1, actorUserID: actor, deviceID: device, roomID: room,
            batch: .init(serverNowUnixMilliseconds: 2_000_000_000_000,
                results: [.presentation(.init(view: view, lease: lease), avatar: nil)]))
    }
}

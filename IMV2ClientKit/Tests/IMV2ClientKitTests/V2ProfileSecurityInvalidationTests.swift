import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Strict profile security invalidations")
struct V2ProfileSecurityInvalidationTests {
    @Test(arguments: ["deleted", "suspended", "hidden"])
    func explicitSecurityStatesAreAccepted(_ state: String) throws {
        let record = try record(state: state)
        let invalidation = try V2ClientProfileInvalidation(record: record)
        #expect(invalidation.state.rawValue == state)
        #expect(invalidation.minimumRevision.rawValue == 2)
    }

    @Test(arguments: [nil, "active", "unknown"] as [String?])
    func oldOrUnknownStateCannotAdvanceSync(_ state: String?) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "strict-profile-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GRDBV2LocalSyncStore(databaseURL: root.appending(path: "client.sqlite"),
            installationBinding: .init(value: UUID()))
        let before = try await store.cursor()
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            _ = try await store.apply(.init(generation: 1, records: [record(state: state)],
                nextSyncToken: .init("strict-next"), receipt: .init("strict-receipt"),
                hasMore: false, capabilityProfile: "base"))
        }
        #expect(try await store.cursor() == before)
        #expect(try await store.pendingProfileInvalidations(limit: 10).isEmpty)
        try await store.close()
    }

    private func record(state: String?) throws -> V2ClientSyncRecord {
        var payload: [String: Any] = ["user_id": UserID(uuid: UUID()).rawValue, "minimum_profile_revision": 2]
        if let state { payload["profile_state"] = state }
        return try .init(sequence: 1, sourceEventID: .init(uuid: UUID()), projectionKind: "profile_invalidation",
                         payload: JSONSerialization.data(withJSONObject: payload))
    }
}

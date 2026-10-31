import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

struct V2ContactAliasProjectionTests {
    private let user = UserID(uuid: UUID())
    private let target = UserID(uuid: UUID())
    private func makeStore() throws -> GRDBV2LocalSyncStore {
        try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "alias-floor-\(UUID()).sqlite"),
            installationBinding: .init(value: UUID()), userID: user)
    }
    private func fact(sequence: UInt64, revision: Int64) throws -> V2ClientSyncRecord {
        try .init(sequence: sequence, sourceEventID: .init(uuid: UUID()), projectionKind: "contact_alias",
            payload: JSONSerialization.data(withJSONObject: ["target_user_id": target.rawValue, "revision": revision]))
    }
    private func batch(_ record: V2ClientSyncRecord) throws -> V2ClientSyncBatch {
        try .init(generation: 1, records: [record], nextSyncToken: .init("token-\(record.sequence)"),
            receipt: .init("receipt-\(record.sequence)"), hasMore: false, capabilityProfile: "base")
    }
    @Test func independentRevisionInvalidatesEditorBaselineWithoutDiscardingIntent() async throws {
        let store = try makeStore(), nameTarget = V2NameTarget.contact(target)
        try await store.saveNameSnapshot(.init(target: nameTarget, name: "Old", revision: .init(rawValue: 1)), accountID: user)
        let intent = try await store.enqueueNameOperation(accountID: user, target: nameTarget, name: "Draft", expectedRevision: .init(rawValue: 1))
        var updates = store.nameSnapshotUpdates(target: nameTarget).makeAsyncIterator()
        let initial = try await updates.next()
        #expect(initial.flatMap { $0 }?.name == "Old")
        let notifications = await store.projectionChanges()
        var changes = notifications.makeAsyncIterator()
        _ = await changes.next()
        _ = try await store.apply(batch(fact(sequence: 1, revision: 2)))
        #expect(await changes.next()?.scopes == .contactAliases)
        let invalidated = try await updates.next()
        #expect(invalidated != nil && invalidated! == nil)
        #expect(try await store.nameSnapshot(target: nameTarget) == nil)
        #expect(try await store.nameCommand(workID: intent).0.name == "Draft")
        #expect(try await store.nameCommand(workID: intent).0.revision?.rawValue == 1)
        try await store.saveNameSnapshot(.init(target: nameTarget, name: "New", revision: .init(rawValue: 2)), accountID: user)
        let refreshed = try await updates.next()
        #expect(refreshed.flatMap { $0 }?.name == "New")
        try await store.close()
    }
    @Test func oldFactsCannotLowerFloorAndContextsKeepIndependentKeys() async throws {
        let store = try makeStore()
        _ = try await store.apply(batch(fact(sequence: 1, revision: 4)))
        _ = try await store.apply(batch(fact(sequence: 2, revision: 1)))
        let keys: Set<V2ProfileViewLookupKey> = [.init(userID: target, context: .relationship),
            .init(userID: target, context: .room(.init(uuid: UUID()))), .init(userID: user, context: .relationship)]
        let values = try await store.contactAliasRevisions(keys: keys)
        #expect(values.count == 3)
        for (key, revision) in values { #expect(revision == (key.userID == target ? 4 : 0)) }
        try await store.close()
    }
    @Test func intentRetriesNeverInvalidateUnrelatedPresentations() {
        for table in ["v2_operation_work", "v2_operation_dependencies", "v2_own_profile_snapshot",
                      "v2_personal_preference_intents", "v2_personal_preference_confirmed", "v2_name_operations", "v2_name_confirmed"] {
            #expect(V2ProjectionTransactionObserver.change(table: table, kind: .update).scopes.isEmpty)
        }
        let profileIntent = V2ProjectionTransactionObserver.change(table: "v2_profile_intents", kind: .update)
        #expect(profileIntent.scopes == .resources)
        #expect(!profileIntent.requiresImmediateRefresh)
    }
    @Test(arguments: ["zero", "fraction", "boolean", "name", "credential", "user"])
    func malformedFactsCannotAdvanceCursor(kind: String) async throws {
        let store = try makeStore()
        var object: [String: Any] = ["target_user_id": target.rawValue, "revision": 1]
        switch kind {
        case "zero": object["revision"] = 0
        case "fraction": object["revision"] = 1.5
        case "boolean": object["revision"] = true
        case "name": object["remark_name"] = "Must not be broadcast"
        case "credential": object["url"] = "https://invalid/credential"
        default: object["target_user_id"] = "not-a-uuid"
        }
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init(uuid: UUID()), projectionKind: "contact_alias", payload: JSONSerialization.data(withJSONObject: object))
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { _ = try await store.apply(batch(record)) }
        #expect(try await store.cursor()?.appliedSequence == nil)
        try await store.close()
    }
    @Test func snapshotCarriesAliasFloorAndDoesNotDeleteLocalIntent() async throws {
        let store = try makeStore()
        _ = try await store.apply(batch(fact(sequence: 1, revision: 4)))
        let intent = try await store.enqueueNameOperation(accountID: user, target: .contact(target), name: "Draft", expectedRevision: .init(rawValue: 4))
        let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        let old = try fact(sequence: 2, revision: 2)
        let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "contact_alias", entityKey: target.rawValue),
            sourceEventID: old.sourceEventID, sequence: 2, payload: old.payload)
        let fixture = try makeSnapshotFixture(reset: reset, pages: [.init(items: [item])])
        try await store.beginReset(reset)
        try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
        for page in fixture.pages { try await store.applySnapshotPage(page, for: fixture.manifest) }
        try await store.prepareSnapshotActivation(fixture.manifest)
        try await store.activateAcknowledgedSnapshot(fixture.manifest)
        let key = V2ProfileViewLookupKey(userID: target, context: .relationship)
        #expect(try await store.contactAliasRevisions(keys: [key])[key] == 4)
        #expect(try await store.nameCommand(workID: intent).0.name == "Draft")
        try await store.close()
    }
}

import Foundation
import IMV2Core
import GRDB
import Testing
@testable import IMV2ClientKit

@Suite("Account-local profile display", .timeLimit(.minutes(1)))
struct V2LocalProfileDisplayTests {
    @Test func expiredLeaseAndPageReentryKeepNamesButNeverKeepByteAuthority() async throws {
        let f = try await Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = Reader(actor: f.actor, device: f.device, lifetime: 0.1)
        let repository = f.repository(reader)
        let activation = await repository.activate()
        _ = try await repository.presentation(for: f.key, activation: activation)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await repository.cachedSnapshot(for: f.key, activation: activation) == nil)
        #expect(try await repository.restoreLocalDisplay().value(for: f.key)?.name == "Original")
        await repository.deactivate(activation)
        await repository.close()
        await reader.setOffline()
        let restored = f.repository(reader)
        let local = try await restored.restoreLocalDisplay()
        #expect(local.value(for: f.key)?.name == "Original")
        #expect(local.value(for: .init(userID: f.key.userID, context: .relationship))?.name == "Original")
        #expect(await reader.calls == 1)
        let next = await restored.activate()
        #expect(await restored.cachedSnapshot(for: f.key, activation: next) == nil)
        await restored.close(); try await f.store.close()
    }

    @Test func ownRemarksShareAcrossContactScreensButGroupNicknamesStayInTheirRoom() async throws {
        let f = try await Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = Reader(actor: f.actor, device: f.device)
        let repository = f.repository(reader), activation = await repository.activate()
        let room = RoomID(uuid: UUID()), otherRoom = RoomID(uuid: UUID())
        let groupKey = V2ProfileViewLookupKey(userID: f.key.userID, context: .room(room))
        let contactKey = V2ProfileViewLookupKey(userID: f.key.userID, context: .relationship)
        await reader.setNames(alias: "My remark", nickname: "Group nickname")
        _ = try await repository.presentation(for: groupKey, activation: activation)
        _ = try await repository.presentation(for: contactKey, activation: activation)
        let local = try await repository.restoreLocalDisplay()
        #expect(local.value(for: groupKey)?.name == "Group nickname")
        #expect(local.value(for: contactKey)?.name == "My remark")
        #expect(local.value(for: f.key)?.name == "My remark")
        #expect(local.value(for: .init(userID: f.key.userID, context: .room(otherRoom)))?.name == "Original")
        let json = try await f.store.databasePool.read { db in
            try Data.fetchAll(db, sql: "SELECT value_json FROM v2_local_profile_display WHERE value_json IS NOT NULL")
        }.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(!json.contains("validUntil") && !json.contains("lease") && !json.contains("https://"))
        await repository.close(); try await f.store.close()
    }

    @Test func contextDenialSurvivesRestartWithoutRevokingAnotherContext() async throws {
        let f = try await Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = Reader(actor: f.actor, device: f.device), repository = f.repository(Reader(actor: f.actor, device: f.device))
        let activation = await repository.activate()
        _ = try await repository.presentation(for: f.key, activation: activation)
        let other = V2ProfileViewLookupKey(userID: f.key.userID, context: .relationship)
        _ = try await repository.presentation(for: other, activation: activation)
        await repository.close()
        await reader.deny(f.key)
        let denying = f.repository(reader), page = await denying.activate()
        #expect(try await denying.presentation(for: f.key, activation: page) == nil)
        let snapshot = try await denying.restoreLocalDisplay()
        #expect(snapshot.value(for: f.key) == nil)
        #expect(snapshot.value(for: other)?.name == "Original")
        await denying.close()
        let restored = f.repository(reader), restoredSnapshot = try await restored.restoreLocalDisplay()
        #expect(restoredSnapshot.value(for: f.key) == nil)
        #expect(restoredSnapshot.value(for: other)?.name == "Original")
        await restored.close(); try await f.store.close()
    }

    @Test func contextDenialCannotRollOtherScreensBackToAnOlderNameOrRemark() async throws {
        let f = try await Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = Reader(actor: f.actor, device: f.device), repository = f.repository(reader)
        let page = await repository.activate()
        _ = try await repository.presentation(for: f.key, activation: page)
        let contact = V2ProfileViewLookupKey(userID: f.key.userID, context: .relationship)
        await reader.setRevision(2)
        await reader.setNames(alias: "Latest remark", nickname: nil)
        _ = try await repository.presentation(for: contact, activation: page)
        #expect(try await repository.restoreLocalDisplay().value(for: f.key)?.name == "Latest remark")
        await repository.close()
        try f.journal.deny(contact)
        let local = try f.journal.load()
        #expect(local.value(for: contact) == nil)
        #expect(local.value(for: f.key)?.name == "Latest remark")
        #expect(local.value(for: f.key)?.identity.displayName == "Updated")
        try await f.store.close()
    }

    @Test func hiddenProjectionAtomicallyPurgesFactsAndRejectsLateOldHTTP() async throws {
        let f = try await Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = Reader(actor: f.actor, device: f.device), repository = f.repository(Reader(actor: f.actor, device: f.device))
        let page = await repository.activate()
        _ = try await repository.presentation(for: f.key, activation: page)
        let old = try #require(try await repository.restoreLocalDisplay().records[f.key])
        try await f.store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_profile_invalidations VALUES(?,2,'hidden',?)", arguments: [f.key.userID.rawValue, Date().timeIntervalSince1970])
        }
        #expect(try f.journal.load().value(for: f.key) == nil)
        #expect(throws: V2ProfilePresentationError.staleResponse) { try f.journal.save(old) }
        #expect(try f.journal.load().value(for: .init(userID: f.key.userID, context: .relationship)) == nil)
        await repository.close()
        await reader.setRevision(3)
        let fresh = f.repository(reader), freshPage = await fresh.activate()
        _ = try await fresh.presentation(for: f.key, activation: freshPage)
        #expect(try await fresh.restoreLocalDisplay().value(for: f.key)?.name == "Updated")
        await fresh.close(); try await f.store.close()
    }

    @Test func legacyFactsAreImportedOnceAndSignOutDoesNotReimportThem() async throws {
        let f = try await Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let rev = try #require(V2ProfileRevision(rawValue: 1))
        try await f.store.saveProfileView(.init(userID: f.key.userID, publicIdentity: .init(userID: f.key.userID,
            handle: .init("legacy"), displayName: "Already local", accountKind: .regular), avatar: nil,
            state: .active, revision: rev, visibilityRevision: rev))
        #expect(try f.journal.load().value(for: f.key)?.name == "Already local")
        try await f.store.clearLocalProfileDisplays()
        #expect(try f.journal.load().value(for: f.key) == nil)
        await #expect(throws: V2ProfilePresentationError.inactive) {
            try await f.store.localProfileDisplayJournal(accountID: .init(uuid: UUID()))
        }
        try await f.store.close()
    }

    private struct Fixture {
        let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
        let directory: URL, store: GRDBV2LocalSyncStore, journal: V2LocalProfileDisplayJournal
        let key = V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: .directConversation)
        init() async throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "local-profile-\(UUID())")
            store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "V2.sqlite"),
                installationBinding: .init(value: UUID()), userID: actor)
            journal = try await store.localProfileDisplayJournal(accountID: actor)
        }
        func repository(_ reader: Reader) -> V2ProfilePresentationRepository {
            .init(actorUserID: actor, deviceID: device, reader: reader, localDisplayJournal: journal)
        }
    }
    private actor Reader: V2ProfilePresentationReading {
        let actor: UserID, device: DeviceID, lifetime: TimeInterval
        var calls = 0, revision: UInt64 = 1
        var offline = false, denied: Set<V2ProfileViewLookupKey> = []
        var alias: String?, nickname: String?
        init(actor: UserID, device: DeviceID, lifetime: TimeInterval = 300) { self.actor = actor; self.device = device; self.lifetime = lifetime }
        func setOffline() { offline = true }
        func deny(_ key: V2ProfileViewLookupKey) { denied.insert(key) }
        func setNames(alias: String?, nickname: String?) { self.alias = alias; self.nickname = nickname }
        func setRevision(_ value: UInt64) { revision = value }
        func readPresentations(_ keys: [V2ProfileViewLookupKey]) throws -> V2ProfilePresentationBatch {
            calls += 1
            if offline { throw URLError(.notConnectedToInternet) }
            let now = Date(), rev = try #require(V2ProfileRevision(rawValue: revision))
            var values: [V2ProfileViewLookupKey: V2AuthorizedProfilePresentation] = [:]
            for key in keys where !denied.contains(key) {
                let view = try V2ProfileView(userID: key.userID, publicIdentity: .init(userID: key.userID,
                    handle: .init("local_user"), displayName: revision == 1 ? "Original" : "Updated", accountKind: .regular),
                    avatar: nil, state: .active, revision: rev, visibilityRevision: rev)
                let member: V2GroupMemberPresentation? = if case .room(let room) = key.context {
                    try .init(roomID: room, userID: key.userID, groupNickname: nickname, revision: rev)
                } else { nil }
                let contactAlias: V2ContactAlias? = if key.context == .relationship {
                    try .init(ownerUserID: actor, targetUserID: key.userID, remarkName: alias, revision: rev)
                } else { nil }
                values[key] = try .init(view: view, lease: .init(actorUserID: actor, deviceID: device, key: key,
                    profileRevision: rev, visibilityRevision: rev, contextRevision: revision, observedAt: now,
                    validUntil: now.addingTimeInterval(lifetime)), groupMember: member, contactAlias: contactAlias)
            }
            return .init(presentations: values, unavailable: Set(keys).intersection(denied), serverNow: now)
        }
    }
}

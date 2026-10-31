import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2Core
import SQLKit
import Testing
@testable import IMV2ServerApplication
@testable import IMV2ServerInfrastructure
@testable import IMV2ServerContracts

@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
struct PostgresV2AuthorProfileChangeTests {
    @Test("public publication retention is independent of pending security delivery")
    func publicationAndSecurityRetention() async throws {
        try await withFixture { f in
            let author = UUID(), pending = UUID(), completed = UUID()
            let old = Date(timeIntervalSince1970: 1_750_000_000)
            let source = PostgresV2AuthorProfileChangeReader(database: f.database)
            let baseline = try await source.readChanges(after: nil)
            try await f.sql.raw("""
                INSERT INTO im_v2.public_profile_update_outbox(source_event_id,source_user_id,revision,created_at)
                VALUES(\(bind:pending),\(bind:author),2,\(bind:old))
                """).run()
            try await f.sql.raw("""
                INSERT INTO im_v2.profile_security_invalidation_outbox
                    (source_event_id,source_user_id,revision,profile_state,profile_updated_at,created_at,state,completed_at)
                VALUES(\(bind:pending),\(bind:author),2,'hidden',\(bind:old),\(bind:old),'pending',NULL),
                      (\(bind:completed),\(bind:author),1,'hidden',\(bind:old),\(bind:old),'completed',\(bind:old))
                """).run()
            let report = try await PostgresV2ControlPlaneHousekeepingStore(database: f.database)
                .purgeTerminal(now: old.addingTimeInterval(30 * 86_400), retention: 86_400,
                               idempotencyRetention: V2IdempotencyPolicy.minimumServerRetention, limit: 1_024)
            #expect(report.deletedRows == 2)
            #expect(try await f.sql.raw("SELECT count(*) AS value FROM im_v2.public_profile_update_outbox WHERE source_event_id=\(bind:pending)").first(decoding: PublicationInteger.self)?.value == 0)
            #expect(try await f.sql.raw("SELECT count(*) AS value FROM im_v2.profile_security_invalidation_outbox WHERE source_event_id=\(bind:pending) AND state='pending'").first(decoding: PublicationInteger.self)?.value == 1)
            #expect(try await source.readChanges(after: baseline.head).resetRequired)
            // A normal display edit is not a valid security queue entry.
            await #expect(throws: (any Error).self) {
                try await f.sql.raw("""
                    INSERT INTO im_v2.profile_security_invalidation_outbox
                        (source_event_id,source_user_id,revision,profile_state,profile_updated_at,created_at)
                    VALUES(\(bind:UUID()),\(bind:author),3,'active',\(bind:old),\(bind:old))
                    """).run()
            }
        }
    }

    @Test("real alias edits and clearing publish private revision identities once")
    func aliasPublication() async throws {
        try await withFixture { f in
            let owner = UUID(), target = UUID(), source = PostgresV2AuthorProfileChangeReader(database: f.database)
            try await seedProfiles(f.sql, users: [owner, target])
            try await f.sql.raw("INSERT INTO im_v2.user_relationships(lower_user_id,higher_user_id,state,requested_by_user_id,updated_at) VALUES(LEAST(\(bind:owner),\(bind:target)),GREATEST(\(bind:owner),\(bind:target)),'accepted',\(bind:owner),clock_timestamp())").run()
            let before = try await source.readChanges(after: nil), store = PostgresV2ProfilePresentationStore(database: f.database)
            let command = try V2ContactAliasUpdateCommand(ownerUserID: .init(uuid: owner), targetUserID: .init(uuid: target),
                operationID: .init(uuid: UUID()), expectedRevision: nil, remarkName: "Private remark",
                firstSubmissionDeadlineMilliseconds: 4_000_000_000_000)
            let receipt = try await store.updateContactAlias(command)
            #expect(try await store.updateContactAlias(command) == receipt)
            _ = try await store.updateContactAlias(.init(ownerUserID: .init(uuid: owner), targetUserID: .init(uuid: target),
                operationID: .init(uuid: UUID()), expectedRevision: .init(rawValue: 1), remarkName: nil,
                firstSubmissionDeadlineMilliseconds: 4_000_000_000_000))
            let changes = try await source.readChanges(after: before.head)
            #expect(changes.head == before.head + 2 && !changes.resetRequired)
            #expect(changes.changes.map(\.revision) == [1, 2])
            #expect(changes.changes.allSatisfy { $0.scope == .contactAlias(owner: .init(uuid: owner), target: .init(uuid: target)) })
            // The publication table has identifiers and counters, no remark text.
            let privateValues = try await f.sql.raw("SELECT count(*) AS value FROM im_v2.author_presentation_control_changes c WHERE to_jsonb(c)::text LIKE '%Private remark%'").first(decoding: PublicationInteger.self)
            #expect(privateValues?.value == 0)
        }
    }

    @Test("alias and social changes defer publication until commit and rollback does not move the head")
    func deferredControlPublication() async throws {
        try await withFixture { f in
            let owner = UUID(), target = UUID(), source = PostgresV2AuthorProfileChangeReader(database: f.database)
            try await seedProfiles(f.sql, users: [owner, target])
            let before = try await source.readChanges(after: nil)
            await #expect(throws: PublicationFailure.rollback) {
                try await f.database.transaction { database in
                    let sql = try #require(database as? any SQLDatabase)
                    try await sql.raw("INSERT INTO im_v2.user_contact_aliases(owner_user_id,target_user_id,remark_name,revision,updated_at) VALUES(\(bind:owner),\(bind:target),'Secret',1,clock_timestamp())").run()
                    try await sql.raw("INSERT INTO im_v2.social_block_revisions(actor_user_id,target_user_id,revision) VALUES(\(bind:owner),\(bind:target),1)").run()
                    let head = try await sql.raw("SELECT sequence AS value FROM im_v2.author_presentation_change_head WHERE singleton").first(decoding: PublicationInteger.self)
                    #expect(head?.value == Int64(before.head))
                    // Forcing the deferred work still remains atomic on rollback.
                    try await sql.raw("SET CONSTRAINTS ALL IMMEDIATE").run()
                    throw PublicationFailure.rollback
                }
            }
            let rolledBack = try await source.readChanges(after: before.head)
            #expect(rolledBack.head == before.head && rolledBack.changes.isEmpty)
            try await f.database.transaction { database in
                let sql = try #require(database as? any SQLDatabase)
                try await sql.raw("INSERT INTO im_v2.social_relationship_revisions(lower_user_id,higher_user_id,revision) VALUES(LEAST(\(bind:owner),\(bind:target)),GREATEST(\(bind:owner),\(bind:target)),1)").run()
                try await sql.raw("INSERT INTO im_v2.social_block_revisions(actor_user_id,target_user_id,revision) VALUES(\(bind:owner),\(bind:target),1),(\(bind:target),\(bind:owner),1)").run()
                let head = try await sql.raw("SELECT sequence AS value FROM im_v2.author_presentation_change_head WHERE singleton").first(decoding: PublicationInteger.self)
                #expect(head?.value == Int64(before.head))
            }
            let committed = try await source.readChanges(after: before.head)
            #expect(committed.head == before.head + 3 && committed.changes.count == 3 && !committed.resetRequired)
            #expect(committed.changes[1].scope == .userBlock(actor: .init(uuid: owner), target: .init(uuid: target)))
            #expect(committed.changes[2].scope == .userBlock(actor: .init(uuid: target), target: .init(uuid: owner)))
            try await f.sql.raw("UPDATE im_v2.social_block_revisions SET revision=revision WHERE actor_user_id=\(bind:owner) AND target_user_id=\(bind:target)").run()
            #expect(try await source.readChanges(after: committed.head).changes.isEmpty)
        }
    }

    @Test("mixed public and deferred control events follow commit order without sequence holes")
    func mixedCommitOrdering() async throws {
        try await withFixture { f in
            let source = PostgresV2AuthorProfileChangeReader(database: f.database), gate = PublicationGate()
            let before = try await source.readChanges(after: nil), owner = UUID(), target = UUID()
            let held = Task {
                try await f.database.transaction { database in
                    let sql = try #require(database as? any SQLDatabase)
                    try await sql.raw("INSERT INTO im_v2.social_block_revisions(actor_user_id,target_user_id,revision) VALUES(\(bind:owner),\(bind:target),1)").run()
                    await gate.wait()
                }
            }
            do {
                try await publicationWait { await gate.waiting }
                try await insert(f.database, author: owner, revision: 1)
                let first = try await source.readChanges(after: before.head)
                #expect(first.changes.count == 1 && first.changes[0].scope == .publicProfile(.init(uuid: owner)))
                await gate.release(); try await held.value
                let next = try await source.readChanges(after: first.head)
                #expect(!next.resetRequired && next.head == first.head + 1)
                #expect(next.changes.first?.scope == .userBlock(actor: .init(uuid: owner), target: .init(uuid: target)))
            } catch { await gate.release(); _ = await held.result; throw error }
        }
    }

    @Test("bounded housekeeping removes expired control notifications and readers reset over the gap")
    func controlRetention() async throws {
        try await withFixture { f in
            let source = PostgresV2AuthorProfileChangeReader(database: f.database), owner = UUID(), target = UUID()
            let before = try await source.readChanges(after: nil)
            try await f.sql.raw("INSERT INTO im_v2.social_block_revisions(actor_user_id,target_user_id,revision) VALUES(\(bind:owner),\(bind:target),1)").run()
            let published = try await source.readChanges(after: before.head)
            #expect(published.changes.count == 1)
            try await f.sql.raw("UPDATE im_v2.author_presentation_control_changes SET created_at=clock_timestamp()-INTERVAL '8 days' WHERE owner_user_id=\(bind:owner)").run()
            let report = try await PostgresV2ControlPlaneHousekeepingStore(database: f.database)
                .purgeTerminal(now: Date(), retention: 7 * 86_400, idempotencyRetention: V2IdempotencyPolicy.minimumServerRetention, limit: 128)
            #expect(report.deletedRows > 0 && report.deletedRows <= 128)
            let reset = try await source.readChanges(after: before.head)
            #expect(reset.resetRequired && reset.head == published.head && reset.changes.isEmpty)
        }
    }

    @Test("real profile edits and idempotent replays publish once to every independent gateway cursor")
    func independentReaders() async throws {
        try await withFixture { f in
            let source = PostgresV2AuthorProfileChangeReader(database: f.database)
            let start = try await source.readChanges(after: nil)
            #expect(start.resetRequired && start.changes.isEmpty)
            let author = UUID(), handle = "pc" + author.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20)
            try await f.sql.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) VALUES(\(bind:author),\(bind:handle),'Before',clock_timestamp(),clock_timestamp())").run()
            let store = PostgresV2ProfileUpdateStore(database: f.database)
            let command = try V2ProfileUpdateCommand(actorUserID: .init(uuid: author), operationID: .init(uuid: UUID()),
                expectedRevision: #require(.init(rawValue: 1)), patch: .init(displayName: .set("After")),
                firstSubmissionDeadlineMilliseconds: 4_000_000_000_000)
            let applied = try await store.update(command)
            #expect(applied.currentSnapshot?.publicIdentity?.displayName == "After")
            _ = try await store.update(command)
            let a = try await source.readChanges(after: start.head)
            let b = try await PostgresV2AuthorProfileChangeReader(database: f.database).readChanges(after: start.head)
            #expect(!a.resetRequired && a.head == start.head + 1 && a.changes == b.changes)
            #expect(a.changes.count == 1 && a.changes[0].scope == .publicProfile(.init(uuid: author)) && a.changes[0].revision == 2)
            let idle = try await source.readChanges(after: a.head)
            #expect(idle.head == a.head && idle.changes.isEmpty && !idle.resetRequired)
        }
    }

    @Test("rollback removes both the source event and publication head advancement")
    func rollback() async throws {
        try await withFixture { f in
            let source = PostgresV2AuthorProfileChangeReader(database: f.database)
            let before = try await source.readChanges(after: nil), author = UUID()
            await #expect(throws: PublicationFailure.rollback) {
                try await f.database.transaction { database in
                    try await insert(database, author: author, revision: 1)
                    throw PublicationFailure.rollback
                }
            }
            let after = try await source.readChanges(after: before.head)
            #expect(!after.resetRequired && after.head == before.head && after.changes.isEmpty)
            try await insert(f.database, author: author, revision: 1)
            let committed = try await source.readChanges(after: before.head)
            #expect(committed.changes.first?.sequence == before.head + 1)
        }
    }

    @Test("a later transaction cannot publish past an uncommitted head", arguments: [false, true])
    func commitOrdering(rollbackFirst: Bool) async throws {
        try await withFixture { f in
            let source = PostgresV2AuthorProfileChangeReader(database: f.database), gate = PublicationGate()
            let start = try await source.readChanges(after: nil), firstAuthor = UUID(), secondAuthor = UUID()
            let first = Task {
                try await f.database.transaction { database in
                    try await insert(database, author: firstAuthor, revision: 1)
                    await gate.wait()
                    if rollbackFirst { throw PublicationFailure.rollback }
                }
            }
            var second: Task<Void, any Error>?
            do {
                try await publicationWait { await gate.waiting }
                let invisible = try await source.readChanges(after: start.head)
                #expect(invisible.head == start.head && invisible.changes.isEmpty)
                second = Task {
                    try await f.database.transaction { database in
                        let sql = try #require(database as? any SQLDatabase)
                        let pid = try #require(await sql.raw("SELECT pg_backend_pid() AS value").first(decoding: PublicationInteger.self))
                        await gate.setSecondPID(pid.value)
                        try await insert(database, author: secondAuthor, revision: 1)
                    }
                }
                // Observe the real database lock, rather than infer ordering
                // from a fixed sleep or from Swift task scheduling.
                try await publicationWait {
                    guard let pid = await gate.secondPID else { return false }
                    let blocked = try await f.sql.raw("SELECT count(*) AS value FROM pg_stat_activity WHERE pid=\(bind:pid) AND wait_event_type='Lock'")
                        .first(decoding: PublicationInteger.self)
                    return blocked?.value == 1
                }
                let stillInvisible = try await source.readChanges(after: start.head)
                #expect(stillInvisible.head == start.head && stillInvisible.changes.isEmpty)
                await gate.release()
                if rollbackFirst { await #expect(throws: PublicationFailure.rollback) { try await first.value } }
                else { try await first.value }
                try await second?.value
                let published = try await source.readChanges(after: start.head)
                #expect(!published.resetRequired)
                #expect(published.changes.map(\.scope) == (rollbackFirst ? [.publicProfile(.init(uuid: secondAuthor))] : [.publicProfile(.init(uuid: firstAuthor)), .publicProfile(.init(uuid: secondAuthor))]))
                #expect(published.changes.map(\.sequence) == (rollbackFirst ? [start.head + 1] : [start.head + 1, start.head + 2]))
            } catch {
                await gate.release()
                _ = await first.result; _ = await second?.result
                throw error
            }
        }
    }

    @Test("bounded pagination never skips committed events and retention gaps request a reset")
    func paginationAndRetention() async throws {
        try await withFixture { f in
            let source = PostgresV2AuthorProfileChangeReader(database: f.database)
            let start = try await source.readChanges(after: nil), author = UUID()
            try await f.database.transaction { database in
                for revision in 1...130 { try await insert(database, author: author, revision: Int64(revision)) }
            }
            let first = try await source.readChanges(after: start.head)
            #expect(!first.resetRequired && first.changes.count == 128 && first.head == start.head + 130)
            let second = try await source.readChanges(after: #require(first.changes.last).sequence)
            #expect(!second.resetRequired && second.changes.map(\.revision) == [129, 130])
            try await f.sql.raw("DELETE FROM im_v2.public_profile_update_outbox WHERE source_user_id=\(bind:author) AND revision=129").run()
            let gap = try await source.readChanges(after: start.head + 128)
            #expect(gap.resetRequired && gap.changes.isEmpty && gap.head == first.head)
            try await f.sql.raw("DELETE FROM im_v2.public_profile_update_outbox WHERE source_user_id=\(bind:author)").run()
            let emptyGap = try await source.readChanges(after: start.head)
            #expect(emptyGap.resetRequired && emptyGap.head == first.head)
            let rewind = try await source.readChanges(after: first.head + 1)
            #expect(rewind.resetRequired && rewind.head == first.head)
        }
    }

    @Test("readiness rejects disabled or altered publication and room authority semantics before opening the gateway",
          arguments: ["ALTER TABLE im_v2.profile_security_invalidation_outbox DROP CONSTRAINT profile_security_invalidation_outbox_profile_state_check",
                      "ALTER TABLE im_v2.public_profile_update_outbox DISABLE TRIGGER public_profile_update_sequence",
                      "ALTER TABLE im_v2.group_join_requests DISABLE TRIGGER group_join_review_authority",
                      "CREATE OR REPLACE FUNCTION im_v2.advance_group_join_review_authority() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END; $$"])
    func readinessDrift(_ drift: String) async throws {
        try await withFixture { f in
            try await V2SchemaReadiness.verify(database: f.database)
            do {
                try await f.database.transaction { database in
                    let sql = try #require(database as? any SQLDatabase)
                    try await sql.raw("\(unsafeRaw: drift)").run()
                    await #expect(throws: V2SchemaReadinessError.unavailableTable("im_v2.public_profile_update_outbox.publication")) {
                        try await V2SchemaReadiness.verify(database: database)
                    }
                    throw PublicationFailure.rollback
                }
            } catch PublicationFailure.rollback {}
            try await V2SchemaReadiness.verify(database: f.database)
        }
    }

    private func withFixture(_ body: (PublicationFixture) async throws -> Void) async throws {
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"]),
                maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let database = resources.database(.psql)
            try await body(.init(database: database, sql: #require(database as? any SQLDatabase)))
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }
}

private func seedProfiles(_ sql: any SQLDatabase, users: [UUID]) async throws {
    for user in users {
        let handle = "pc" + user.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20)
        try await sql.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) VALUES(\(bind:user),\(bind:handle),'Profile',clock_timestamp(),clock_timestamp())").run()
    }
}

private func insert(_ database: any Database, author: UUID, revision: Int64) async throws {
    let sql = try #require(database as? any SQLDatabase)
    try await sql.raw("""
        INSERT INTO im_v2.public_profile_update_outbox
            (source_event_id,source_user_id,revision,created_at)
        VALUES(\(bind:UUID()),\(bind:author),\(bind:revision),clock_timestamp())
        """).run()
}
private struct PublicationFixture: Sendable { let database: any Database; let sql: any SQLDatabase }
private struct PublicationInteger: Decodable { let value: Int64 }
private enum PublicationFailure: Error { case rollback }
private actor PublicationGate {
    var waiting: Bool { continuation != nil }
    var secondPID: Int64?
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func setSecondPID(_ pid: Int64) { secondPID = pid }
}
private func publicationWait(_ predicate: () async throws -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(5)
    while try !(await predicate()) {
        guard .now < end else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(1))
    }
}

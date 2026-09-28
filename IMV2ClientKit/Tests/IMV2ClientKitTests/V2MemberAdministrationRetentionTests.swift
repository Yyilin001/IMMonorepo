import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

struct V2MemberAdministrationRetentionTests {
    @Test("completed member administration history is deleted atomically after seven days", arguments: [false, true])
    func completedHistory(removal: Bool) async throws {
        let f = try AdministrationFixture(); defer { f.remove() }
        let now = Date()
        let until = UInt64((now.timeIntervalSince1970 + 600) * 1_000)
        let id = try await f.service.enqueue(roomID: f.room, targetUserID: f.target,
            action: removal ? .remove : .mute(untilMilliseconds: until), reasonCode: .init("ADMIN_ACTION"), expectedMembershipRevision: 0)
        #expect(try await f.service.prepareNextIntent())
        let pending = try await f.store.memberAdministrationPending(id: id)
        let command = try #require(pending.command), work = try #require(pending.work)
        _ = try await f.claim(work.id)
        let outcome: V2MemberAdministrationTerminalOutcome = removal
            ? .applied(.removed(membershipRevision: 1, roomSequence: 1, eventID: .init(uuid: UUID())))
            : .alreadySatisfied(muteUntilMilliseconds: until, membershipRevision: 0)
        let receipt = try V2MemberAdministrationReceipt(identity: command.identity, fingerprint: command.fingerprint,
            outcome: outcome, resolvedAtMilliseconds: UInt64(now.timeIntervalSince1970 * 1_000))
        try await f.store.completeMemberAdministration(receipt, command: command, now: now)
        #expect(try await f.store.pruneCompletedOperationHistory(now: now.addingTimeInterval(6 * 86_400)) == 0)
        try await f.store.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: f.url, installationBinding: f.binding, userID: f.account)
        try await reopened.databasePool.write { db in
            try db.execute(sql: "CREATE TRIGGER retention_abort BEFORE DELETE ON v2_operation_work BEGIN SELECT RAISE(ABORT,'retention fixture'); END")
        }
        await #expect(throws: (any Error).self) {
            try await reopened.pruneCompletedOperationHistory(now: now.addingTimeInterval(8 * 86_400))
        }
        #expect(try await reopened.memberAdministrationPending(id: id).command == command)
        #expect(try await reopened.operationWork(id: work.id)?.execution == .committed)
        try await reopened.databasePool.write { try $0.execute(sql: "DROP TRIGGER retention_abort") }
        #expect(try await reopened.pruneCompletedOperationHistory(now: now.addingTimeInterval(8 * 86_400)) == 1)
        #expect(try await reopened.operationWork(id: work.id) == nil)
        let count = try await reopened.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_member_administration_intents") }
        #expect(count == 0)
        try await reopened.close()
    }

    @Test("unknown operations and unconfirmed drafts are never aged out", arguments: [false, true])
    func unresolvedHistory(frozen: Bool) async throws {
        let f = try AdministrationFixture(); defer { f.remove() }
        let id = try await f.service.enqueue(roomID: f.room, targetUserID: f.target, action: .remove,
            reasonCode: .init("ADMIN_ACTION"), expectedMembershipRevision: 0)
        if frozen {
            #expect(try await f.service.prepareNextIntent())
            let work = try #require(try await f.store.memberAdministrationPending(id: id).work)
            try await f.service.execute(f.claim(work.id))
            #expect(try await f.store.operationWork(id: work.id)?.execution == .awaitingConfirmation)
        } else {
            try await f.store.pauseMemberAdministrationPreparation(id: id, code: "CONFIRMATION_REQUIRED")
        }
        #expect(try await f.store.pruneCompletedOperationHistory(now: Date().addingTimeInterval(30 * 86_400)) == 0)
        #expect(try await f.store.memberAdministrationPending(id: id).id == id)
        try await f.store.close()
    }
}

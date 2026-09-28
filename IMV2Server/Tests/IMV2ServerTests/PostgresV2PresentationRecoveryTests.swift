import Foundation
import IMV2Core
import SQLKit
import Testing
@testable import IMV2Server

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("Presentation receipts preserve outcomes, close races and authorize edit baselines", arguments: [false, true])
    func presentationRecovery(alias: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, userDatabase, sql, userSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000), target = UserID(uuid: memberTwoUUID)
            if alias {
                try await sql.raw("INSERT INTO im_v2.user_relationships(lower_user_id,higher_user_id,state,requested_by_user_id,updated_at) VALUES(\(bind:senderUUID),\(bind:memberTwoUUID),'accepted',\(bind:senderUUID),\(bind:now))").run()
            }
            let store = PostgresV2ProfilePresentationStore(database: database, nicknameCapacityProfile: try forwardImportTestProfile(), now: { now })
            func update(_ op: UUID, revision: UInt64?, name: String?, deadline: UInt64 = UInt64(Int64.max)) async throws -> V2OperationExecutionState {
                if alias {
                    let c = try V2ContactAliasUpdateCommand(ownerUserID: senderID, targetUserID: target, operationID: .init(uuid: op), expectedRevision: revision.flatMap(V2ProfileRevision.init(rawValue:)), remarkName: name, firstSubmissionDeadlineMilliseconds: deadline)
                    let result = try await store.updateContactAlias(c)
                    switch result.outcome { case .committed: return .committed; case .closed: return .closed; case .rejected(.expiredUnsubmitted): return .expiredUnsubmitted; case .rejected: return .rejected }
                }
                let c = try V2GroupNicknameUpdateCommand(actorUserID: senderID, roomID: roomID, operationID: .init(uuid: op), expectedRevision: revision.flatMap(V2ProfileRevision.init(rawValue:)), nickname: name, firstSubmissionDeadlineMilliseconds: deadline)
                let result = try await store.updateOwnGroupNickname(c)
                switch result.outcome { case .committed: return .committed; case .closed: return .closed; case .rejected(.expiredUnsubmitted): return .expiredUnsubmitted; case .rejected: return .rejected }
            }
            func recovery(_ op: UUID, revision: UInt64?, name: String?, close: Bool) async throws -> V2OperationExecutionState? {
                if alias {
                    let c = try V2ContactAliasUpdateCommand(ownerUserID: senderID, targetUserID: target, operationID: .init(uuid: op), expectedRevision: revision.flatMap(V2ProfileRevision.init(rawValue:)), remarkName: name, firstSubmissionDeadlineMilliseconds: UInt64(Int64.max))
                    let result = try await store.recoverContactAlias(.init(identity: c.identity, fingerprint: c.fingerprint, action: close ? .closeIfAbsent:.query))
                    switch result { case .unresolved: return nil; case .fingerprintConflict: throw CancellationError(); case .receipt(let r): switch r.outcome {case .committed:return .committed;case .closed:return .closed;case .rejected:return .rejected} }
                }
                let c = try V2GroupNicknameUpdateCommand(actorUserID: senderID, roomID: roomID, operationID: .init(uuid: op), expectedRevision: revision.flatMap(V2ProfileRevision.init(rawValue:)), nickname: name, firstSubmissionDeadlineMilliseconds: UInt64(Int64.max))
                let result = try await store.recoverGroupNickname(.init(identity: c.identity, fingerprint: c.fingerprint, action: close ? .closeIfAbsent:.query))
                switch result { case .unresolved: return nil; case .fingerprintConflict: throw CancellationError(); case .receipt(let r): switch r.outcome {case .committed:return .committed;case .closed:return .closed;case .rejected:return .rejected} }
            }
            if alias { #expect(try await store.contactAliasSnapshot(ownerUserID: senderID, targetUserID: target).value == nil) }
            else { #expect(try await store.ownGroupNicknameSnapshot(actorUserID: senderID, roomID: roomID).value == nil) }
            let a = UUID(), b = UUID()
            #expect(try await recovery(a, revision: nil, name: nil, close: false) == nil)
            #expect(try await update(a, revision: nil, name: nil) == .committed)
            #expect(try await update(b, revision: 1, name: nil) == .committed)
            #expect(try await update(a, revision: nil, name: nil) == .committed)
            if alias {
                let command = try V2ContactAliasUpdateCommand(ownerUserID:senderID,targetUserID:target,operationID:.init(uuid:a),expectedRevision:nil,remarkName:nil,firstSubmissionDeadlineMilliseconds:UInt64(Int64.max))
                #expect(try await store.updateContactAlias(command).committedValue.revision.rawValue == 1)
                #expect(try await store.contactAliasSnapshot(ownerUserID:senderID,targetUserID:target).value?.revision.rawValue == 2)
                await #expect(throws:V2ProfilePresentationError.operationPayloadMismatch) { _ = try await update(a,revision:nil,name:"different") }
            } else {
                let command = try V2GroupNicknameUpdateCommand(actorUserID:senderID,roomID:roomID,operationID:.init(uuid:a),expectedRevision:nil,nickname:nil,firstSubmissionDeadlineMilliseconds:UInt64(Int64.max))
                #expect(try await store.updateOwnGroupNickname(command).committedValue.revision.rawValue == 1)
                #expect(try await store.ownGroupNicknameSnapshot(actorUserID:senderID,roomID:roomID).value?.revision.rawValue == 2)
                await #expect(throws:V2ProfilePresentationError.operationPayloadMismatch) { _ = try await update(a,revision:nil,name:"different") }
            }

            #expect(try await recovery(a, revision: nil, name: nil, close: true) == .committed)
            let stale = UUID()
            #expect(try await update(stale, revision: 1, name: "stale") == .rejected)
            #expect(try await update(stale, revision: 1, name: "stale") == .rejected)
            #expect(try await update(UUID(), revision: 2, name: "expired", deadline: 1) == .expiredUnsubmitted)
            let closed = UUID()
            #expect(try await recovery(closed, revision: 2, name: "closed", close: true) == .closed)
            #expect(try await update(closed, revision: 2, name: "closed") == .closed)
            if alias {
                let outbox = try PostgresV2UserStateEventOutbox(database: database)
                let events = try await outbox.claim(now:Date().addingTimeInterval(1),leaseDuration:30,limit:100)
                    .map(\.event).filter { $0.kind == .contactAlias }
                #expect(events.count == 2)
                let projector = try PostgresV2UserStateEventProjector(database:userDatabase)
                for event in events.sorted(by: { $0.payloadJSON > $1.payloadJSON }) { _ = try await projector.project(event) }
                let report = try await PostgresV2UserProjectionWorker(database:userDatabase).runOnce(now:Date().addingTimeInterval(2))
                #expect(report.failedRecordCount == 0)
                let row = try #require(try await userSQL.raw("SELECT payload::text AS value FROM im_v2.user_projection_versions WHERE user_id=\(bind:senderUUID) AND projection_kind='contact_alias' AND valid_to_sequence IS NULL").first(decoding:PresentationPayload.self))
                let payload = try #require(JSONSerialization.jsonObject(with:Data(row.value.utf8)) as? [String:Any])
                #expect(Set(payload.keys) == ["target_user_id","revision"])
                #expect(payload["revision"] as? Int == 2)
            }
            for _ in 0..<8 {
                let op = UUID()
                async let submitted = update(op, revision: 2, name: nil)
                async let cancelled = recovery(op, revision: 2, name: nil, close: true)
                let (s, c) = try await (submitted, cancelled)
                #expect(c == s)
            }
            let table = alias ? "contact_alias_operation_receipts":"group_nickname_operation_receipts"
            await #expect(throws: (any Error).self) { try await sql.raw("DELETE FROM im_v2.\(unsafeRaw:table)").run() }
            await #expect(throws: (any Error).self) { try await sql.raw("UPDATE im_v2.\(unsafeRaw:table) SET receipt='{}'").run() }
            if alias {
                try await sql.raw("DELETE FROM im_v2.user_relationships").run()
                await #expect(throws: V2ProfilePresentationError.forbidden) { _ = try await store.contactAliasSnapshot(ownerUserID: senderID, targetUserID: target) }
            } else {
                try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=2 WHERE room_id=\(bind:roomUUID) AND user_id=\(bind:senderUUID)").run()
                try await sql.raw("UPDATE im_v2.rooms SET membership_revision=2 WHERE room_id=\(bind:roomUUID)").run()
                await #expect(throws: V2ProfilePresentationError.forbidden) { _ = try await store.ownGroupNicknameSnapshot(actorUserID: senderID, roomID: roomID) }
            }
            #expect(try await recovery(a, revision: nil, name: nil, close: false) == .committed)
        }
    }
}

private struct PresentationPayload: Decodable { let value:String }

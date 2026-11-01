@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import Foundation
import IMV2Core
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("ownership transfer and dissolution are atomic, permission fenced, and permanently recoverable", arguments: [V2GroupCapacityClass.standard, .large])
    func groupLifecycleTerminalReceipts(_ mode: V2GroupCapacityClass) async throws {
        try await withForwardOwnerDatabases(mode: mode) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000), profile = try forwardImportTestProfile()
            try await sql.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE user_id=\(bind: senderUUID)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision=1").run()
            let target = UserID(uuid: memberTwoUUID), invite = UUID(), request = UUID()
            try await sql.raw("""
                INSERT INTO im_v2.group_invite_links(invite_id,room_id,created_by_user_id,creation_operation_id,token_digest,requested_lifetime_seconds,expires_at,maximum_approved_uses,created_at)
                VALUES(\(bind: invite),\(bind: roomUUID),\(bind: senderUUID),\(bind: UUID()),\(bind: Data(repeating: 1,count: 32)),300,\(bind: now.addingTimeInterval(300)),10,\(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.group_join_requests(request_id,invite_id,room_id,applicant_user_id,submission_operation_id,created_at,updated_at)
                VALUES(\(bind: request),\(bind: invite),\(bind: roomUUID),\(bind: memberThreeUUID),\(bind: UUID()),\(bind: now),\(bind: now))
                """).run()
            @Sendable func intent(actor: UserID, action: V2GroupCapabilityAction) throws -> V2GroupCapabilityIntent {
                let reference: V2OperationReference = action.kind == .groupOwnership ? .groupOwnership(.init(uuid: UUID())) : .groupDissolution(.init(uuid: UUID()))
                return try .init(identity: .init(accountID: actor, scope: .room(roomID), operation: reference), action: action, confirmedUntilMilliseconds: 1_750_000_120_000)
            }
            try await withRoomActivation(database: database, roomID: roomID) { token in
                let store = PostgresV2GroupCapabilityOperationStore(database: database, clock: { now })
                let outbox = try PostgresV2UserStateEventOutbox(database: database)
                let projector = try PostgresV2UserStateEventProjector(database: database)
                let delivery = V2UserStateEventWorker(outbox: outbox, projector: projector, now: { now.addingTimeInterval(1) })
                let snapshots = PostgresV2UserProjectionWorker(database: database)
                for user in [senderUUID, memberTwoUUID, memberThreeUUID] {
                    let grant = try V2UserStateEvent(sourceEventID: .init(uuid: UUID()), userID: .init(uuid: user), kind: .membership,
                        payload: JSONSerialization.data(withJSONObject: ["event_type": "membership_changed", "room_id": roomUUID.uuidString,
                            "target_user_id": user.uuidString, "action": "add", "membership_revision": 1,
                            "title": "集成测试群", "owner_user_id": senderUUID.uuidString,
                            "capacity_class": mode.rawValue, "created_at_ms": 1_750_000_000_000]), createdAt: now)
                    _ = try await projector.project(grant)
                }

                let transferIntent = try intent(actor: senderID, action: .transferOwnership(targetUserID: target, expectedMembershipRevision: 1))
                guard case .admitted(let admission) = try await store.admit(transferIntent, token: token) else { throw V2GroupCapabilityValidationError.invalidAdmission }
                let transfer = try V2GroupCapabilityCommand(intent: transferIntent, admission: admission)
                let result = try await store.submit(transfer, token: token, capacityProfile: profile, eventID: .init(uuid: UUID()))
                guard case .receipt(let receipt) = result, case .applied(.ownershipTransferred(let previous, let owner, let revision, _)) = receipt.outcome else { throw V2GroupCapabilityValidationError.invalidReceipt }
                #expect(previous == senderID && owner == target && revision == 2 && receipt.validates(command: transfer))
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.room_memberships WHERE left_revision IS NULL AND role='owner' AND user_id=\(bind: memberTwoUUID)").first(decoding: CountRow.self)?.value == 1)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_rooms WHERE owner_user_id=\(bind: memberTwoUUID)").first(decoding: CountRow.self)?.value == 1)
                #expect(try await delivery.runOnce(limit: 10) == 3)
                for _ in 0..<3 {
                    let report = try await snapshots.runOnce(now: Date())
                    #expect(report.appliedRecordCount == 2 && report.failedRecordCount == 0)
                }
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_projection_versions WHERE valid_to_sequence IS NULL AND projection_kind='room' AND payload->>'viewer_membership_revision'='1' AND payload->>'owner_user_id'=\(bind: memberTwoUUID.uuidString)").first(decoding: CountRow.self)?.value == 3)
                #expect(try await store.admit(intent(actor: senderID, action: .dissolve(expectedMembershipRevision: 2)), token: token) == .currentUnavailable(.current(.permissionDenied)))
                #expect(try await store.admit(intent(actor: target, action: .dissolve(expectedMembershipRevision: 1)), token: token) == .currentUnavailable(.current(.revisionChanged(currentRevision: 2))))
                let dissolveIntent = try intent(actor: target, action: .dissolve(expectedMembershipRevision: 2))
                guard case .admitted(let closeAdmission) = try await store.admit(dissolveIntent, token: token) else { throw V2GroupCapabilityValidationError.invalidAdmission }
                let dissolve = try V2GroupCapabilityCommand(intent: dissolveIntent, admission: closeAdmission)
                let closed = try await store.submit(dissolve, token: token, capacityProfile: profile, eventID: .init(uuid: UUID()))
                guard case .receipt(let proof) = closed else { throw V2GroupCapabilityValidationError.invalidReceipt }
                #expect(proof.outcome == .applied(.dissolved(membershipRevision: 3, roomSequence: 2)))
                #expect(proof.validates(command: dissolve))
                let restarted = PostgresV2GroupCapabilityOperationStore(database: database, clock: { now.addingTimeInterval(600) })
                #expect(try await restarted.submit(dissolve, token: token, capacityProfile: profile, eventID: .init(uuid: UUID())) == closed)
                #expect(try await restarted.recover(.init(identity: transfer.identity, fingerprint: transfer.fingerprint, action: .closeIfAbsent), token: token) == result)
                #expect(try await store.admit(intent(actor: target, action: .dissolve(expectedMembershipRevision: 3)), token: token) == .currentUnavailable(.current(.roomDissolved)))
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.room_memberships WHERE left_revision IS NULL").first(decoding: CountRow.self)?.value == 0)
                #expect(try await sql.raw("SELECT eligible_member_count AS value FROM im_v2.room_admission").first(decoding: CountRow.self)?.value == 0)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_state_event_outbox WHERE projection_kind='membership'").first(decoding: CountRow.self)?.value == 6)
                #expect(try await count("im_v2.group_capability_receipts", on: sql) == 2)
                #expect(try await count("im_v2.room_events", on: sql) == 2)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_links WHERE state='revoked'").first(decoding: CountRow.self)?.value == 1)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_join_requests WHERE state='rejected'").first(decoding: CountRow.self)?.value == 1)
                #expect(try await delivery.runOnce(limit: 10) == 3)
                var applied = 0
                for _ in 0..<3 {
                    let report = try await snapshots.runOnce(now: Date())
                    #expect(report.failedRecordCount == 0)
                    applied += report.appliedRecordCount
                }
                #expect(applied == 3)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_projection_versions WHERE valid_to_sequence IS NULL AND projection_kind='room' AND payload->>'viewer_is_member'='false'").first(decoding: CountRow.self)?.value == 3)
                await #expect(throws: (any Error).self) { try await sql.raw("UPDATE im_v2.rooms SET dissolved_at=NULL").run() }
                await #expect(throws: (any Error).self) { try await sql.raw("UPDATE im_v2.rooms SET frozen_at=NULL,frozen_by_user_id=NULL").run() }
                let lateSend = try V2MessageSendOperationCommand(command: .init(roomID: roomID, senderUserID: target, clientMessageID: .init(uuid: UUID()), text: "after dissolution", limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
                let sendStore = v2FixtureMessageSendOperationStore(database: database, writes: PostgresV2RoomWriteStore(database: database), clock: { now })
                let late = try await sendStore.send(lateSend, token: token, capacityProfile: profile, identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())))
                guard case .receipt(let denial) = late, case .rejected = denial.outcome else { throw V2MessageOperationValidationError.invalidReceipt }
                #expect(try await count("im_v2.messages", on: sql) == 0)
            }
        }
    }
}

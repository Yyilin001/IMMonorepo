import Foundation
import IMV2Core
import SQLKit
import Testing
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("Presence batch isolates complete viewer keys and preserves privacy and lease selection")
    func presenceBatchKeepsViewerAuthorizationAndLeasePrivacy() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let peer = UserID(uuid: memberTwoUUID)
            let room = try await V2DirectRoomOperationTestFixture(database: database,
                capacityProfile: forwardImportTestProfile(), roomShardID: "room-a", roomID: .init(uuid: UUID()),
                now: { base }).openedIdentity(actorUserID: senderID, operationID: .init(uuid: UUID()),
                    targetUserID: peer, firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
            let live = try PostgresV2LiveActivityStore(database: database)
            let good = V2PresenceObservationRequest(roomID: room.roomID, viewerUserID: senderID, targetUserID: peer)
            let reverse = V2PresenceObservationRequest(roomID: room.roomID, viewerUserID: peer, targetUserID: senderID)
            let wrongTarget = V2PresenceObservationRequest(roomID: room.roomID, viewerUserID: senderID, targetUserID: senderID)
            let outsider = V2PresenceObservationRequest(roomID: room.roomID, viewerUserID: .init(uuid: UUID()), targetUserID: peer)
            let missing = V2PresenceObservationRequest(roomID: .init(uuid: UUID()), viewerUserID: senderID, targetUserID: peer)
            let device = UUID(), active = UUID(), suppressed = UUID(), expired = UUID()
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id,device_id,created_at,last_active_at) VALUES (\(bind:memberTwoUUID),\(bind:device),\(bind:base),\(bind:base))").run()
            for (connection, hidden, expiry) in [(active, false, base.addingTimeInterval(30)),
                (suppressed, true, base.addingTimeInterval(90)), (expired, false, base.addingTimeInterval(-1))] {
                try await sql.raw("INSERT INTO im_v2.user_live_presence_leases (connection_id,publication_suppressed,user_id,device_id,expires_at,updated_at) VALUES (\(bind:connection),\(bind:hidden),\(bind:memberTwoUUID),\(bind:device),\(bind:expiry),\(bind:base))").run()
            }
            let initial = try await live.presenceBatch([good, reverse, wrongTarget, outsider, missing, good], now: base)
            #expect(initial.count == 5)
            #expect(initial[good] == .observed(.init(roomID: room.roomID, targetUserID: peer, isOnline: true, expiresAt: base.addingTimeInterval(30))))
            #expect(initial[reverse] == .observed(.init(roomID: room.roomID, targetUserID: senderID, isOnline: false, expiresAt: base)))
            #expect(initial[wrongTarget] == .denied(.actorNotMember))
            #expect(initial[outsider] == .denied(.notDirectRoom))
            #expect(initial[missing] == .denied(.notDirectRoom))
            #expect(try await live.presenceBatch([], now: base).isEmpty)
            try await sql.raw("INSERT INTO im_v2.user_blocks (blocker_user_id,blocked_user_id,created_at) VALUES (\(bind:memberTwoUUID),\(bind:senderUUID),\(bind:base))").run()
            let blocked = try await live.presenceBatch([good, reverse], now: base)
            #expect(blocked[good] == .denied(.interactionBlocked))
            #expect(blocked[reverse] == .denied(.interactionBlocked))
            try await sql.raw("DELETE FROM im_v2.user_blocks WHERE blocker_user_id=\(bind:memberTwoUUID) AND blocked_user_id=\(bind:senderUUID)").run()
            try await sql.raw("INSERT INTO im_v2.user_live_activity_preferences (user_id,allows_online_presence,allows_typing_indicators,updated_at) VALUES (\(bind:memberTwoUUID),false,true,\(bind:base))").run()
            try await sql.raw("UPDATE im_v2.user_live_presence_leases SET expires_at='infinity'::timestamptz WHERE connection_id=\(bind:active)").run()
            let hidden = try await live.presenceBatch([good], now: base)
            #expect(hidden[good] == .observed(.init(roomID: room.roomID, targetUserID: peer, isOnline: false, expiresAt: base)))
            try await sql.raw("UPDATE im_v2.user_live_activity_preferences SET allows_online_presence=true WHERE user_id=\(bind:memberTwoUUID)").run()
            await #expect(throws: V2LiveActivityStoreError.corruptPersistenceState) {
                try await live.presenceBatch([good, reverse], now: base)
            }
            try await sql.raw("UPDATE im_v2.user_live_presence_leases SET expires_at=\(bind:base) WHERE connection_id=\(bind:active)").run()
            let offline = try await live.presenceBatch([good], now: base)
            #expect(offline[good] == .observed(.init(roomID: room.roomID, targetUserID: peer, isOnline: false, expiresAt: base)))
        }
    }
}

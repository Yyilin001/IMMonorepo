@testable import IMV2ServerInfrastructure
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2Core
import Foundation
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("unconfigured alerts stay pending, retries retain work, expiry never fakes delivery")
    func accountNotificationReservedDelivery() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { target, owner, sql, ownerSQL, room in
            let now = Date(), event = UUID()
            try await v2EnqueueMessageDispatch(eventID: event, messageID: UUID(), roomID: room.uuidValue!,
                roomSequence: 1, membershipRevision: 0, senderID: senderUUID,
                mentionedUserIDs: [], mentionsEveryone: false, createdAt: now, sql: ownerSQL)
            let source = PostgresV2RoomDispatchStore(database: owner)
            let sourceLease = try #require(try await source.claim(now: now, limit: 1).first)
            let projector = try PostgresV2UserStateEventProjector(database: target)
            _ = try await projector.projectRoomChange(sourceLease, to: .init(uuid: memberTwoUUID))
            let store = PostgresV2AccountNotificationStore(database: target)
            let disabled = try await V2AccountNotificationWorker(store: store, now: { now }).runOnce(limit: 8)
            #expect(disabled.claimed == 0 && disabled.completed == 0 && disabled.expired == 0)
            #expect(try await count("im_v2.account_notification_outbox WHERE claim_token IS NULL AND attempt=0", on: sql) == 1)
            let failure = try await V2AccountNotificationWorker(store: store,
                delivery: NotificationTestDelivery(outcome: .retry), now: { now }).runOnce(limit: 8)
            #expect(failure.retried == 1 && failure.completed == 0)
            #expect(try await store.claim(now: now, limit: 1).isEmpty)
            let retryTime = now.addingTimeInterval(3)
            let success = try await V2AccountNotificationWorker(store: store,
                delivery: NotificationTestDelivery(outcome: .accepted), now: { retryTime }).runOnce(limit: 8)
            #expect(success.completed == 1)
            // Lost source ACK cannot recreate a consumed alert or allocate a new personal sequence.
            #expect(try await projector.projectRoomChange(sourceLease, to: .init(uuid: memberTwoUUID)) == 1)
            #expect(try await count("im_v2.account_notification_outbox", on: sql) == 0)
            _ = try await projector.projectRoomChange(sourceLease, to: .init(uuid: memberThreeUUID))
            let expiryTime = now.addingTimeInterval(V2AccountNotificationLimits.lifetime + 1)
            let expired = try await V2AccountNotificationWorker(store: store, now: { expiryTime }).runOnce(limit: 8)
            #expect(expired.expired == 1 && expired.claimed == 0 && expired.completed == 0)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 2)
            #expect(try await count("im_v2.user_state_event_receipts", on: sql) == 2)
        }
    }

    @Test("notification lease expiry fences old completion and retention skips an active lease")
    func accountNotificationLeaseFences() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { target, owner, sql, ownerSQL, room in
            let now = Date()
            let created = now.addingTimeInterval(-V2AccountNotificationLimits.lifetime + 2)
            try await v2EnqueueMessageDispatch(eventID: UUID(), messageID: UUID(), roomID: room.uuidValue!,
                roomSequence: 1, membershipRevision: 0, senderID: senderUUID,
                mentionedUserIDs: [], mentionsEveryone: false, createdAt: created, sql: ownerSQL)
            let sourceLease = try #require(try await PostgresV2RoomDispatchStore(database: owner).claim(now: now, limit: 1).first)
            _ = try await PostgresV2UserStateEventProjector(database: target).projectRoomChange(sourceLease, to: .init(uuid: memberTwoUUID))
            let store = PostgresV2AccountNotificationStore(database: target)
            let lease = try #require(try await store.claim(now: now, limit: 1).first)
            #expect(try await store.claim(now: now, limit: 1).isEmpty)
            #expect(try await store.expire(now: now.addingTimeInterval(3), limit: 1) == 0)
            #expect(try await !store.complete(lease, now: now.addingTimeInterval(61)))
            #expect(try await store.expire(now: now.addingTimeInterval(61), limit: 1) == 1)
            #expect(try await count("im_v2.account_notification_outbox", on: sql) == 0)
        }
    }
}
private struct NotificationTestDelivery: V2AccountNotificationDelivering {
    let outcome: V2AccountNotificationOutcome
    func deliver(_ notification: V2AccountNotification) async throws -> V2AccountNotificationOutcome {
        #expect(notification.senderID != notification.userID)
        return outcome
    }
}

import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 special-account messaging")
struct V2SpecialAccountMessagingServiceTests {
    @Test("a trusted system-account request opens the direct room, sends as the account, and is audited")
    func trustedSystemMessageUsesTheServerOnlyPath() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let roomID = try RoomID("00000000-0000-0000-0000-000000000a01")
        let accountID = try UserID("00000000-0000-0000-0000-000000000a02")
        let customerID = try UserID("00000000-0000-0000-0000-000000000a03")
        let profile = try V2CapacityProfile(id: "standard", limits: .init(
            maxEligibleMembers: 10,
            maxCommandsPerWindow: 10,

            retryAfterSeconds: 1
        ))
        let roomAdmission = try RoomAdmissionState(
            eligibleMemberCount: 2,
            commandWindow: .init(limit: 10))
        let roomState = V2RoomCommandState(
            roomID: roomID,
            nextRoomSequence: 1,
            admission: roomAdmission
        )
        let shardState = try ShardAdmissionState(
            lease: .init(
                id: try .init("00000000-0000-0000-0000-000000000a04"),
                generation: 1,
                validUntil: now.addingTimeInterval(60),
                commandWindow: .init(limit: 10)))
        let specialStore = SpecialAccountStoreSpy(account: .init(userID: accountID, stableKey: "system_notice", kind: .system))
        let direct = try V2DirectMessagingService(
            store: DirectRoomStoreSpy(roomID: roomID),
            capacityProfile: profile,
            roomShardID: "rooms-primary",
            identifiers: .init(makeUUID: { UUID(uuidString: roomID.rawValue)! }),
            now: { now }
        )
        let messageStore = InMemoryV2RoomWriteStore(seed: [(roomState, shardState)], authorizedActors: [accountID])
        let messages = V2SendMessageService(
            store: messageStore,
            capacityProfile: profile,
            limits: try .init(maxUTF8Bytes: 64),
            now: { now }
        )
        let service = V2TrustedSpecialAccountMessagingService(
            store: specialStore,
            directMessaging: direct,
            messages: messages,
            now: { now }
        )
        let request = try V2TrustedSpecialAccountMessage(
            stableAccountKey: "system_notice",
            servicePrincipal: "notification-worker",
            operationID: try .init("00000000-0000-0000-0000-000000000a05"),
            requestFingerprint: "8b548c1791c509d9",
            customerUserID: customerID,
            text: "维护通知"
        )

        let outcome = try await service.send(request)

        guard case .accepted(let accepted) = outcome else {
            Issue.record("expected accepted special-account message")
            return
        }
        #expect(accepted.senderUserID == accountID)
        #expect(await specialStore.authorizedRoomID() == roomID)
        #expect(await specialStore.recordedMessageID() == accepted.messageID)
    }
}

private actor SpecialAccountStoreSpy: V2SpecialAccountMessagingStore {
    private let account: V2ResolvedSpecialAccount
    private var authorizedRoom: RoomID?
    private var recordedMessage: MessageID?

    init(account: V2ResolvedSpecialAccount) { self.account = account }

    func resolveActiveAccount(stableKey: String) async throws -> V2ResolvedSpecialAccount? {
        stableKey == account.stableKey ? account : nil
    }

    func authorizeOutbound(account: V2ResolvedSpecialAccount, roomID: RoomID, customerUserID _: UserID) async throws {
        guard account == self.account else { throw V2SpecialAccountMessagingError.deliveryDenied }
        authorizedRoom = roomID
    }

    func record(request _: V2TrustedSpecialAccountMessage, account _: V2ResolvedSpecialAccount, roomID _: RoomID, outcome: V2SendMessageOutcome, now _: Date) async throws {
        switch outcome {
        case .accepted, .idempotent: recordedMessage = outcome.acceptanceReceipt?.messageID
        case .idempotencyConflict, .rateLimited, .unavailable, .denied:
            throw V2SpecialAccountMessagingError.corruptPersistenceState
        }
    }

    func authorizedRoomID() -> RoomID? { authorizedRoom }
    func recordedMessageID() -> MessageID? { recordedMessage }
}

private actor DirectRoomStoreSpy: V2DirectMessagingStore {
    private let roomID: RoomID

    init(roomID: RoomID) { self.roomID = roomID }

    func open(command: V2OpenDirectRoomCommand, capacityProfile _: V2CapacityProfile, roomShardID _: String, roomID _: RoomID, now: Date) async throws -> V2OpenDirectRoomOutcome {
        .opened(.init(roomID: roomID, actorUserID: command.actorUserID, targetUserID: command.targetUserID, createdAt: now))
    }

    func setStrangerMessagePermission(command: V2SetStrangerMessagePermissionCommand, now: Date) async throws -> V2SetStrangerMessagePermissionOutcome {
        .idempotent(permission: command.permission, updatedAt: now)
    }

    func setUserAddPermission(command: V2SetUserAddPermissionCommand, now: Date) async throws -> V2SetUserAddPermissionOutcome {
        .idempotent(permission: command.permission, updatedAt: now)
    }
}

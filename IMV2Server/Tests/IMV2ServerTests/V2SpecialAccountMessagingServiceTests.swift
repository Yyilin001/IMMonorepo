@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("a trusted system-account request uses the proven direct owner and is audited")
    func trustedSystemMessageUsesTheServerOnlyPath() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, _, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let customer = UserID(uuid: memberTwoUUID)
            let specialStore = SpecialAccountStoreSpy(account: .init(userID: senderID, stableKey: "system_notice", kind: .system))
            let bootstrap = try V2RoomBootstrapDomainExecutor(shardID: "room-a",
                direct: PostgresV2DirectMessagingStore(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database), projectionDelivery: SuccessfulProjectionDelivery()), group: PostgresV2GroupMessagingStore(database: database),
                capacityProfile: profile, now: { now })
            let port = V2ActorCreationBootstrapPort(execute: { command, _ in try await bootstrap.execute(command) },
                stage: { intent, page, _ in try await bootstrap.stage(intent: intent, page: page) })
            let direct = PostgresV2DirectRoomOperationStore(database: database,
                routes: V2PostgresRoomShardRouter(database: database), selector: try .init(shardIDs: ["room-a"]), bootstrap: port)
            let messages = V2SendMessageService(store: PostgresV2RoomWriteStore(database: database),
                capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), now: { now })
            let service = V2TrustedSpecialAccountMessagingService(store: specialStore, directMessaging: direct, messages: messages, now: { now })
            let request = try V2TrustedSpecialAccountMessage(stableAccountKey: "system_notice", servicePrincipal: "notification-worker",
                operationID: .init(uuid: UUID()), requestFingerprint: "8b548c1791c509d9",
                firstSubmissionDeadlineMilliseconds: 1_750_000_600_000, customerUserID: customer, text: "维护通知")
            let outcome = try await service.send(request)
            guard case .accepted(let accepted) = outcome else { Issue.record("expected accepted special-account message"); return }
            #expect(accepted.senderUserID == senderID)
            #expect(await specialStore.authorizedRoomID() == accepted.roomID)
            #expect(await specialStore.recordedMessageID() == accepted.messageID)
        }
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

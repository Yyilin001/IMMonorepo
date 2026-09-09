import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2OutboxCancelledSocialTests {
    @Test("cancelled social actions do not enqueue or send", arguments: ["relationship", "block", "stranger", "user-add", "receipts"])
    func cancelledSocialAction(kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-app-cancelled-social-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        do {
            let transport = UnexpectedSocialTransport()
            let outbox = V2SocialCommandOutboxEngine(store: store, socialTransport: transport, directTransport: transport, readReceiptTransport: transport)
            let relationship = V2OutboxRelationshipChanger(outbox: outbox)
            let block = V2OutboxUserBlockChanger(outbox: outbox)
            let stranger = V2OutboxStrangerMessagePreferenceUpdater(outbox: outbox)
            let userAdd = V2OutboxUserAddPreferenceUpdater(outbox: outbox)
            let receipts = V2RealtimeReadReceiptPreferenceUpdater(outbox: outbox)
            let target = UserID(uuid: UUID())
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                switch kind {
                case "relationship": _ = try await relationship.changeRelationship(targetUserID: target.rawValue, action: .request)
                case "block": _ = try await block.changeBlock(targetUserID: target.rawValue, action: .block)
                case "stranger": _ = try await stranger.update(allowsStrangerMessages: false)
                case "user-add": _ = try await userAdd.update(allowsBeingAdded: false)
                default: _ = try await receipts.update(allowsDirectReadReceipts: false, allowsGroupReadReceipts: false)
                }
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.pendingSocialCommands().isEmpty)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }
}

private struct UnexpectedSocialTransport: V2ClientSocialRelationshipTransport, V2ClientDirectMessagingTransport, V2ClientReadReceiptTransport {
    private func unexpected<T>() throws -> T {
        Issue.record("cancelled social action must not reach transport")
        throw CancellationError()
    }
    func changeRelationship(operationID: RelationshipOperationID, targetUserID: UserID, action: V2RelationshipAction) async throws -> V2ClientRelationshipChange { try unexpected() }
    func changeUserBlock(operationID: UserBlockOperationID, targetUserID: UserID, action: V2UserBlockAction) async throws -> V2ClientUserBlockChange { try unexpected() }
    func openDirectRoom(operationID: DirectRoomOperationID, targetUserID: UserID) async throws -> V2ClientDirectRoom { try unexpected() }
    func setStrangerMessagePermission(operationID: StrangerMessagePreferenceOperationID, permission: V2StrangerMessagePermission) async throws -> Date { try unexpected() }
    func setUserAddPermission(operationID: UserAddPreferenceOperationID, permission: V2UserAddPermission) async throws -> Date { try unexpected() }
    func recordReadReceipt(roomID: RoomID, operationID: ReadReceiptOperationID, readThroughRoomSequence: UInt64) async throws -> V2ClientReadReceipt { try unexpected() }
    func setReadReceiptPreferences(operationID: ReadReceiptPreferenceOperationID, allowsDirectReadReceipts: Bool, allowsGroupReadReceipts: Bool) async throws -> V2ReadReceiptPreferences { try unexpected() }
    func listReadReceiptReaders(roomID: RoomID, messageID: MessageID, cursor: String?, pageSize: Int) async throws -> V2ReadReceiptReadersPage { try unexpected() }
}

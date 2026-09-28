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
        let account=UserID(uuid:UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()),userID:account)
        do {
            let service=V2SocialOperationService(accountID:account,store:store,client:UnexpectedSocialOperationClient())
            let preferences=V2AccountPreferenceService(accountID:account,store:store,client:UnexpectedAccountPreferenceClient())
            let relationship=V2OperationRelationshipChanger(service:service),block=V2OperationUserBlockChanger(service:service)
            let stranger=V2OperationStrangerMessagePreferenceUpdater(service:preferences)
            let userAdd=V2OperationUserAddPreferenceUpdater(service:preferences)
            let receipts=V2OperationReadReceiptPreferenceUpdater(service:preferences)
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
            #expect(try await store.dueOperationWork(now:Date(),limit:32).isEmpty)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }
}

private struct UnexpectedSocialOperationClient:V2SocialOperationClient {
    func baseline(targetUserID:UserID) async throws -> V2SocialOperationSnapshot { Issue.record("cancelled action read baseline");throw CancellationError() }
    func submit(_ command:V2SocialOperationCommand) async throws -> V2SocialOperationRecoveryResult { Issue.record("cancelled action submitted");throw CancellationError() }
    func recover(_ command:V2SocialOperationCommand,action:V2OperationRecoveryRequest.Action) async throws -> V2SocialOperationRecoveryResult { throw CancellationError() }
}

private struct UnexpectedAccountPreferenceClient:V2AccountPreferenceClient {
    func baseline(kind:V2OperationKind) async throws -> V2AccountPreferenceSnapshot { Issue.record("cancelled setting read baseline");throw CancellationError() }
    func submit(_ command:V2AccountPreferenceCommand) async throws -> V2AccountPreferenceRecoveryResult { Issue.record("cancelled setting submitted");throw CancellationError() }
    func recover(_ command:V2AccountPreferenceCommand,action:V2OperationRecoveryRequest.Action) async throws -> V2AccountPreferenceRecoveryResult { throw CancellationError() }
}

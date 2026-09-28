import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2OutboxCancelledMutationTests {
    @Test("already cancelled message mutations neither enqueue nor send", arguments: ["edit", "withdrawal", "reaction"])
    func cancelledMutation(kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-app-cancelled-mutation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account=UserID(uuid:UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()),userID:account)
        do {
            let room = RoomID(uuid: UUID())
            let message = MessageID(uuid: UUID())
            let remote=V2AppMessageWorkClient(rejectOld:false)
            let service=V2MessageMutationOperationService(accountID:account,store:store,client:remote)
            let editor=V2OperationMessageEditor(service:service)
            let withdrawer=V2OperationMessageWithdrawer(service:service)
            let reactionRemote=V2AppReactionClient(account:account)
            let reactor=V2OperationMessageReactionChanger(service:.init(accountID:account,store:store,client:reactionRemote))
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                switch kind {
                case "edit": _ = try await editor.edit(messageID: message.rawValue, in: room.rawValue, expectedMessageRevision: 1, text: "edited")
                case "withdrawal": _ = try await withdrawer.withdraw(messageID: message.rawValue, in: room.rawValue, expectedMessageRevision: 1)
                default: _ = try await reactor.changeReaction(messageID: message.rawValue, in: room.rawValue, reaction: "👍", action: .add)
                }
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.dueOperationWork(now:.distantFuture,kinds:[.editMessage,.withdrawMessage]).isEmpty)
            #expect(await remote.calls==0)
            #expect(try await store.nextReactionDraft(now:.distantFuture)==nil)
            #expect(await reactionRemote.calls==0)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }
}

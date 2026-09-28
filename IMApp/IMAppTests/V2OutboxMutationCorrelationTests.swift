import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2OutboxMutationCorrelationTests {
    @Test("withdrawal and reaction feedback belongs to the current operation", arguments: ["withdrawal", "reaction"], [false, true])
    func mutationCorrelation(kind: String, rejectOld: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-app-mutation-correlation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account=UserID(uuid:UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()),userID:account)
        do {
            let room = RoomID(uuid: UUID())
            let oldMessage = MessageID(uuid: UUID())
            let newMessage = MessageID(uuid: UUID())
            if kind == "withdrawal" {
                let remote=V2AppMessageWorkClient(rejectOld:rejectOld)
                let service=V2MessageMutationOperationService(accountID:account,store:store,client:remote)
                let olderID=try await service.enqueueWithdrawal(roomID:room,messageID:oldMessage,expectedRevision:1)
                let older=try #require(try await store.operationWork(id:olderID))
                guard case .claimed(let claim)=try await store.claimOperationWork(id:olderID,ownerID:UUID(),action:.submit,now:older.nextActionAt) else { throw V2OperationWorkError.invalidTransition }
                try await service.execute(claim)
                let adapter=V2OperationMessageWithdrawer(service:service)
                #expect(try await adapter.withdraw(messageID:newMessage.rawValue,in:room.rawValue,expectedMessageRevision:1) == .queuedForRetry)
                let current=try #require(try await store.dueOperationWork(now:.now,kinds:[.withdrawMessage]).first)
                #expect(current.id != olderID && current.execution == .prepared)
                #expect(try await store.operationWork(id:olderID)?.execution == (rejectOld ? .rejected : .committed))
                #expect(await remote.calls==1)
            } else {
                let remote=V2AppReactionClient(account:account,rejectOld:rejectOld)
                let service=V2MessageReactionOperationService(accountID:account,store:store,client:remote)
                let olderID=try await service.enqueue(roomID:room,messageID:oldMessage,reaction:"👍",targetState:.present)
                #expect(try await service.prepareNextIntent())
                let older=try #require(try await store.operationWork(id:olderID))
                guard case .claimed(let claim)=try await store.claimOperationWork(id:olderID,ownerID:UUID(),action:.submit,now:older.nextActionAt) else { throw V2OperationWorkError.invalidTransition }
                try await service.execute(claim)
                let adapter=V2OperationMessageReactionChanger(service:service)
                #expect(try await adapter.changeReaction(messageID:newMessage.rawValue,in:room.rawValue,reaction:"👍",action:.add) == .queuedForRetry)
                #expect(try await service.prepareNextIntent())
                let current=try #require(try await store.dueOperationWork(now:.now,kinds:[.reaction]).first)
                #expect(current.id != olderID && current.execution == .prepared)
                #expect(try await store.operationWork(id:olderID)?.execution == (rejectOld ? .rejected : .committed))
                #expect(await remote.submissions==1)

            }
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }
}

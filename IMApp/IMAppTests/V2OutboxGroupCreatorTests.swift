import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2OperationGroupCreatorTests {
    @Test("App saves a creation before any network call and restores the same pending ID")
    func durableBeforeNetwork() async throws {
        let f=try AppCreationFixture();defer { f.remove() }
        let result=try await f.creator.createConversation(title:"Group",initialMemberUserIDs:[])
        guard case .queuedForRetry(let id)=result else { Issue.record("Expected durable creation");return }
        #expect(try await f.creator.restoredCreationStatus() == .queuedForRetry(operationID:id))
        #expect(await f.remote.calls==0)
        #expect(try await f.creator.createConversation(title:"Group",initialMemberUserIDs:[])==result)
        try await f.store.close()
    }
    @Test("cancelled cancellation call preserves the creation without writing a cancel intent")
    func cancelledCancellationCall() async throws {
        let f=try AppCreationFixture();defer { f.remove() }
        let id=try await f.service.enqueue(title:"Group",members:[])
        let task=Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.creator.cancelConversationCreation(operationID:id.uuidString)
        }
        await #expect(throws:CancellationError.self) { _ = try await task.value }
        #expect(try await f.service.pending(id:id).cancellationRequested==false)
        #expect(try await f.creator.cancelConversationCreation(operationID:id.uuidString) == .queuedForRetry)
        #expect(try await f.service.pending(id:id).cancellationRequested)
        #expect(await f.remote.calls==0)
        try await f.store.close()
    }
    @Test("an unresolved original creation cannot be replaced by another title")
    func originalIdentityCannotBeReplaced() async throws {
        let f=try AppCreationFixture();defer { f.remove() }
        let id=try await f.service.enqueue(title:"Original",members:[])
        await #expect(throws:V2OperationWorkError.invalidTransition) {
            _ = try await f.creator.createConversation(title:"Different",initialMemberUserIDs:[])
        }
        #expect(try await f.creator.restoredCreationStatus() == .queuedForRetry(operationID:id.uuidString))
        #expect(await f.remote.calls==0)
        try await f.store.close()
    }
}
private struct AppCreationFixture {
    let url=FileManager.default.temporaryDirectory.appending(path:UUID().uuidString).appending(path:"state.sqlite")
    let store:GRDBV2LocalSyncStore,remote=UnusedCreationRemote(),service:V2GroupCreationOperationService,creator:V2OperationGroupConversationCreator
    init() throws {
        let account=UserID(uuid:UUID())
        store=try .init(databaseURL:url,installationBinding:.init(value:UUID()),userID:account)
        service = .init(accountID:account,store:store,client:remote)
        creator = .init(service:service)
    }
    func remove() { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
}
private actor UnusedCreationRemote:V2GroupCreationOperationClient {
    var calls=0
    func begin(_ intent:V2GroupCreationIntent) throws -> V2GroupCreationOperationResult { calls+=1;throw CancellationError() }
    func append(_ page:V2GroupCreationAppendRequest) throws -> V2GroupCreationOperationResult { calls+=1;throw CancellationError() }
    func finalize(_ intent:V2GroupCreationIntent) throws -> V2GroupCreationOperationResult { calls+=1;throw CancellationError() }
    func recover(_ intent:V2GroupCreationIntent,action:V2OperationRecoveryRequest.Action) throws -> V2GroupCreationOperationResult { calls+=1;throw CancellationError() }
}

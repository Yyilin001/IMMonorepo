import Foundation
import GRDB
import SwiftUI
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


@MainActor
@Suite("Direct chat waits for its own durable confirmation", .timeLimit(.minutes(1)))
struct V2OperationDirectConversationOpenerTests {
    @MainActor @Test("a contact opens a durable local chat immediately without server confirmation")
    func localFirstOpenDoesNotWaitForReceipt() async throws {
        let f = try DirectOpenFixture(); defer { f.remove() }
        let commandAccount = try await f.store.databasePool.read { db in
            try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1")!
        }
        let source = V2GRDBConversationDataSource(localStore: f.store, requestLatestVisible: { _ in })
        let conversations = V2ConversationListStore(environment: .init(userID: commandAccount,
            projections: .init(dataSource: source), discovery: .init(directConversationOpener: f.opener)))
        let destination = try #require(await conversations.openLocalFirstDirectConversation(with: f.peer))
        guard case .localDirect(let route) = destination else { Issue.record("Expected a local destination"); return }
        #expect(try await f.service.receipt(id: route.operationID) == nil)
        #expect(await conversations.openLocalFirstDirectConversation(with: f.peer) == destination)
        let navigation = V2RootNavigationStore()
        navigation.path.append(V2ContactsRoute.contact(f.peer.userID.rawValue))
        navigation.showConversation(destination)
        var expected = NavigationPath(); expected.append(route)
        #expect(navigation.selectedTab == .conversations && navigation.path == expected)
        let local = V2LocalDirectConversationStore(operationID: route.operationID, service: f.service, conversations: conversations)
        local.draft = "written before connection"
        await local.send()
        #expect(local.draft.isEmpty)
        #expect(try await f.service.localMessages(workID: route.operationID).map(\.text) == ["written before connection"])
        try await f.store.close()
    }

    @Test("a queued click waits and returns the confirmed room, ignoring an older receipt")
    func waitsForExactRequest() async throws {
        let f = try DirectOpenFixture(); defer { f.remove() }
        let room = RoomID(uuid: UUID())
        let oldID = try await f.service.enqueue(publicIdentity: f.peer)
        try await f.complete(oldID, outcome: .opened(roomID: room, createdAtMilliseconds: 1_750_000_000_000))
        var returned = false
        let opening = Task { let room = try await f.opener.openConversation(with: f.peer); returned = true; return room }
        let request = try await f.pending()
        #expect(request.work.id != oldID)
        #expect(!returned)
        try await f.complete(request.work.id, outcome: .opened(roomID: room, createdAtMilliseconds: 1_750_000_000_000))
        #expect(try await opening.value == room.rawValue)
        #expect(returned)
        try await f.store.close()
    }

    @Test("timeout retains the same original request for a later click")
    func timeoutPreservesRequest() async throws {
        let f = try DirectOpenFixture(); defer { f.remove() }
        let opener = V2OperationDirectConversationOpener(service: f.service, confirmationTimeout: .milliseconds(30))
        var ids: [UUID] = []
        for _ in 0..<2 {
            do { _ = try await opener.openConversation(with: f.peer); Issue.record("Expected timeout") }
            catch V2DirectConversationOpeningState.queued(let id) { ids.append(id) }
        }
        #expect(ids.count == 2 && ids[0] == ids[1])
        let request = try await f.pending()
        #expect(request.work.id == ids.first && !request.work.execution.isTerminal)
        try await f.store.close()
    }

    @Test("leaving the profile cancels its waiter without cancelling the durable request")
    func cancellationStopsNavigation() async throws {
        let f = try DirectOpenFixture(); defer { f.remove() }
        let opening = Task { try await f.opener.openConversation(with: f.peer) }
        let request = try await f.pending()
        opening.cancel()
        await #expect(throws: CancellationError.self) { _ = try await opening.value }
        #expect(try await f.store.operationWork(id: request.work.id)?.execution.isTerminal == false)
        try await f.store.close()
    }

    @Test("a closed result ends the wait without producing a chat destination")
    func closedResult() async throws {
        let f = try DirectOpenFixture(); defer { f.remove() }
        let opening = Task { try await f.opener.openConversation(with: f.peer) }
        let request = try await f.pending()
        try await f.complete(request.work.id, outcome: .closed)
        do { _ = try await opening.value; Issue.record("Closed request must not navigate") }
        catch V2DirectConversationOpeningState.expired { }
        try await f.store.close()
    }
}

private struct DirectOpenFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "direct-open-\(UUID())")
    let store: GRDBV2LocalSyncStore
    let service: V2DirectRoomOperationService
    let peer: V2PublicIdentity
    var opener: V2OperationDirectConversationOpener { .init(service: service) }

    init() throws {
        let actor = UserID(uuid: UUID())
        store = try .init(databaseURL: root.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()), userID: actor)
        service = .init(accountID: actor, store: store, client: UnusedDirectOpenRemote())
        peer = try .init(userID: .init(uuid: UUID()), handle: .init("direct_peer"), displayName: "Peer", accountKind: .regular)
    }
    func pending() async throws -> V2DirectRoomPending {
        for try await values in await service.updates() {
            if let request = values.first(where: { !$0.work.execution.isTerminal }) { return request }
        }
        throw V2OperationWorkError.invalidRecord
    }
    func complete(_ id: UUID, outcome: V2DirectRoomOperationTerminalOutcome) async throws {
        guard case .claimed = try await store.claimOperationWork(id: id, ownerID: UUID(), action: .submit, now: .now) else {
            throw V2OperationWorkError.invalidTransition
        }
        let command = try await store.directRoomCommand(workID: id)
        let receipt = try V2DirectRoomOperationReceipt(identity: command.identity, fingerprint: command.fingerprint,
            outcome: outcome, resolvedAtMilliseconds: 1_750_000_000_001)
        try await store.completeDirectRoom(receipt, workID: id)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct UnusedDirectOpenRemote: V2DirectRoomOperationClient {
    func submit(_ command: V2DirectRoomOperationCommand) async throws -> V2DirectRoomOperationResult { throw CancellationError() }
    func recover(_ command: V2DirectRoomOperationCommand, action: V2OperationRecoveryRequest.Action) async throws -> V2DirectRoomOperationResult { throw CancellationError() }
}

#if canImport(Network) && canImport(Security)
import Foundation
import GRDB
import Network
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Durable message recovery and dispatcher ownership", .serialized, .timeLimit(.minutes(1)))
struct V2NetworkCommandRetryTests {
    @Test("dispatcher shutdown drains work and restart keeps original TCP operation identities")
    func quietRetryAndStoppedRecovery() async throws {
        let root=FileManager.default.temporaryDirectory.appending(path:"message-network-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let account=UserID(uuid:UUID()),binding=V2LocalInstallationBinding(value:UUID())
        let url=root.appending(path:"state.sqlite"),store=try GRDBV2LocalSyncStore(databaseURL:url,installationBinding:binding,userID:account)
        let remote=MessageRetryFixture(),owner=V2AccountRuntime()
        let first=try MessageRetryActivities(store:store,account:account,remote:remote,owner:owner)
        do {
            let firstWorkIDs = try await first.enqueuePair()
            await owner.startActivity(id:"messages") { try await first.dispatcher.run() }
            try await eventually { try await Self.allCommitted(firstWorkIDs, in: store) }
            #expect(await remote.submissions==2)
            #expect(await remote.recoveries==2)
            let secondWorkIDs = try await first.enqueuePair()
            try await eventually { await remote.submissions==4 }
            await owner.close()
            let calls=await remote.totalCalls
            try await Task.sleep(for:.milliseconds(100))
            #expect(await remote.totalCalls==calls)
            try await store.close()
            let restored=try GRDBV2LocalSyncStore(databaseURL:url,installationBinding:binding,userID:account)
            let newOwner=V2AccountRuntime()
            let next=try MessageRetryActivities(store:restored,account:account,remote:remote,owner:newOwner,now:{Date().addingTimeInterval(60)})
            await newOwner.startActivity(id:"messages") { try await next.dispatcher.run() }
            try await eventually { try await Self.allCommitted(firstWorkIDs + secondWorkIDs, in: restored) }
            #expect(await remote.submissions==4)
            #expect(await remote.recoveries==4)
            #expect(await remote.identities.count==4)
            await newOwner.close();try await restored.close()
        } catch {
            await owner.close();try? await store.close();throw error
        }
    }
    private static func allCommitted(_ ids: [UUID], in store: GRDBV2LocalSyncStore) async throws -> Bool {
        for id in ids {
            guard try await store.operationWork(id: id)?.execution == .committed else { return false }
        }
        return true
    }
    private func eventually(_ predicate:@Sendable () async throws -> Bool) async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while try await !predicate() {
            guard ContinuousClock.now<deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for:.milliseconds(10))
        }
    }
}
private struct MessageRetryActivities:Sendable {
    let store:GRDBV2LocalSyncStore,send:V2MessageSendOperationService,mutation:V2MessageMutationOperationService,dispatcher:V2OperationWorkDispatcher
    let room=RoomID(uuid:UUID())
    init(store:GRDBV2LocalSyncStore,account:UserID,remote:MessageRetryFixture,owner:V2AccountRuntime,now:@escaping @Sendable ()->Date=Date.init) throws {
        self.store=store
        send = .init(accountID:account,store:store,client:remote)
        mutation = .init(accountID:account,store:store,client:try V2HTTPMessageMutationOperationClient(baseURL:URL(string:"https://account.example")!,credentials:remote,transport:remote))
        let send=self.send,mutation=self.mutation
        dispatcher = .init(store:store,handlers:[.init(kind:.sendMessage){try await send.execute($0)},.init(kind:.editMessage){try await mutation.execute($0)}],ownerID:owner.ownerID,now:now)
    }
    func enqueuePair() async throws -> [UUID] {
        let id=try await send.enqueueMessage(roomID:room,text:"durable send")
        _ = try await store.handOffSendIntent(id)
        let rawSendWorkID = try await store.databasePool.read { db in
            try String.fetchOne(db, sql: "SELECT work_id FROM v2_send_intents WHERE intent_id=?", arguments: [id.uuidString])
        }
        let sendWorkID = try #require(rawSendWorkID.flatMap(UUID.init(uuidString:)))
        let editWorkID = try await mutation.enqueueEdit(roomID:room,messageID:.init(uuid:UUID()),expectedRevision:1,text:"durable edit")
        return [sendWorkID, editWorkID]
    }
}
private actor MessageRetryFixture:V2MessageSendOperationClient,V2ClientMediaEdgeCredentialProvider,V2ClientMediaEdgeHTTPTransport {
    var submissions=0,recoveries=0,totalCalls=0
    var identities=Set<String>()
    var sends:[String:V2MessageSendOperationReceipt]=[:],mutations:[String:V2MessageMutationReceipt]=[:]
    func mediaEdgeCredentials() throws -> V2ClientMediaEdgeCredentials { try .init(accessToken:"fixture",deviceID:.init("fixture-device")) }
    func submit(_ command: V2MessageSendOperationCommand) throws -> V2MessageSendOperationRecoveryResult {
        totalCalls += 1; submissions += 1
        let key = try command.identity.storageKey
        identities.insert(key)
        sends[key] = try .init(identity: command.identity, fingerprint: command.fingerprint,
            outcome: .accepted(.init(messageID: .init(uuid: UUID()), roomSequence: 1)),
            resolvedAtMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000))
        throw V2MessageSendTransportError.outcomeUnknown
    }
    func recover(_ request: V2MessageSendOperationRecoveryRequest) throws -> V2MessageSendOperationRecoveryResult {
        totalCalls += 1; recoveries += 1
        return .receipt(try #require(sends[request.identity.storageKey]))
    }
    func data(for request:URLRequest) async throws -> (Data,HTTPURLResponse) {
        totalCalls += 1
        let body=try #require(request.httpBody),url=try #require(request.url)
        let decoder=JSONDecoder(),encoder=JSONEncoder()
        let output:Data,status:Int
        if url.path.hasSuffix("/edit") {
            let command=try decoder.decode(V2MessageEditOperationCommand.self,from:body),key=try command.identity.storageKey
            identities.insert(key);submissions += 1
            mutations[key]=try .init(identity:command.identity,fingerprint:command.fingerprint,outcome:.committed(.init(messageID:command.messageID,messageRevision:2,roomSequence:2,eventID:.init(uuid:UUID()))),resolvedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1_000))
            output=Data();status=503
        } else if url.path.contains("message-mutations") {
            recoveries += 1
            let query=try decoder.decode(V2MessageMutationRecoveryRequest.self,from:body)
            output=try encoder.encode(V2MessageMutationRecoveryResult.receipt(#require(mutations[query.identity.storageKey])));status=200
        } else { throw V2MessageSendTransportError.invalidResponse }

        return (output,HTTPURLResponse(url:url,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json","Retry-After":"1"])!)
    }
}
#endif

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import IMV2Core
@testable import IMV2ClientKit

@Suite("Bound message HTTP backpressure")
struct V2MessageDeferredTests {
    @Test("HTTP floor survives SQLite restart and explicit continuation",arguments:[120,90_000])
    func mutationFloor(seconds:Int) async throws {
        let f=try MutationWorkFixture();defer { f.remove() }
        let transport=MessageDeferredTransport(seconds:seconds)
        let client=try V2HTTPMessageMutationOperationClient(baseURL:URL(string:"https://account.invalid")!,credentials:transport,transport:transport)
        let service=V2MessageMutationOperationService(accountID:f.account,store:f.store,client:client)
        let id=try await f.store.enqueueMessageMutation(f.edit(message:f.message,text:"frozen"))
        let before=Date()
        try await service.execute(f.claim(id))
        let work=try #require(try await f.store.operationWork(id:id))
        #expect(work.execution == .awaitingConfirmation)
        #expect(work.nextActionAt >= before.addingTimeInterval(Double(seconds)-1))
        try await f.store.close()
        let reopened=try GRDBV2LocalSyncStore(databaseURL:f.url,installationBinding:f.binding,userID:f.account)
        try await reopened.retryOperationWorkByUser(id:id,now:Date())
        #expect(try await reopened.operationWork(id:id)?.nextActionAt == work.nextActionAt)
        #expect(try await reopened.dueOperationWork(now:before.addingTimeInterval(30),kinds:[.editMessage]).isEmpty)
        try await reopened.close()
    }
    @Test("send adapter returns the maximum bound body and HTTP floor")
    func sendFloor() async throws {
        let f=try SendWorkFixture();defer { f.remove() }
        let service=V2MessageSendOperationService(accountID:f.account,store:f.store,client:f.remote)
        let id=try await service.enqueueMessage(roomID:f.room,text:"frozen")
        _ = try await f.store.handOffSendIntent(id)
        let work=try #require(try await f.store.dueOperationWork(now:.now,kinds:[.sendMessage]).first)
        let command=try await f.store.messageSendCommand(workID:work.id)
        let transport=MessageDeferredTransport(seconds:120)
        let client=try V2HTTPMessageSendOperationClient(baseURL:URL(string:"https://account.invalid")!,credentials:transport,transport:transport)
        guard case .deferred(let hint)=try await client.submit(command) else { Issue.record("expected hint");return }
        #expect(hint.retryAfterMilliseconds == 120_000)
        #expect(try hint.validates(identity:command.identity,fingerprint:command.fingerprint))
        try await f.store.close()
    }
}
private actor MessageDeferredTransport:V2ClientMediaEdgeCredentialProvider,V2ClientMediaEdgeHTTPTransport {
    let seconds:Int
    init(seconds:Int) { self.seconds=seconds }
    func mediaEdgeCredentials() throws -> V2ClientMediaEdgeCredentials { try .init(accessToken:"fixture",deviceID:.init("fixture-device")) }
    func data(for request:URLRequest) async throws -> (Data,HTTPURLResponse) {
        let body=try #require(request.httpBody),url=try #require(request.url)
        let identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,isSend=url.path.hasSuffix("/send")
        if isSend { let command=try JSONDecoder().decode(V2MessageSendOperationCommand.self,from:body);identity=try command.identity;fingerprint=try command.fingerprint }
        else { let command=try JSONDecoder().decode(V2MessageEditOperationCommand.self,from:body);identity=try command.identity;fingerprint=try command.fingerprint }
        let hint=try V2MessageOperationRetryHint(identity:identity,fingerprint:fingerprint,reason:.rateLimited,retryAfterMilliseconds:1_000)
        let output = isSend ? try JSONEncoder().encode(V2MessageSendOperationRecoveryResult.deferred(hint)) : try JSONEncoder().encode(V2MessageMutationRecoveryResult.deferred(hint))
        return (output,try #require(HTTPURLResponse(url:url,statusCode:429,httpVersion:nil,headerFields:["Content-Type":"application/json","Retry-After":String(seconds)])))
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import IMV2Core
@testable import IMV2ClientKit

@Suite("Frozen forward HTTP boundaries")
struct V2HTTPForwardPlanOperationClientTests {
    @Test("recovery carries full frozen manifest and explicit action without network authority in headers")
    func frozenRecovery() async throws {
        let f=try DurableForwardFixture();defer { f.remove() }
        let wire=ForwardHTTPWire(seconds:0)
        let client=try V2HTTPForwardPlanOperationClient(baseURL:URL(string:"https://account.invalid")!,credentials:wire,transport:wire)
        #expect(try await client.recover(f.command,action:.cancelRemaining) == .unresolved)
        let request=try #require(await wire.request)
        #expect(request.url?.path=="/v2/forward-plans/operations/recover")
        #expect(request.httpMethod=="POST" && request.value(forHTTPHeaderField:"Cache-Control")=="no-store")
        let body=try JSONDecoder().decode(V2ForwardPlanRecoveryRequest.self,from:try #require(request.httpBody))
        #expect(body.command==f.command && body.action == .cancelRemaining)
        #expect(request.value(forHTTPHeaderField:"firstSubmissionDeadlineMilliseconds")==nil)
    }
    @Test("body and HTTP cooldown floor survive restart and explicit continuation",arguments:[120,90_000])
    func durableFloor(seconds:Int) async throws {
        let f=try DurableForwardFixture();defer { f.remove() }
        let store=try f.open(),wire=ForwardHTTPWire(seconds:seconds)
        let client=try V2HTTPForwardPlanOperationClient(baseURL:URL(string:"https://account.invalid")!,credentials:wire,transport:wire)
        let service=V2ForwardPlanOperationService(accountID:f.user,store:store,client:client)
        let id=try await store.enqueueForwardPlanOperation(f.command)
        guard case .claimed(let claim)=try await store.claimOperationWork(id:id,ownerID:UUID(),action:.submit,now:Date()) else { throw V2OperationWorkError.invalidTransition }
        let before=Date()
        try await service.execute(claim)
        let work=try #require(try await store.operationWork(id:id))
        #expect(work.execution == .awaitingConfirmation && work.scheduling == .needsAttention)
        #expect(work.nextActionAt>=before.addingTimeInterval(Double(seconds)-1))
        try await store.close()
        let reopened=try f.open()
        try await reopened.retryOperationWorkByUser(id:id,now:Date())
        #expect(try await reopened.operationWork(id:id)?.nextActionAt==work.nextActionAt)
        #expect(try await reopened.dueOperationWork(now:before.addingTimeInterval(30),kinds:[.forwardMessage]).isEmpty)
        try await reopened.close()
    }
}
private actor ForwardHTTPWire:V2ClientMediaEdgeCredentialProvider,V2ClientMediaEdgeHTTPTransport {
    let seconds:Int
    private(set) var request:URLRequest?
    init(seconds:Int) { self.seconds=seconds }
    func mediaEdgeCredentials() throws -> V2ClientMediaEdgeCredentials { try .init(accessToken:"fixture",deviceID:.init("fixture-device")) }
    func data(for request:URLRequest) async throws -> (Data,HTTPURLResponse) {
        self.request=request
        let body=try #require(request.httpBody),url=try #require(request.url)
        let command=try url.path.hasSuffix("/submit") ? JSONDecoder().decode(V2ForwardPlanOperationCommand.self,from:body) : JSONDecoder().decode(V2ForwardPlanRecoveryRequest.self,from:body).command
        let result:V2ForwardPlanRecoveryResult=seconds==0 ? .unresolved : .deferred(try .init(identity:command.identity,fingerprint:command.fingerprint,reason:.rateLimited,retryAfterMilliseconds:1_000))
        return (try JSONEncoder().encode(result),try #require(HTTPURLResponse(url:url,statusCode:seconds==0 ? 200 : 429,httpVersion:nil,headerFields:["Content-Type":"application/json","Retry-After":String(seconds)])))
    }
}

import Foundation
import Testing
import IMV2Core
@testable import IMV2ClientKit

struct V2HTTPNameOperationClientTests {
    let endpoint = URL(string: "https://account.invalid/v2/profile-presentations")!
    @Test func typedRoutesKeepDeadlineLocalAndOriginalIdentityAcrossRecovery() async throws {
        let owner = try UserID("owner"), target = try UserID("friend")
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        let command = try V2ContactAliasUpdateCommand(ownerUserID: owner, targetUserID: target, operationID: .init("operation"), expectedRevision: nil, remarkName: "Name", firstSubmissionDeadlineMilliseconds: 9_000_000_000_000)
        let receipt = try V2ContactAliasUpdateReceipt(identity: command.identity, fingerprint: command.fingerprint,
            outcome: .committed(.init(ownerUserID: owner, targetUserID: target, remarkName: "Name", revision: .init(rawValue: 1)!)), resolvedAtMilliseconds: 1)
        let transport = NameHTTPTransport(bodies: [
            try JSONEncoder().encode(V2ContactAliasSnapshot(ownerUserID: owner, targetUserID: target, value: nil)),
            try JSONEncoder().encode(receipt), try JSONEncoder().encode(V2ContactAliasRecoveryResult.receipt(receipt))])
        let client = try V2HTTPNameOperationClient(endpoint: endpoint, credentials: NameHTTPCredentials(deadline: deadline), transport: transport)
        #expect(try await client.contactSnapshot(owner: owner, target: target).value == nil)
        #expect(try await client.submit(command) == receipt)
        #expect(try await client.recover(V2ContactAliasRecoveryRequest(identity: command.identity, fingerprint: command.fingerprint, action: .query)) == .receipt(receipt))
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET","PUT","POST"])
        #expect(requests[0].url?.path == "/v2/profile-presentations/contact-aliases/friend")
        #expect(requests[2].url?.path == "/v2/profile-presentations/contact-aliases/friend/operations/recover")
        #expect(try JSONDecoder().decode(V2ContactAliasUpdateCommand.self, from: #require(requests[1].httpBody)) == command)
        #expect(requests.allSatisfy { V2HTTPRequestDeadline.deadline(for: $0) == deadline })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cache-Control") == "no-store" })
        #expect(requests.allSatisfy { $0.allHTTPHeaderFields?.keys.contains(where: { $0.lowercased().contains("deadline") }) == false })
    }
    @Test func ownNicknameBaselineAndReceiptAreBoundToActorAndRoom() async throws {
        let actor = try UserID("owner"), room = try RoomID("room")
        let command = try V2GroupNicknameUpdateCommand(actorUserID: actor, roomID: room, operationID: .init("operation"), expectedRevision: nil, nickname: nil, firstSubmissionDeadlineMilliseconds: 9_000_000_000_000)
        let wrong = try V2GroupNicknameSnapshot(actorUserID: .init("other"), roomID: room, value: nil)
        let receipt = try V2GroupNicknameUpdateReceipt(identity: command.identity, fingerprint: command.fingerprint, outcome: .closed, resolvedAtMilliseconds: 1)
        let transport = NameHTTPTransport(bodies: [try JSONEncoder().encode(wrong), try JSONEncoder().encode(receipt), try JSONEncoder().encode(V2GroupNicknameRecoveryResult.receipt(receipt))])
        let client = try V2HTTPNameOperationClient(endpoint: endpoint, credentials: NameHTTPCredentials(), transport: transport)
        await #expect(throws: V2OperationWorkError.identityConflict) { try await client.groupSnapshot(actor: actor, room: room) }
        #expect(try await client.submit(command) == receipt)
        #expect(try await client.recover(V2GroupNicknameRecoveryRequest(identity: command.identity, fingerprint: command.fingerprint, action: .closeIfAbsent)) == .receipt(receipt))
        let requests = await transport.requests
        #expect(requests[1].url?.path == "/v2/profile-presentations/groups/room/nickname")
        #expect(requests[2].url?.path == "/v2/profile-presentations/groups/room/nickname/operations/recover")
    }
    @Test func overloadRetainsRetryAdviceWithoutImplicitReplay() async throws {
        let transport = NameHTTPTransport(bodies: [Data()], status: 503, headers: ["Retry-After":"30"])
        let client = try V2HTTPNameOperationClient(endpoint: endpoint, credentials: NameHTTPCredentials(), transport: transport)
        do { _ = try await client.groupSnapshot(actor: .init("owner"), room: .init("room")); Issue.record("expected failure") }
        catch let failure as V2HTTPFailure { #expect(failure.statusCode == 503); #expect(failure.retryAfter != nil) }
        #expect(await transport.requests.count == 1)
    }
}
private struct NameHTTPCredentials: V2ClientPushEndpointCredentialProvider {
    var deadline: ContinuousClock.Instant? = nil
    func pushEndpointCredentials() -> V2ClientPushEndpointCredentials { .init(accessToken: "test", deviceID: .init(uuid: UUID()), requestDeadline: deadline) }
}
private actor NameHTTPTransport: V2ClientPushEndpointHTTPTransport {
    var bodies: [Data]
    let status: Int
    let headers: [String:String]
    var requests: [URLRequest] = []
    init(bodies: [Data], status: Int = 200, headers: [String:String] = ["Content-Type":"application/json"]) { self.bodies = bodies; self.status = status; self.headers = headers }
    func data(for request: URLRequest) -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (bodies.removeFirst(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

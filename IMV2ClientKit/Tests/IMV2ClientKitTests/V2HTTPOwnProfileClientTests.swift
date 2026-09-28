import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 HTTP own profile client")
struct V2HTTPOwnProfileClientTests {
    @Test("production own-profile reads share credentials and transport while subscribers cancel independently")
    func mergedOwnProfileRead() async throws {
        let user = UserID(uuid: UUID())
        let profile = try V2ProfileView(userID: user, publicIdentity: .init(userID: user, handle: .init("profile_read"), displayName: "Name", accountKind: .regular),
            avatar: nil, state: .active, revision: .init(rawValue: 1)!, visibilityRevision: .init(rawValue: 1)!)
        let endpoint = URL(string: "https://account.invalid/v2/profile/me")!
        let response = HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let transport = SharedOwnProfileTransport(value: (try JSONEncoder().encode(profile), response))
        let queries = V2QueryCoordinator<V2ProfileView>()
        let credentials = SharedOwnProfileCredentials()
        let client = try V2HTTPOwnProfileClient(endpoint: endpoint, credentials: credentials, transport: transport,
            queries: queries, queryScope: .init(accountID: user.rawValue, authorizationDomain: "self", activationID: UUID()))
        let a = Task { try await client.currentProfile() }
        for _ in 0..<10000 { if await transport.count() == 1 { break }; await Task.yield() }
        let b = Task { try await client.currentProfile() }
        for _ in 0..<10000 { if await queries.snapshot().subscribers == 2 { break }; await Task.yield() }
        #expect(await queries.snapshot().subscribers == 2)
        a.cancel()
        await #expect(throws: CancellationError.self) { _ = try await a.value }
        #expect(await transport.count() == 1)
        #expect(await credentials.count() == 1)
        await transport.complete()
        #expect(try await b.value == profile)
        await queries.closeAndDrain()
    }
    @Test("patch preserves unchanged avatar and matches original receipt")
    func patchAndRecovery() async throws {
        let endpoint = URL(string: "https://account.invalid/v2/profile/me")!
        let actor = UserID(uuid: UUID())
        let command = try V2ProfileUpdateCommand(actorUserID: actor, operationID: .init(uuid: UUID()), expectedRevision: .init(rawValue: 4)!, patch: .init(displayName: .set("New name")), firstSubmissionDeadlineMilliseconds: 9999999999999)
        let receipt = try V2ProfileOperationReceipt(actorUserID: actor, operationID: command.operationID, fingerprint: command.fingerprint, outcome: .committed(revision: .init(rawValue: 5)!, visibilityRevision: .init(rawValue: 5)!), resolvedAtMilliseconds: 1)
        let response = HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
        let transport = OwnProfileHTTPTransport(responses: [(try JSONEncoder().encode(V2ProfileUpdateResult(receipt: receipt, currentSnapshot: nil)), response), (try JSONEncoder().encode(V2ProfileOperationRecoveryResult.receipt(receipt, currentSnapshot: nil)), response)])
        let client = try V2HTTPOwnProfileClient(endpoint: endpoint, credentials: OwnProfileCredentials(), transport: transport)
        #expect(try await client.patchProfile(command).receipt == receipt)
        #expect(try await client.recoverProfile(.init(actorUserID: actor, operationID: command.operationID, fingerprint: command.fingerprint, action: .query)) == .receipt(receipt, currentSnapshot: nil))
        let requests = await transport.requests()
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "PUT")
        #expect(requests[1].url?.path == "/v2/profile/me/operations/recover")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cache-Control") == "no-store" })
        let payload = try #require(requests[0].httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: payload) as? [String:Any])
        #expect(body["first_submission_deadline_ms"] as? UInt64 == command.firstSubmissionDeadlineMilliseconds)
        let encodedPatch = try JSONSerialization.data(withJSONObject: body["patch"]!)
        #expect(try JSONDecoder().decode(V2ProfilePatch.self, from: encodedPatch).avatar == .unchanged)
    }
    @Test("503 preserves retry advice and is not terminal rejection")
    func preservesStatus() async throws {
        let endpoint = URL(string: "https://account.invalid/v2/profile/me")!
        let response = HTTPURLResponse(url: endpoint, statusCode: 503, httpVersion: nil, headerFields: ["Retry-After":"30"])!
        let client = try V2HTTPOwnProfileClient(endpoint: endpoint, credentials: OwnProfileCredentials(), transport: OwnProfileHTTPTransport(responses: [(Data(),response)]))
        do { _ = try await client.currentProfile(); Issue.record("must fail") }
        catch let error as V2HTTPFailure { #expect(error.statusCode == 503); #expect(error.retryAfter != nil); #expect(error.certainty == .responseReceived) }
    }
    @Test("401 refresh result preserves a retryable request boundary")
    func distinguishes401From403() async throws {
        let endpoint = URL(string: "https://account.invalid/v2/profile/me")!
        let unauthorized = HTTPURLResponse(url: endpoint,statusCode: 401,httpVersion: nil,headerFields: [:])!
        let forbidden = HTTPURLResponse(url: endpoint,statusCode: 403,httpVersion: nil,headerFields: [:])!
        let client = try V2HTTPOwnProfileClient(endpoint: endpoint,credentials: OwnProfileCredentials(),transport: OwnProfileHTTPTransport(responses: [(Data(),unauthorized),(Data(),forbidden)]))
        await #expect(throws: V2OwnProfileClientError.authorizationUnavailable) { try await client.currentProfile() }
        await #expect(throws: V2OwnProfileClientError.authorizationDenied) { try await client.currentProfile() }
    }
    @Test("receipt for another operation is rejected")
    func rejectsMismatchedReceipt() async throws {
        let endpoint = URL(string: "https://account.invalid/v2/profile/me")!
        let actor = UserID(uuid: UUID())
        let command = try V2ProfileUpdateCommand(actorUserID: actor, operationID: .init(uuid: UUID()), expectedRevision: .init(rawValue: 1)!, patch: .init(displayName: .set("New name")), firstSubmissionDeadlineMilliseconds: 9999999999999)
        let receipt = try V2ProfileOperationReceipt(actorUserID: actor, operationID: .init(uuid: UUID()), fingerprint: command.fingerprint, outcome: .closed, resolvedAtMilliseconds: 1)
        let response = HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
        let client = try V2HTTPOwnProfileClient(endpoint: endpoint, credentials: OwnProfileCredentials(), transport: OwnProfileHTTPTransport(responses: [(try JSONEncoder().encode(V2ProfileUpdateResult(receipt: receipt,currentSnapshot: nil)),response)]))
        await #expect(throws: V2OwnProfileClientError.invalidResponse) { try await client.patchProfile(command) }
    }
}
private struct OwnProfileCredentials: V2ClientPushEndpointCredentialProvider {
    func pushEndpointCredentials() async throws -> V2ClientPushEndpointCredentials { .init(accessToken: "access-token", deviceID: .init(uuid: UUID())) }
}
private actor OwnProfileHTTPTransport: V2ClientPushEndpointHTTPTransport {
    private var pending: [(Data, HTTPURLResponse)]
    private var recorded: [URLRequest] = []
    init(responses: [(Data, HTTPURLResponse)]) { pending = responses }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) { recorded.append(request); return pending.removeFirst() }
    func requests() -> [URLRequest] { recorded }
}

private actor SharedOwnProfileCredentials: V2ClientPushEndpointCredentialProvider {
    private var calls = 0
    func pushEndpointCredentials() -> V2ClientPushEndpointCredentials {
        calls += 1; return .init(accessToken: "test", deviceID: .init(uuid: UUID()))
    }
    func count() -> Int { calls }
}
private actor SharedOwnProfileTransport: V2ClientPushEndpointHTTPTransport {
    private let value: (Data, HTTPURLResponse)
    private var calls = 0
    private var pending: CheckedContinuation<(Data, HTTPURLResponse), Never>?
    init(value: (Data, HTTPURLResponse)) { self.value = value }
    func data(for request: URLRequest) async -> (Data, HTTPURLResponse) {
        calls += 1; return await withCheckedContinuation { pending = $0 }
    }
    func count() -> Int { calls }
    func complete() { pending?.resume(returning: value); pending = nil }
}

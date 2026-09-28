import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 HTTP group invitation client")
struct V2HTTPGroupInvitationClientTests {
    @Test func recoveryOnlyIntentClosesBeforeConfirmationExpiry() async throws {
        let account = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), activation = UUID()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("invitation.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: .init(value: UUID()), userID: account)
        let client = RecoveryOnlyInvitationClient()
        let service = V2InvitationOperationService(accountID: account, activationID: activation, store: store,
            client: client, secrets: UnusedInvitationSecrets())
        let confirmation = try await service.confirmation(roomID: room,
            action: .revoke(inviteID: .init(uuid: UUID()), expectedMembershipRevision: 1))
        let id = try await service.enqueue(confirmation)
        let workID = try await store.trackInvitationRecovery(id: id)
        guard case .claimed(let claim) = try await store.claimOperationWork(id: workID, ownerID: UUID(), action: .reconcile, now: Date()) else {
            throw V2OperationWorkError.invalidTransition
        }
        #expect(Date().timeIntervalSince1970 * 1_000 < Double(confirmation.intent.confirmedUntilMilliseconds))
        try await service.execute(claim)
        let actions = await client.actions
        #expect(actions == [.closeIfAbsent])
        #expect(try await store.operationWork(id: workID)?.execution == .closed)
        #expect(try await store.operationWork(id: workID)?.identity == confirmation.intent.identity)
        #expect(try await store.invitationPending(id: id).command == nil)
        try await store.close()
    }

    @Test("review pages expose metadata only and reject mismatched or unbounded results", arguments: ["valid", "legacy", "wrong-room", "duplicate", "oversize", "terminal", "same-cursor", "empty-cursor", "long-cursor", "invalid-user"])
    func reviewPageContract(_ scenario: String) async throws {
        let base = try #require(URL(string: "https://account.example"))
        let room = RoomID(uuid: UUID()), applicant = UserID(uuid: UUID()), request = GroupJoinRequestID(uuid: UUID())
        var item: [String: Any] = ["request_id": request.rawValue, "room_id": room.rawValue,
            "invite_id": UUID().uuidString, "applicant_user_id": applicant.rawValue,
            "state": "pending", "created_at_ms": 1750000000000]
        if scenario == "legacy" { item["applicant_user_id"] = nil; item["applicant"] = ["user_id": applicant.rawValue, "display_name": "Old unleased name"] }
        if scenario == "wrong-room" { item["room_id"] = UUID().uuidString }
        if scenario == "invalid-user" { item["applicant_user_id"] = "" }
        if scenario == "terminal" { item["state"] = "cancelled"; item["decided_at_ms"] = 1750000001000 }
        var items = [item]
        if scenario == "duplicate" { items.append(item) }
        if scenario == "oversize" { items += (0..<2).map { _ in var copy = item; copy["request_id"] = UUID().uuidString; return copy } }
        let next: String = switch scenario { case "same-cursor": "prior"; case "empty-cursor": ""; case "long-cursor": String(repeating: "x", count: 1_025); default: "next" }
        let body = try JSONSerialization.data(withJSONObject: ["items": items, "next_cursor": next])
        let transport = RecordingGroupInvitationTransport(responses: [try response(status: 200, endpoint: base, body: String(decoding: body, as: UTF8.self))])
        let client = try V2HTTPGroupInvitationClient(baseURL: base,
            credentials: GroupInvitationCredentials(accessToken: "edge-token", deviceID: .init(uuid: UUID())), transport: transport)
        if scenario == "valid" {
            let page = try await client.pendingRequests(roomID: room, cursor: "prior", pageSize: 2)
            #expect(page.requests.first?.presentationKey == .init(userID: applicant, context: .groupJoinReview(room)))
            #expect(page.requests.first?.requestID == request && page.nextCursor == "next")
        } else {
            await #expect(throws: V2ClientGroupInvitationError.invalidResponse) {
                _ = try await client.pendingRequests(roomID: room, cursor: "prior", pageSize: 2)
            }
        }
        for size in [0, 101] {
            await #expect(throws: V2ClientGroupInvitationError.invalidRequest) {
                _ = try await client.pendingRequests(roomID: room, cursor: nil, pageSize: size)
            }
        }
        #expect(await transport.requests().count == 1)
    }

    @Test("create freezes an observed membership baseline and preserves its original admission")
    func createContract() async throws {
        let base=try #require(URL(string:"https://account.example")),room=RoomID(uuid:UUID()),account=UserID(uuid:UUID())
        let identity=try V2OperationIdentity(accountID:account,scope:.room(room),operation:.groupInvite(.init(uuid:UUID())))
        let now=UInt64(Date().timeIntervalSince1970*1000)
        let intent=try V2GroupInvitationOperationIntent(identity:identity,action:.create(lifetimeSeconds:3600,maximumApprovedUses:20,expectedMembershipRevision:4),confirmedUntilMilliseconds:now+120000)
        let admission=try V2GroupInvitationAdmission(id:.init(uuid:UUID()),identity:identity,intentFingerprint:intent.fingerprint,membershipRevision:4,issuedAtMilliseconds:now,expiresAtMilliseconds:now+120000)
        let command=try V2GroupInvitationOperationCommand(intent:intent,admission:admission)
        let endpoint=base.appending(path:"v2/rooms/\(room.rawValue)/invitation-operations/submit")
        let reply=V2GroupInvitationOperationRecoveryResult.unresolved
        let transport=RecordingGroupInvitationTransport(responses:[try response(status:200,endpoint:endpoint,body:String(decoding:JSONEncoder().encode(reply),as:UTF8.self))])
        let client=try V2HTTPInvitationOperationClient(baseURL:base,credentials:GroupInvitationCredentials(accessToken:"edge-token",deviceID:.init(uuid:UUID())),transport:transport)
        #expect(try await client.submit(.init(command:command)) == .unresolved)
        let request=try #require(await transport.requests().first)
        #expect(request.url==endpoint && request.httpMethod=="POST")
        #expect(request.value(forHTTPHeaderField:"Cache-Control")=="no-store")
        #expect(try JSONDecoder().decode(V2GroupInvitationSubmission.self,from:#require(request.httpBody)).command==command)
    }

    @Test("preview sends its bearer secret only in the request body and maps unavailable links")
    func previewUnavailable() async throws {
        let baseURL = try #require(URL(string: "https://account.example"))
        let endpoint = baseURL.appendingPathComponent("v2/group-invites/preview")
        let transport = RecordingGroupInvitationTransport(responses: [try response(status: 404, endpoint: endpoint, body: "")])
        let client = try V2HTTPGroupInvitationClient(
            baseURL: baseURL,
            credentials: GroupInvitationCredentials(
                accessToken: "edge-token",
                deviceID: try .init("00000000-0000-0000-0000-000000000211")
            ),
            transport: transport
        )
        let secret = try V2GroupInviteSecret(String(repeating: "B", count: 43))

        await #expect(throws: V2ClientGroupInvitationError.unavailable) {
            _ = try await client.preview(secret: secret)
        }
        let request = try #require(await transport.requests().first)
        #expect(request.url?.absoluteString.contains(secret.rawValue) == false)
        let body = try #require(request.httpBody)
        #expect(String(decoding: body, as: UTF8.self).contains(secret.rawValue))
    }

    @Test("plain HTTP endpoints are rejected before any credential access")
    func rejectsPlainHTTP() throws {
        #expect(throws: V2ClientGroupInvitationError.invalidEndpoint) {
            _ = try V2HTTPGroupInvitationClient(
                baseURL: #require(URL(string: "http://account.example")),
                credentials: GroupInvitationCredentials(
                    accessToken: "edge-token",
                    deviceID: try .init("00000000-0000-0000-0000-000000000221")
                )
            )
        }
    }

    @Test("original cancellation proof binds request, identity and fingerprint",arguments:[false,true])
    func cancelContract(wrongIdentity:Bool) async throws {
        let base=try #require(URL(string:"https://account.example")),room=RoomID(uuid:UUID()),account=UserID(uuid:UUID()),requestID=GroupJoinRequestID(uuid:UUID())
        let identity=try V2OperationIdentity(accountID:account,scope:.room(room),operation:.groupJoinRequest(.init(uuid:UUID())))
        let now=UInt64(Date().timeIntervalSince1970*1000)
        let intent=try V2GroupInvitationOperationIntent(identity:identity,action:.cancel(requestID:requestID),confirmedUntilMilliseconds:now+120000)
        let original=try V2GroupInvitationOperationIntent(identity:wrongIdentity ? .init(accountID:account,scope:.room(room),operation:.groupJoinRequest(.init(uuid:UUID()))) : identity,action:.cancel(requestID:requestID),confirmedUntilMilliseconds:now+120000)
        let receipt=try V2GroupInvitationOperationReceipt(intent:original,outcome:.applied(.requestCancelled(requestID:requestID)),resolvedAtMilliseconds:now)
        let endpoint=base.appending(path:"v2/rooms/\(room.rawValue)/invitation-operations/operations/recover")
        let transport=RecordingGroupInvitationTransport(responses:[try response(status:200,endpoint:endpoint,body:String(decoding:JSONEncoder().encode(V2GroupInvitationOperationRecoveryResult.receipt(receipt)),as:UTF8.self))])
        let client=try V2HTTPInvitationOperationClient(baseURL:base,credentials:GroupInvitationCredentials(accessToken:"edge-token",deviceID:.init(uuid:UUID())),transport:transport)
        if wrongIdentity {await #expect(throws:V2GroupInvitationOperationValidationError.invalidReceipt) {try await client.recover(intent,action:.query)}}
        else {#expect(try await client.recover(intent,action:.query) == .receipt(receipt))}
        let request=try #require(await transport.requests().first)
        #expect(try JSONDecoder().decode(V2GroupInvitationRecoveryRequest.self,from:#require(request.httpBody)).intent==intent)
    }

    @Test func sharedReadsKeepIndependentSubscribersAndNeverShareAcrossAccountsOrPages() async throws {
        let base = try #require(URL(string: "https://account.example"))
        let queries = V2QueryCoordinator<Data>()
        let transport = SuspendedInvitationTransport()
        let credentials = GroupInvitationCredentials(accessToken: "token", deviceID: .init(uuid: UUID()))
        let activation = UUID()
        let scope = V2QueryScope(accountID: "account-a", authorizationDomain: "management", activationID: activation, generation: 1)
        let client = try V2HTTPGroupInvitationClient(baseURL: base, credentials: credentials, transport: transport, queries: queries, queryScope: scope)
        let room = RoomID(uuid: UUID())
        let first = Task { try await client.activeInvites(roomID: room) }
        let second = Task { try await client.activeInvites(roomID: room) }
        while await queries.snapshot().subscribers < 2 { await Task.yield() }
        first.cancel()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        while await transport.count() < 1 { await Task.yield() }
        #expect(await transport.count() == 1)
        await transport.complete()
        #expect(try await second.value.isEmpty)
        let other = try V2HTTPGroupInvitationClient(baseURL: base, credentials: credentials, transport: transport, queries: queries,
            queryScope: .init(accountID: "account-b", authorizationDomain: "management", activationID: activation, generation: 1))
        let a = Task { try await client.pendingRequests(roomID: room, cursor: nil, pageSize: 10) }
        let b = Task { try await client.pendingRequests(roomID: room, cursor: "next", pageSize: 10) }
        let c = Task { try await other.pendingRequests(roomID: room, cursor: nil, pageSize: 10) }
        while await transport.count() < 4 { await Task.yield() }
        #expect(await queries.snapshot().flights == 3)
        await queries.beginClose()
        await transport.complete()
        for task in [a, b, c] {
            await #expect(throws: V2QueryCoordinator<Data>.QueryError.self) { _ = try await task.value }
        }
        await queries.closeAndDrain()
    }

    @Test func retryAfterHTTPDateAndTransportCertaintyArePreserved() async throws {
        let base = try #require(URL(string: "https://account.example"))
        let credentials = GroupInvitationCredentials(accessToken: "token", deviceID: .init(uuid: UUID()))
        let formatter = DateFormatter(); formatter.locale = .init(identifier: "en_US_POSIX"); formatter.timeZone = .init(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        let response = try #require(HTTPURLResponse(url: base, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": formatter.string(from: Date().addingTimeInterval(7200))]))
        let client = try V2HTTPGroupInvitationClient(baseURL: base, credentials: credentials,
            transport: RecordingGroupInvitationTransport(responses: [(Data(), response)]))
        do { _ = try await client.activeInvites(roomID: .init(uuid: UUID())); Issue.record("expected throttling") }
        catch V2ClientGroupInvitationError.rateLimited(let seconds) { #expect((seconds ?? 0) >= 7198) }
        let failure = V2HTTPFailure(kind: .deadlineExceeded, service: "accountAPI", certainty: .notStarted)
        let failed = try V2HTTPGroupInvitationClient(baseURL: base, credentials: credentials, transport: FailedInvitationTransport(failure: failure))
        await #expect(throws: failure) { _ = try await failed.activeInvites(roomID: .init(uuid: UUID())) }
    }

    private func response(status: Int, endpoint: URL, body: String) throws -> (Data, HTTPURLResponse) {
        var headers = ["Cache-Control": "no-store"]
        if status == 200 { headers["Content-Type"] = "application/json" }
        return (
            Data(body.utf8),
            try #require(HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: headers))
        )
    }
}

private struct GroupInvitationCredentials: V2ClientPushEndpointCredentialProvider,V2ClientMediaEdgeCredentialProvider {
    let accessToken: String
    let deviceID: DeviceID

    func mediaEdgeCredentials() -> V2ClientMediaEdgeCredentials {.init(accessToken:accessToken,deviceID:deviceID)}
    func pushEndpointCredentials() -> V2ClientPushEndpointCredentials {
        .init(accessToken: accessToken, deviceID: deviceID)
    }
}

private actor RecordingGroupInvitationTransport: V2ClientGroupInvitationHTTPTransport,V2ClientMediaEdgeHTTPTransport {
    private var responses: [(Data, HTTPURLResponse)]
    private var captured: [URLRequest] = []

    init(responses: [(Data, HTTPURLResponse)]) { self.responses = responses }

    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        captured.append(request)
        guard !responses.isEmpty else { throw V2ClientGroupInvitationError.networkFailure }
        return responses.removeFirst()
    }

    func requests() -> [URLRequest] { captured }
}

private struct FailedInvitationTransport: V2ClientGroupInvitationHTTPTransport {
    let failure: V2HTTPFailure
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw failure }
}
private actor SuspendedInvitationTransport: V2ClientGroupInvitationHTTPTransport {
    private var requests: [URLRequest] = []
    private var waiting: [CheckedContinuation<(Data, HTTPURLResponse), any Error>] = []
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }
    func count() -> Int { requests.count }
    func complete() {
        let response = HTTPURLResponse(url: URL(string: "https://account.example")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let current = waiting; waiting = []
        for continuation in current { continuation.resume(returning: (Data("{\"items\":[]}".utf8), response)) }
    }
}

private actor RecoveryOnlyInvitationClient: V2InvitationOperationClient {
    var actions: [V2OperationRecoveryRequest.Action] = []
    func baseline(roomID: RoomID) async throws -> V2GroupInvitationOperationBaseline { throw V2OperationWorkError.invalidTransition }
    func admit(_ request: V2GroupInvitationAdmissionRequest) async throws -> V2GroupInvitationAdmissionResult { throw V2OperationWorkError.invalidTransition }
    func submit(_ submission: V2GroupInvitationSubmission) async throws -> V2GroupInvitationOperationRecoveryResult { throw V2OperationWorkError.invalidTransition }
    func recover(_ intent: V2GroupInvitationOperationIntent, action: V2OperationRecoveryRequest.Action) async throws -> V2GroupInvitationOperationRecoveryResult {
        actions.append(action)
        return .receipt(try .init(intent: intent, outcome: .closed, resolvedAtMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000)))
    }
}
private struct UnusedInvitationSecrets: V2InvitationSecretStoring {
    func save(_ authorization: V2GroupInvitationSecretAuthorization, reference: UUID, accountID: UserID) throws { throw V2InvitationSecretStoreError.unavailable }
    func load(reference: UUID, accountID: UserID) throws -> V2GroupInvitationSecretAuthorization { throw V2InvitationSecretStoreError.unavailable }
    func remove(reference: UUID, accountID: UserID) throws { throw V2InvitationSecretStoreError.unavailable }
}

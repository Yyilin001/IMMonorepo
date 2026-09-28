import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 HTTP device-session client")
struct V2HTTPDeviceSessionClientTests {
    @Test("list uses the authenticated no-store contract")
    func listAndRevokeRequests() async throws {
        let endpoint = try #require(URL(string: "https://account.example/v2/devices"))
        let current = try DeviceID("00000000-0000-0000-0000-000000000901")
        let transport = RecordingDeviceSessionTransport(responses: [
            try response(status: 200, endpoint: endpoint, body: "{\"sessions\":[{\"deviceID\":\"\(current.rawValue)\",\"deviceName\":\"iPhone\",\"platform\":\"iPhone\",\"createdAtMilliseconds\":1750000000000,\"lastActiveAtMilliseconds\":1750000001000,\"isCurrentDevice\":true}],\"nextCursor\":\"next-page\"}")
        ])
        let client = try V2HTTPDeviceSessionClient(
            endpoint: endpoint,
            credentials: FixedDeviceSessionCredentials(accessToken: "edge-token", deviceID: current),
            transport: transport
        )

        let page = try await client.list(cursor: nil, pageSize: 50)
        #expect(page.sessions.count == 1)
        #expect(page.sessions[0].deviceName == "iPhone")
        #expect(page.sessions[0].isCurrentDevice)
        #expect(page.nextCursor == "next-page")
        let requests = await transport.requests()
        #expect(requests.count == 1)
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[0].url?.query == "page_size=50")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer edge-token" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-IM-Device-ID") == current.rawValue })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cache-Control") == "no-store" })
    }

    @Test("remote revoke requires an immutable complete observed baseline and matched original proof")
    func unavailableRemoteSession() async throws {
        let root = URL(string: "https://account.example")!, current = DeviceID(uuid: UUID()), other = DeviceID(uuid: UUID())
        let actor = UserID(uuid: UUID()), now = UInt64(Date().timeIntervalSince1970 * 1_000)
        let baseline = try V2RemoteDeviceRevocationBaseline(id: UUID(), actorUserID: actor, currentDeviceID: current,
            targetDeviceIDs: [other], issuedAtMilliseconds: now, expiresAtMilliseconds: now + 120_000)
        let command = try V2RemoteDeviceRevocationCommand(operationID: UUID(), baseline: baseline, selection: .allObservedOthers, firstSubmissionDeadlineMilliseconds: now + 120_000)
        let proof = try V2RemoteDeviceRevocationReceipt(command: command, outcome: .revoked, resolvedAtMilliseconds: now + 1)
        let transport = RecordingDeviceSessionTransport(responses: [
            try response(status: 200, endpoint: root, body: String(decoding: JSONEncoder().encode(baseline), as: UTF8.self)),
            try response(status: 200, endpoint: root, body: String(decoding: JSONEncoder().encode(V2RemoteDeviceRevocationResult.receipt(proof)), as: UTF8.self))])
        let client = try V2HTTPRemoteDeviceRevocationClient(baseURL: root, credentials: FixedDeviceSessionCredentials(accessToken: "edge-token", deviceID: current), transport: transport)
        #expect(try await client.baseline() == baseline)
        #expect(try await client.submit(command) == .receipt(proof))
        let requests = await transport.requests()
        #expect(requests[0].url?.path == "/v2/devices/revocation-baseline")
        #expect(requests[1].url?.path == "/v2/devices/remote-revocations/submit")
        #expect(try JSONDecoder().decode(V2RemoteDeviceRevocationCommand.self, from: #require(requests[1].httpBody)) == command)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cache-Control") == "no-store" })
    }

    @Test(arguments: [429, 503])
    func listPreservesServerCooldownAndResponseCertainty(status: Int) async throws {
        let endpoint = try #require(URL(string: "https://account.example/v2/devices"))
        let response = try #require(HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "10000"]))
        let client = try V2HTTPDeviceSessionClient(endpoint: endpoint,
            credentials: FixedDeviceSessionCredentials(accessToken: "token", deviceID: .init(uuid: UUID())),
            transport: RecordingDeviceSessionTransport(responses: [(Data(), response)]))
        do { _ = try await client.list(cursor: nil, pageSize: 10); Issue.record("expected throttle") }
        catch let failure as V2HTTPFailure {
            #expect(failure.statusCode == status && failure.certainty == .responseReceived)
            #expect((failure.retryAfter?.timeIntervalSinceNow ?? 0) >= 9998)
        }
    }

    private func response(status: Int, endpoint: URL, body: String) throws -> (Data, HTTPURLResponse) {
        var headers = ["Cache-Control": "no-store"]
        if status == 200 { headers["Content-Type"] = "application/json" }
        let response = try #require(HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: headers))
        return (Data(body.utf8), response)
    }
}

private struct FixedDeviceSessionCredentials: V2ClientDeviceSessionCredentialProvider {
    let accessToken: String; let deviceID: DeviceID
    func deviceSessionCredentials() -> V2ClientDeviceSessionCredentials { .init(accessToken: accessToken, deviceID: deviceID) }
}
private actor RecordingDeviceSessionTransport: V2ClientDeviceSessionHTTPTransport {
    private var responses: [(Data, HTTPURLResponse)]
    private var captured: [URLRequest] = []
    init(responses: [(Data, HTTPURLResponse)]) { self.responses = responses }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        captured.append(request)
        guard !responses.isEmpty else { throw V2ClientDeviceSessionError.networkFailure }
        return responses.removeFirst()
    }
    func requests() -> [URLRequest] { captured }
}

private final class RemoteRevocationFixtureMetadata: V2RemoteDeviceRevocationMetadataStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    let locked: Bool
    init(locked: Bool = false) { self.locked = locked }
    func read() throws -> Data? {
        guard !locked else { throw V2RemoteDeviceRevocationJournalError.locked }
        lock.lock(); defer { lock.unlock() }; return bytes
    }
    func write(_ bytes: Data) throws {
        guard !locked else { throw V2RemoteDeviceRevocationJournalError.locked }
        lock.lock(); defer { lock.unlock() }; self.bytes = bytes
    }
}
private actor RemoteRevocationFixtureClient: V2RemoteDeviceRevocationClient {
    let value: V2RemoteDeviceRevocationBaseline
    private(set) var submits: [V2RemoteDeviceRevocationCommand] = []
    private(set) var recoveries: [V2RemoteDeviceRevocationCommand] = []
    init(_ value: V2RemoteDeviceRevocationBaseline) { self.value = value }
    func baseline() -> V2RemoteDeviceRevocationBaseline { value }
    func submit(_ command: V2RemoteDeviceRevocationCommand) -> V2RemoteDeviceRevocationResult { submits.append(command); return .unresolved }
    func recover(_ command: V2RemoteDeviceRevocationCommand, action: V2RemoteDeviceRevocationRecoveryRequest.Action) throws -> V2RemoteDeviceRevocationResult {
        recoveries.append(command)
        #expect(action == .closeIfAbsent)
        return .receipt(try .init(command: command, outcome: .closed, resolvedAtMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000)))
    }
}
extension V2HTTPDeviceSessionClientTests {
    @Test("security journal restart keeps original identity and fixed target set without restoring submit authorization")
    func metadataRestartDoesNotReauthorize() async throws {
        let actor = UserID(uuid: UUID()), current = DeviceID(uuid: UUID()), targets = [DeviceID(uuid: UUID()), DeviceID(uuid: UUID())].sorted { $0.rawValue < $1.rawValue }
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        let baseline = try V2RemoteDeviceRevocationBaseline(id: UUID(), actorUserID: actor, currentDeviceID: current, targetDeviceIDs: targets, issuedAtMilliseconds: now, expiresAtMilliseconds: now + 120_000)
        let command = try V2RemoteDeviceRevocationCommand(operationID: UUID(), baseline: baseline, selection: .allObservedOthers, firstSubmissionDeadlineMilliseconds: baseline.expiresAtMilliseconds)
        let metadata = RemoteRevocationFixtureMetadata(), remote = RemoteRevocationFixtureClient(baseline)
        let first = V2RemoteDeviceRevocationService(accountID: actor, currentDeviceID: current, storage: metadata, client: remote)
        _ = try await first.readBaseline(); try await first.enqueue(command)
        let restored = V2RemoteDeviceRevocationService(accountID: actor, currentDeviceID: current, storage: metadata, client: remote)
        let updates = try await restored.updates()
        let worker = Task { try await restored.run() }; defer { worker.cancel() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await values in updates where values.first?.receipt != nil {
                    #expect(values.first?.command == command)
                    #expect(values.first?.receipt?.targetDeviceIDs == targets)
                    return
                }
                throw CancellationError()
            }
            group.addTask { try await Task.sleep(for: .seconds(5)); throw URLError(.timedOut) }
            defer { group.cancelAll() }; _ = try await group.next()
        }
        #expect(await remote.submits.isEmpty)
        #expect(await remote.recoveries == [command])
        worker.cancel(); _ = await worker.result
        let beforeClose = try metadata.read()
        await restored.close()
        await #expect(throws: CancellationError.self) { try await restored.enqueue(command) }
        await #expect(throws: CancellationError.self) { try await restored.resume(command.operationID) }
        #expect(try metadata.read() == beforeClose)
    }
    @Test("security journal rejects overlapping original unknown identities and bounds unfinished records")
    func metadataCapacityAndOverlap() async throws {
        let actor = UserID(uuid: UUID()), current = DeviceID(uuid: UUID()), targets = (0..<9).map { _ in DeviceID(uuid: UUID()) }.sorted { $0.rawValue < $1.rawValue }
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        let baseline = try V2RemoteDeviceRevocationBaseline(id: UUID(), actorUserID: actor, currentDeviceID: current, targetDeviceIDs: targets, issuedAtMilliseconds: now, expiresAtMilliseconds: now + 120_000)
        let service = V2RemoteDeviceRevocationService(accountID: actor, currentDeviceID: current, storage: RemoteRevocationFixtureMetadata(), client: RemoteRevocationFixtureClient(baseline))
        _ = try await service.readBaseline()
        for target in targets.prefix(8) { try await service.enqueue(.init(operationID: UUID(), baseline: baseline, selection: .device(target), firstSubmissionDeadlineMilliseconds: baseline.expiresAtMilliseconds)) }
        do {
            try await service.enqueue(.init(operationID: UUID(), baseline: baseline, selection: .device(targets[0]), firstSubmissionDeadlineMilliseconds: baseline.expiresAtMilliseconds)); Issue.record("replaced unknown identity")
        } catch V2RemoteDeviceRevocationJournalError.conflictingPending {}
        do {
            try await service.enqueue(.init(operationID: UUID(), baseline: baseline, selection: .device(targets[8]), firstSubmissionDeadlineMilliseconds: baseline.expiresAtMilliseconds)); Issue.record("unbounded security queue")
        } catch V2RemoteDeviceRevocationJournalError.capacityExceeded {}
        let stream = try await service.updates(); var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.count == 8)
    }
    @Test("locked security metadata is unavailable rather than an empty recovery queue")
    func metadataLockIsNotEmpty() async throws {
        let actor = UserID(uuid: UUID()), current = DeviceID(uuid: UUID()), now = UInt64(Date().timeIntervalSince1970 * 1_000)
        let baseline = try V2RemoteDeviceRevocationBaseline(id: UUID(), actorUserID: actor, currentDeviceID: current, targetDeviceIDs: [], issuedAtMilliseconds: now, expiresAtMilliseconds: now + 120_000)
        let service = V2RemoteDeviceRevocationService(accountID: actor, currentDeviceID: current, storage: RemoteRevocationFixtureMetadata(locked: true), client: RemoteRevocationFixtureClient(baseline))
        do { _ = try await service.updates(); Issue.record("locked record became an empty queue") }
        catch V2RemoteDeviceRevocationJournalError.locked {}
    }
}

private actor LateRemoteRevocationClient: V2RemoteDeviceRevocationClient {
    let value: V2RemoteDeviceRevocationBaseline
    private var pending: CheckedContinuation<V2RemoteDeviceRevocationResult, any Error>?
    init(_ value: V2RemoteDeviceRevocationBaseline) { self.value = value }
    func baseline() -> V2RemoteDeviceRevocationBaseline { value }
    func submit(_ command: V2RemoteDeviceRevocationCommand) async throws -> V2RemoteDeviceRevocationResult {
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func recover(_ command: V2RemoteDeviceRevocationCommand, action: V2RemoteDeviceRevocationRecoveryRequest.Action) -> V2RemoteDeviceRevocationResult { .unresolved }
    func waitForSubmit() async { while pending == nil { await Task.yield() } }
    func finish(_ command: V2RemoteDeviceRevocationCommand, failing: Bool) throws {
        if failing { pending?.resume(throwing: URLError(.networkConnectionLost)) }
        else { pending?.resume(returning: .receipt(try .init(command: command, outcome: .closed, resolvedAtMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000)))) }
        pending = nil
    }
}
extension V2HTTPDeviceSessionClientTests {
    @Test("closed security owner cannot overwrite metadata with a late submit response", arguments: [false, true])
    func closedOwnerRejectsLateSubmit(failing: Bool) async throws {
        let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        let baseline = try V2RemoteDeviceRevocationBaseline(id: UUID(), actorUserID: actor, currentDeviceID: device,
            targetDeviceIDs: [DeviceID(uuid: UUID())], issuedAtMilliseconds: now, expiresAtMilliseconds: now + 120_000)
        let command = try V2RemoteDeviceRevocationCommand(operationID: UUID(), baseline: baseline,
            selection: .allObservedOthers, firstSubmissionDeadlineMilliseconds: baseline.expiresAtMilliseconds)
        let metadata = RemoteRevocationFixtureMetadata(), client = LateRemoteRevocationClient(baseline)
        let old = V2RemoteDeviceRevocationService(accountID: actor, currentDeviceID: device, storage: metadata, client: client)
        _ = try await old.readBaseline(); try await old.enqueue(command)
        let worker = Task { try await old.run() }
        await client.waitForSubmit()
        await old.close()
        let replacement = V2RemoteDeviceRevocationService(accountID: actor, currentDeviceID: device, storage: metadata, client: client)
        try await replacement.resume(command.operationID)
        let replacementBytes = try metadata.read()
        try await client.finish(command, failing: failing)
        _ = await worker.result
        #expect(try metadata.read() == replacementBytes)
        let updates = try await replacement.updates()
        var iterator = updates.makeAsyncIterator()
        let records = await iterator.next()
        #expect(records?.first?.command == command)
        #expect(records?.first?.unknown == true)
        #expect(records?.first?.receipt == nil)
        await replacement.close()
    }
}

import Foundation
import IMV2ClientKit
import IMV2Core
import Testing

struct V2MemberAdministrationHTTPBoundaryTests {
    @Test("HTTP receipt integers reject overflow and preserve command-specific revisions",
          arguments: ["muteSequence", "removeSequence", "removeRevision"],
          [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func receiptBounds(scenario: String, value: UInt64) async throws {
        let removal = scenario.hasPrefix("remove")
        let expectedRevision: UInt64 = scenario == "removeRevision" && value > 0 && value <= UInt64(Int64.max) ? value - 1 : 0
        let command = try command(removal: removal, revision: expectedRevision)
        let outcome: V2MemberAdministrationTerminalOutcome = removal
            ? .applied(.removed(membershipRevision: expectedRevision + 1, roomSequence: 1, eventID: .init(uuid: UUID())))
            : .applied(.muted(untilMilliseconds: 1_750_000_300_000, membershipRevision: expectedRevision, roomSequence: 1, eventID: .init(uuid: UUID())))
        let receipt = try V2MemberAdministrationReceipt(identity: command.identity, fingerprint: command.fingerprint,
            outcome: outcome, resolvedAtMilliseconds: 1_750_000_001_000)
        let encoded = try JSONEncoder().encode(V2MemberAdministrationRecoveryResult.receipt(receipt))
        let object = try JSONSerialization.jsonObject(with: encoded)
        let key = scenario == "removeRevision" ? "membershipRevision" : "roomSequence"
        let body = try JSONSerialization.data(withJSONObject: replacing(object, key: key, value: NSNumber(value: value)))
        let client = try V2HTTPMemberAdministrationClient(baseURL: URL(string: "https://account.example")!,
            credentials: AdministrationBoundaryCredentials(), transport: AdministrationBoundaryResponse(body: body))
        if value == 0 || value > UInt64(Int64.max) {
            await #expect(throws: V2MemberAdministrationValidationError.invalidReceipt) { try await client.submit(command) }
        } else {
            #expect(try await client.submit(command) == JSONDecoder().decode(V2MemberAdministrationRecoveryResult.self, from: body))
        }
    }

    @Test("HTTP submit preserves the frozen identity, reason, target and confirmation context", arguments: [false, true])
    func commandRoundTrip(removal: Bool) async throws {
        let command = try command(removal: removal, revision: 0)
        let transport = AdministrationCommandCapture()
        let client = try V2HTTPMemberAdministrationClient(baseURL: URL(string: "https://account.example")!,
            credentials: AdministrationBoundaryCredentials(), transport: transport)
        #expect(try await client.submit(command) == .unresolved)
        let request = try #require(await transport.captured())
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v2/rooms/\(command.intent.roomID.rawValue)/member-administration/submit")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(try JSONDecoder().decode(V2MemberAdministrationCommand.self, from: #require(request.httpBody)) == command)
    }

    @Test("HTTP closure proof must belong to the exact frozen command", arguments: [false, true])
    func rejectsUnrelatedProof(wrongIdentity: Bool) async throws {
        let command = try command(removal: true, revision: 0)
        let other = try self.command(removal: true, revision: 0)
        let receipt = try V2MemberAdministrationReceipt(
            identity: wrongIdentity ? other.identity : command.identity,
            fingerprint: wrongIdentity ? command.fingerprint : other.fingerprint,
            outcome: .closed, resolvedAtMilliseconds: 1_750_000_001_000)
        let client = try V2HTTPMemberAdministrationClient(baseURL: URL(string: "https://account.example")!,
            credentials: AdministrationBoundaryCredentials(),
            transport: AdministrationBoundaryResponse(body: JSONEncoder().encode(V2MemberAdministrationRecoveryResult.receipt(receipt))))
        await #expect(throws: V2MemberAdministrationValidationError.invalidReceipt) {
            try await client.recover(command, action: .closeIfAbsent)
        }
    }

    private func command(removal: Bool, revision: UInt64) throws -> V2MemberAdministrationCommand {
        let intent = try V2MemberAdministrationIntent(roomID: .init(uuid: UUID()), actorUserID: .init(uuid: UUID()),
            operationID: .init(uuid: UUID()), targetUserID: .init(uuid: UUID()),
            action: removal ? .remove : .mute(untilMilliseconds: 1_750_000_300_000), reasonCode: .init("abuse_spam"),
            expectedMembershipRevision: revision, confirmedUntilMilliseconds: 1_750_000_120_000)
        return try .init(intent: intent, admission: .init(id: .init(uuid: UUID()), identity: intent.identity,
            intentFingerprint: intent.fingerprint, membershipRevision: revision, targetJoinedRevision: 0,
            issuedAtMilliseconds: 1_750_000_000_000, expiresAtMilliseconds: 1_750_000_120_000))
    }

    private func replacing(_ object: Any, key: String, value: NSNumber) -> Any {
        if let fields = object as? [String: Any] {
            return fields.mapValues { replacing($0, key: key, value: value) }
                .merging(fields[key] == nil ? [:] : [key: value]) { _, replacement in replacement }
        }
        if let values = object as? [Any] { return values.map { replacing($0, key: key, value: value) } }
        return object
    }
}

private struct AdministrationBoundaryCredentials: V2ClientMediaEdgeCredentialProvider {
    func mediaEdgeCredentials() -> V2ClientMediaEdgeCredentials { .init(accessToken: "test-token", deviceID: .init(uuid: UUID())) }
}
private struct AdministrationBoundaryResponse: V2ClientMediaEdgeHTTPTransport {
    let body: Data
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}
private actor AdministrationCommandCapture: V2ClientMediaEdgeHTTPTransport {
    private var request: URLRequest?
    func captured() -> URLRequest? { request }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        return (try JSONEncoder().encode(V2MemberAdministrationRecoveryResult.unresolved),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}

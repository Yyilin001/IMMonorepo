import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Credential issue cancellation boundaries", .timeLimit(.minutes(1)))
struct V2CredentialIssueCancellationTests {
    @Test("cancelled prerequisites cannot start the next registration effect", arguments: Stage.allCases)
    func stopsBeforeNextEffect(stage: Stage) async throws {
        let fixture = IssueCancellationFixture(stage: stage)
        let provider = try V2HTTPAccountAssertionDeviceCredentialProvider(
            issueEndpoint: URL(string: "https://account.invalid/v2/device-credentials")!,
            assertionProvider: fixture, deviceIdentityProvider: fixture,
            operationStore: fixture, transport: fixture)
        let issuing = Task { try await provider.issueDeviceCredentials() }
        await fixture.waitUntilBlocked()
        issuing.cancel()
        await fixture.release()
        await #expect(throws: CancellationError.self) { try await issuing.value }
        let effects = await fixture.effects
        let expected: [Stage]
        switch stage {
        case .identity: expected = [.identity]
        case .assertion: expected = [.identity, .assertion]
        case .load: expected = [.identity, .assertion, .load]
        case .save: expected = [.identity, .assertion, .load, .save]
        }
        #expect(effects == expected)
        #expect(await fixture.requests == 0)
        // A save already in progress may commit. Its durable operation is
        // retained for replay, but cancellation must prevent the HTTP request.
        let hasRecord = await fixture.record != nil
        #expect(hasRecord == (stage == .save))
    }

    @Test("URLSession cancellation remains cancellation and preserves the replay operation")
    func preservesTransportCancellation() async throws {
        let fixture = IssueCancellationFixture(stage: nil, cancelsHTTP: true)
        let provider = try V2HTTPAccountAssertionDeviceCredentialProvider(
            issueEndpoint: URL(string: "https://account.invalid/v2/device-credentials")!,
            assertionProvider: fixture, deviceIdentityProvider: fixture,
            operationStore: fixture, transport: fixture)
        await #expect(throws: CancellationError.self) { try await provider.issueDeviceCredentials() }
        #expect(await fixture.requests == 1)
        #expect(await fixture.record != nil)
    }

    enum Stage: CaseIterable, Sendable { case identity, assertion, load, save }
}

private actor IssueCancellationFixture: V2DeviceIdentityProvider, V2DeviceBoundAccountAssertionProvider,
    V2DeviceCredentialRegistrationOperationStore, V2AuthHTTPTransport {
    private let stage: V2CredentialIssueCancellationTests.Stage?
    private let cancelsHTTP: Bool
    private let device = try! DeviceID("00000000-0000-4000-8000-000000000801")
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private(set) var effects: [V2CredentialIssueCancellationTests.Stage] = []
    private(set) var requests = 0
    private(set) var record: V2PendingDeviceCredentialRegistration?
    init(stage: V2CredentialIssueCancellationTests.Stage?, cancelsHTTP: Bool = false) { self.stage = stage; self.cancelsHTTP = cancelsHTTP }
    func deviceID() async -> DeviceID { await pause(.identity); return device }
    func accountAssertion(for deviceID: DeviceID) async -> String { await pause(.assertion); return "valid-opaque-assertion" }
    func load() async -> V2PendingDeviceCredentialRegistration? { await pause(.load); return record }
    func save(_ registration: V2PendingDeviceCredentialRegistration) async { await pause(.save); record = registration }
    func delete() { record = nil }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests += 1
        if cancelsHTTP { throw URLError(.cancelled) }
        throw V2HTTPAuthTransportError.networkFailure
    }
    private func pause(_ current: V2CredentialIssueCancellationTests.Stage) async {
        effects.append(current)
        guard current == stage else { return }
        entered = true; observer?.resume(); observer = nil
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilBlocked() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}

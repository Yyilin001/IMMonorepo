import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("HTTP adapters preserve observed transport failures")
struct V2HTTPFailurePropagationTests {
    @Test(arguments: [V2HTTPFailure.Certainty.notStarted, .outcomeUnknown, .responseReceived])
    func safetyAndSecretOperationsPreserveFailure(certainty: V2HTTPFailure.Certainty) async throws {
        let failure = V2HTTPFailure(kind: .httpStatus, service: "authentication", statusCode: 503,
            retryAfter: Date(timeIntervalSince1970: 2_000_000_000), certainty: certainty)
        let transport = FailingProofTransport(failure: failure)
        let revocation = try V2HTTPDeviceRevocationClient(endpoint: URL(string: "https://account.example/v2/device-credentials/revoke")!, transport: transport)
        await #expect(throws: failure) {
            try await revocation.revoke(credential: .generate(), operationID: UUID())
        }
        let password = try V2PasswordLifecycleClient(baseURL: URL(string: "https://account.example/v2/password")!, transport: transport)
        await #expect(throws: failure) {
            try await password.perform(.change, accountHandle: "alice", deviceID: DeviceID("device"),
                currentPassword: "old-password-123", newPassword: "new-password-123")
        }
        #expect(await transport.calls == 2)
    }
}

private actor FailingProofTransport: V2AuthHTTPTransport {
    let failure: V2HTTPFailure
    private(set) var calls = 0
    init(failure: V2HTTPFailure) { self.failure = failure }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        calls += 1
        throw failure
    }
}

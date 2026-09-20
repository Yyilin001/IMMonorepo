import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Password lifecycle transport")
struct V2PasswordLifecycleClientTests {
    @Test("operations use no-store HTTPS and do not retry uncertain responses", arguments: [204, 401, 503])
    func requestContract(_ status: Int) async throws {
        let transport = LifecycleTransport(status: status)
        let client = try V2PasswordLifecycleClient(baseURL: #require(URL(string: "https://account.invalid/v2/account-auth/password")), transport: transport)
        do {
            try await client.perform(.change, accountHandle: "account", deviceID: .init(uuid: UUID()), currentPassword: "current-password", newPassword: "replacement-password")
            #expect(status == 204)
        } catch {
            #expect(status != 204)
        }
        let request = try #require(await transport.request)
        #expect(await transport.calls == 1)
        #expect(request.url?.path == "/v2/account-auth/password/change")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.value(forHTTPHeaderField: "Pragma") == "no-cache")
        #expect(request.httpMethod == "POST")
    }

    @Test("invalid password is rejected without network traffic")
    func validation() async throws {
        let transport = LifecycleTransport(status: 204)
        let client = try V2PasswordLifecycleClient(baseURL: #require(URL(string: "https://account.invalid/password")), transport: transport)
        await #expect(throws: V2AccountAuthenticationError.invalidPassword) {
            try await client.perform(.change, accountHandle: "account", deviceID: .init(uuid: UUID()), currentPassword: "current-password", newPassword: "short")
        }
        #expect(await transport.calls == 0)
    }

    #if canImport(Security)
    @Test("recovery codes have full-length random material")
    func randomCodes() throws {
        let first = try V2PasswordLifecycleClient.generateRecoveryCode()
        let second = try V2PasswordLifecycleClient.generateRecoveryCode()
        #expect(first != second)
        #expect(first.utf8.count == 64)
        #expect(first.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
    }
    #endif
}

private actor LifecycleTransport: V2AuthHTTPTransport {
    let status: Int
    private(set) var request: URLRequest?
    private(set) var calls = 0
    init(status: Int) { self.status = status }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        calls += 1
        self.request = request
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: [:]))
        return (Data(), response)
    }
}

import Foundation
import IMV2ClientKit
import Testing
@testable import IMApp

@MainActor
struct V2AccountSecurityStoreTests {
    @Test("password change signs out only after confirmed success", arguments: [204, 503])
    func completion(_ status: Int) async throws {
        var signedOut = false
        let transport = SecurityStoreTransport(status: status)
        let client = try V2PasswordLifecycleClient(baseURL: #require(URL(string: "https://account.invalid/password")), transport: transport)
        let store = V2AccountSecurityStore(client: client, passwordChanged: { signedOut = true })
        await store.perform(.change, account: "account", current: "current-password", next: "replacement-password", code: "")
        #expect(signedOut == (status == 204))
        if status == 503 {
            guard case .outcomeUnknown(let message) = store.state else { Issue.record("Expected uncertain outcome"); return }
            #expect(message.contains("新密码"))
        }
    }

    @Test("a cancelled settings request cannot sign out a replacement session")
    func cancelledCompletion() async throws {
        var signedOut = false
        let transport = SuspendedSecurityTransport()
        let client = try V2PasswordLifecycleClient(baseURL: #require(URL(string: "https://account.invalid/password")), transport: transport)
        let store = V2AccountSecurityStore(client: client, passwordChanged: { signedOut = true })
        let task = Task { await store.perform(.change, account: "account", current: "current-password", next: "replacement-password", code: "") }
        await transport.waitUntilRequested()
        task.cancel()
        await transport.finish()
        await task.value
        #expect(!signedOut)
        guard case .outcomeUnknown(let message) = store.state else { Issue.record("Cancellation does not prove no commit"); return }
        #expect(message.contains("不会撤回"))
    }

    @Test("uncertain recovery-code setup preserves the saved code guidance")
    func recoveryCodeOutcomeUnknown() async throws {
        let client = try V2PasswordLifecycleClient(baseURL: #require(URL(string: "https://account.invalid/password")),
            transport: SecurityStoreTransport(status: 503))
        let store = V2AccountSecurityStore(client: client, passwordChanged: { Issue.record("Code setup must not sign out") })
        await store.perform(.recoveryCode, account: "account", current: "current-password", next: "", code: String(repeating: "a1", count: 32))
        guard case .outcomeUnknown(let message) = store.state else { Issue.record("Expected uncertain outcome"); return }
        #expect(message.contains("同一码重试") && message.contains("不要"))
        #expect(!message.contains("新密码"))
    }
}

private actor SecurityStoreTransport: V2AuthHTTPTransport {
    let status: Int
    init(status: Int) { self.status = status }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        return (Data(), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: [:])))
    }
}
private actor SuspendedSecurityTransport: V2AuthHTTPTransport {
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await withCheckedContinuation { pending = $0; started?.resume(); started = nil }
        let url = try #require(request.url)
        return (Data(), try #require(HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: [:])))
    }
    func waitUntilRequested() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { pending?.resume(); pending = nil }
}

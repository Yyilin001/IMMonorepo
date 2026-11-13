#if os(macOS)
import Foundation
import Testing
import IMV2ClientRuntime
import IMV2SharedApple
@testable import IMV2SharedSDK
@testable import IMV2SharedRuntime

@Suite(.serialized) struct SharedPlatformTests {
    @Test func appleSecureItemsAndBindingRoundTrip() async throws {
        let platform = SharedPlatform.apple(), name = "phase12-test-" + UUID().uuidString
        let item = platform.securePersistence(name), other = platform.securePersistence(name + "-other")
        defer { try? item.delete(); try? other.delete() }
        #expect(try item.load() == nil)
        try item.save(Data("opaque-test-value".utf8))
        #expect(try platform.securePersistence(name).load() == Data("opaque-test-value".utf8))
        #expect(try other.load() == nil)
        try item.save(Data([7, 9])); #expect(try item.load() == Data([7, 9]))
        try item.delete(); try item.delete(); #expect(try item.load() == nil)
        let binding = platform.installationBinding(name)
        let value = V2LocalInstallationBinding(value: UUID())
        do {
            try await binding.save(value)
            #expect(try await platform.installationBinding(name).load() == value)
            try await binding.delete(); #expect(try await binding.load() == nil)
        } catch { try? await binding.delete(); throw error }
    }

    @Test func cABIHandlesCloseAndCallerOwnedReplies() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try JSONSerialization.data(withJSONObject: ["accountURL":"https://localhost:1", "gatewayHost":"localhost", "gatewayPort":7443, "storageDirectory":directory.path])
        let client = config.withUnsafeBytes { sharedCreate($0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count)) }
        #expect(client > 0); #expect(sharedClients() == 1)
        #expect(config.withUnsafeBytes { sharedCreate($0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count)) } == 0)
        #expect(sharedReleaseClient(client) == 0)
        let restore = try await call(client, ["operation":"restore"])
        #expect((restore["snapshot"] as? [String:Any])?["state"] as? String == "signedOut")
        #expect(restore["error"] == nil)
        let closed = try await call(client, ["operation":"close"]); #expect(closed["error"] == nil)
        #expect(sharedReleaseClient(client) == 1)
        #expect(sharedActive() == 0); #expect(sharedClients() == 0)
        #expect(sharedReleaseClient(client) == 0)
        #expect(sharedCreate(nil, 0) == 0)
    }

    private func call(_ client: Int64, _ value: [String:Any]) async throws -> [String:Any] {
        let request = try JSONSerialization.data(withJSONObject: value)
        let operation = request.withUnsafeBytes { sharedSubmit(client, $0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count)) }
        try #require(operation > 0)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while .now < deadline {
            if let reply = sharedPoll(operation) {
                let data = Data(String(cString: reply).utf8); sharedFree(reply)
                // Poll ownership is independent: a second reply is released by the caller too.
                let second = try #require(sharedPoll(operation)); sharedFree(second)
                #expect(sharedRelease(operation) == 1); #expect(sharedRelease(operation) == 0)
                return try #require(JSONSerialization.jsonObject(with: data) as? [String:Any])
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        sharedCancel(operation); throw SharedFailure.operationFailed
    }
}
#endif

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite(.serialized)
struct V2ProfilePresentationThrottleTests {
    @Test("long cooldown survives page replacement without another remote read")
    func longCooldown() async throws {
        let reader = ProfileThrottlingReader(delay: 100_000)
        let repository = V2ProfilePresentationRepository(actorUserID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()),
            reader: reader, retryJitter: { 0 })
        let first = await repository.activate()
        let delay = try await requireThrottle { _ = try await repository.presentation(for: throttleKey(), activation: first) }
        #expect(delay > 99_900)
        await repository.deactivate(first)
        let second = await repository.activate()
        let retained = try await requireThrottle { _ = try await repository.presentation(for: throttleKey(), activation: second) }
        #expect(retained > 99_900)
        #expect(await reader.calls == 1)
        await repository.endAllActivations()
    }

    @Test("HTTP-date Retry-After is preserved by the presentation adapter", arguments: [429, 503])
    func httpDateCooldown(status: Int) async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        let transport = ProfileThrottleHTTPTransport(status: status,
            retryAfter: formatter.string(from: Date().addingTimeInterval(3600)))
        let client = try V2HTTPProfilePresentationClient(endpoint: #require(URL(string: "https://account.invalid/v2/profile-presentations/batch")),
            credentials: ProfileThrottleCredentials(), transport: transport)
        let delay = try await requireThrottle { _ = try await client.readPresentations([throttleKey()]) }
        #expect(delay > 3500 && delay <= 3600)
    }
    @Test("HTTP Retry-After preserves the server floor independently of an error body", arguments: ["2", "-5", "nan", "100000", "invalid"])
    func httpRetryAfter(header: String) async throws {
        let transport = ProfileThrottleHTTPTransport(status: 429, retryAfter: header)
        let client = try V2HTTPProfilePresentationClient(endpoint: #require(URL(string: "https://account.invalid/v2/profile-presentations/batch")),
            credentials: ProfileThrottleCredentials(), transport: transport)
        let expected: Double = header == "2" ? 2 : (header == "100000" ? 100000 : 1)
        await #expect(throws: V2ProfilePresentationError.throttled(retryAfter: expected)) {
            _ = try await client.readPresentations([throttleKey()])
        }
        let request = try #require(await transport.request)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-profile-token")
    }

    @Test("global authentication failure is distinct from an unavailable author", arguments: [401, 403])
    func httpAuthorization(status: Int) async throws {
        let client = try V2HTTPProfilePresentationClient(endpoint: #require(URL(string: "https://account.invalid/v2/profile-presentations/batch")),
            credentials: ProfileThrottleCredentials(), transport: ProfileThrottleHTTPTransport(status: status, retryAfter: nil))
        await #expect(throws: V2ClientMediaTransferError.authorizationUnavailable) {
            _ = try await client.readPresentations([throttleKey()])
        }
    }

    @Test("page and foreground reentry share the account cooldown; expiry resumes a real lookup")
    func cooldownAndRecovery() async throws {
        let reader = ProfileThrottlingReader()
        let repository = V2ProfilePresentationRepository(actorUserID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()),
            reader: reader, retryJitter: { 0 })
        let first = await repository.activate(), key = throttleKey()
        let duration = try await requireThrottle { _ = try await repository.presentation(for: key, activation: first) }
        #expect(duration > 0.8 && duration <= 1)
        await repository.deactivate(first)
        let second = await repository.activate()
        _ = try await requireThrottle { _ = try await repository.presentation(for: throttleKey(), activation: second) }
        await repository.endAllActivations()
        let third = await repository.activate()
        _ = try await requireThrottle { _ = try await repository.presentation(for: key, activation: third) }
        #expect(await reader.calls == 1)
        try await Task.sleep(for: .seconds(duration + 0.02))
        // The next real response is unavailable. The original 429 must never
        // have been cached as a thirty-second negative authorization result.
        #expect(try await repository.presentation(for: key, activation: third) == nil)
        #expect(await reader.calls == 2)
        await repository.endAllActivations()
    }

    @Test("cooldown adds positive jitter and belongs only to its repository")
    func jitterAndAccountIsolation() async throws {
        let reader = ProfileThrottlingReader()
        let first = V2ProfilePresentationRepository(actorUserID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()),
            reader: reader, retryJitter: { 0.5 })
        let activation = await first.activate()
        let duration = try await requireThrottle { _ = try await first.presentation(for: throttleKey(), activation: activation) }
        #expect(duration > 1.25 && duration <= 1.5)
        let second = V2ProfilePresentationRepository(actorUserID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()),
            reader: reader, retryJitter: { 0 })
        let other = await second.activate()
        #expect(try await second.presentation(for: throttleKey(), activation: other) == nil)
        #expect(await reader.calls == 2)
        await first.endAllActivations(); await second.endAllActivations()
    }

    @Test("a late 429 after backgrounding still prevents immediate foreground retries")
    func lateThrottle() async throws {
        let reader = ProfileThrottlingReader(holdFirst: true)
        let repository = V2ProfilePresentationRepository(actorUserID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()),
            reader: reader, retryJitter: { 0 })
        let activation = await repository.activate(), key = throttleKey()
        let waiting = Task { try await repository.presentation(for: key, activation: activation) }
        do {
            let deadline = ContinuousClock.now + .seconds(2)
            while await reader.calls == 0, .now < deadline { await Task.yield() }
            #expect(await reader.calls == 1)
            await repository.endAllActivations()
            await #expect(throws: CancellationError.self) { _ = try await waiting.value }
            await reader.release()
            let fresh = await repository.activate()
            _ = try await requireThrottle { _ = try await repository.presentation(for: throttleKey(), activation: fresh) }
            #expect(await reader.calls == 1)
            await repository.endAllActivations()
        } catch { await reader.release(); waiting.cancel(); _ = await waiting.result; await repository.endAllActivations(); throw error }
    }
}

private func throttleKey() -> V2ProfileViewLookupKey { .init(userID: .init(uuid: UUID()), context: .relationship) }
private func requireThrottle(_ action: () async throws -> Void) async throws -> TimeInterval {
    do { try await action(); Issue.record("Expected account cooldown"); return 0 }
    catch V2ProfilePresentationError.throttled(let seconds) { return seconds }
}
private struct ProfileThrottleCredentials: V2ClientMediaEdgeCredentialProvider {
    let device = DeviceID(uuid: UUID())
    func mediaEdgeCredentials() throws -> V2ClientMediaEdgeCredentials { .init(accessToken: "test-profile-token", deviceID: device) }
}
private actor ProfileThrottleHTTPTransport: V2ClientMediaEdgeHTTPTransport {
    let status: Int; let retryAfter: String?
    var request: URLRequest?
    init(status: Int, retryAfter: String?) { self.status = status; self.retryAfter = retryAfter }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        self.request = request
        let url = try #require(request.url)
        return (Data("not-json".utf8), try #require(HTTPURLResponse(url: url, statusCode: status,
            httpVersion: nil, headerFields: retryAfter.map { ["Retry-After": $0] } ?? [:])))
    }
}
private actor ProfileThrottlingReader: V2ProfilePresentationReading {
    var calls = 0
    private let holdFirst: Bool
    private let delay: TimeInterval
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(holdFirst: Bool = false, delay: TimeInterval = 1) { self.holdFirst = holdFirst; self.delay = delay }
    func readPresentations(_ keys: [V2ProfileViewLookupKey]) async throws -> V2ProfilePresentationBatch {
        calls += 1
        if calls == 1 {
            if holdFirst && !released { await withCheckedContinuation { continuation = $0 } }
            throw V2ProfilePresentationError.throttled(retryAfter: delay)
        }
        return .init(presentations: [:], unavailable: Set(keys), serverNow: Date())
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

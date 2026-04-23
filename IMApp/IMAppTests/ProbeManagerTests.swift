import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

private actor ProbeRequestGate {
    private var startedCount = 0
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var resumeContinuations: [CheckedContinuation<Void, Never>] = []
    private var isResumed = false

    func markStarted() {
        startedCount += 1

        var remainingWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        for (expectedCount, continuation) in startWaiters {
            if startedCount >= expectedCount {
                continuation.resume()
            } else {
                remainingWaiters.append((expectedCount, continuation))
            }
        }
        startWaiters = remainingWaiters
    }

    func waitUntilStarted(_ expectedCount: Int) async {
        guard startedCount < expectedCount else {
            return
        }

        await withCheckedContinuation { continuation in
            startWaiters.append((expectedCount, continuation))
        }
    }

    func waitForResume() async {
        guard !isResumed else {
            return
        }

        await withCheckedContinuation { continuation in
            resumeContinuations.append(continuation)
        }
    }

    func resumeAll() {
        isResumed = true
        let continuations = resumeContinuations
        resumeContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

struct ProbeManagerTests {
    private static let userID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private static let userEmail = "probe@example.com"

    @Test func stopAllForSignedOutCancelsConcurrentTestUpdates() async throws {
        let gate = ProbeRequestGate()
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                let body = try Self.authResponseBody()
                return HTTPFixtures.response(statusCode: 200, body: body)
            case ("GET", "/api/me"):
                await gate.markStarted()
                await gate.waitForResume()
                let body = try Self.userBody()
                return HTTPFixtures.response(statusCode: 200, body: body)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache()
        )

        _ = try await client.login(email: Self.userEmail, password: "password123", device: nil)
        let manager = await MainActor.run { ProbeManager(sessionClient: client) }

        await MainActor.run {
            manager.runConcurrentTest(requestCount: 2)
        }

        await gate.waitUntilStarted(2)
        await MainActor.run {
            manager.stopAllForSignedOut()
        }
        await gate.resumeAll()
        try? await Task.sleep(for: .milliseconds(50))

        let isRunning = await MainActor.run { manager.isConcurrentTestRunning }
        let successCount = await MainActor.run { manager.concurrentTestSuccessCount }
        let rateLimitedCount = await MainActor.run { manager.concurrentTestRateLimitedCount }
        let failureCount = await MainActor.run { manager.concurrentTestFailureCount }
        let status = await MainActor.run { manager.concurrentTestStatus }

        #expect(!isRunning)
        #expect(successCount == 0)
        #expect(rateLimitedCount == 0)
        #expect(failureCount == 0)
        #expect(status == "登录状态已失效，已停止并发测试。")
    }

    private static func userBody() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "id": userID.uuidString,
                "email": userEmail
            ]
        )
    }

    private static func authResponseBody() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "accessToken": "access-1",
                "expiresIn": 600,
                "refreshToken": "refresh-1",
                "refreshExpiresIn": 30 * 24 * 60 * 60,
                "user": [
                    "id": userID.uuidString,
                    "email": userEmail
                ]
            ]
        )
    }
}

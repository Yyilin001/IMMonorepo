import Foundation
import XCTest
@testable import IMV2ClientKit

final class V2HTTPExecutorTests: XCTestCase {
    func testTransportMetricReachesBoundedSinkWithRetryContext() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let diagnostics = V2NetworkDiagnostics()
        let scheduler = V2AccountWorkScheduler(configuration: .init(ordinaryLimit: 1))
        let executor = V2HTTPExecutor(session: session, scheduler: scheduler, metrics: { diagnostics.record($0) })
        let result = try await V2NetworkWorkScope.$context.withValue(.init(service: "accountAPI", priority: .critical, isRetry: true)) {
            try await executor.execute(URLRequest(url: URL(string: "https://example.test/ok")!), service: "accountAPI")
        }
        let metric = try XCTUnwrap(diagnostics.snapshot().samples.last)
        XCTAssertEqual(metric.receivedBytes, result.0.count)
        XCTAssertEqual(metric.statusCode, 200)
        XCTAssertEqual(metric.certainty, .responseReceived)
        XCTAssertEqual(metric.priority, .critical)
        XCTAssertTrue(metric.isRetry)
        XCTAssertGreaterThanOrEqual(metric.queued, 0)
        let active = await scheduler.snapshot().active
        XCTAssertEqual(active, 0)
        await scheduler.closeAndDrain()
    }
    func testCooldownSurvivesErrorBodyFailure() async throws {
        let scheduler = V2AccountWorkScheduler()
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let executor = V2HTTPExecutor(session: session, scheduler: scheduler)
        do {
            _ = try await executor.execute(URLRequest(url: URL(string: "https://example.test/status")!), budget: .init(timeout: 2, maximumResponseBytes: 1))
            XCTFail("Expected response cap")
        } catch let error as V2HTTPFailure { XCTAssertEqual(error.kind, .responseTooLarge) }
        do {
            _ = try await executor.execute(URLRequest(url: URL(string: "https://example.test/blackhole")!), budget: .init(timeout: 0.03))
            XCTFail("Expected header cooldown despite body rejection")
        } catch let error as V2HTTPFailure { XCTAssertEqual(error.certainty, .notStarted) }
        await scheduler.closeAndDrain()
    }
    func testRetryAfterAppliesToOtherRequestsBeforeTheyStartTransport() async throws {
        let scheduler = V2AccountWorkScheduler()
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let executor = V2HTTPExecutor(session: session, scheduler: scheduler)
        let response = try await executor.execute(URLRequest(url: URL(string: "https://example.test/status")!), service: "account")
        XCTAssertEqual(response.1.statusCode, 503)
        do {
            _ = try await executor.execute(URLRequest(url: URL(string: "https://example.test/blackhole")!), budget: .init(timeout: 0.03), service: "account")
            XCTFail("Expected service cooldown")
        } catch let error as V2HTTPFailure {
            XCTAssertEqual(error.certainty, .notStarted)
            XCTAssertEqual(error.kind, .deadlineExceeded)
        }
        let other = try await executor.execute(URLRequest(url: URL(string: "https://example.test/ok")!), service: "other")
        XCTAssertEqual(other.1.statusCode, 200)
        await scheduler.closeAndDrain()
    }
    func testDurableScopeConsumesSharedRetryQuotaAtLeafAdmission() async throws {
        let scheduler = V2AccountWorkScheduler()
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        for _ in 0..<5 {
            let permit = try await scheduler.acquire(.init(service: "account", isRetry: true))
            _ = await scheduler.release(permit)
        }
        do {
            _ = try await V2NetworkWorkScope.$context.withValue(.init(service: "durableOperations", isRetry: true)) {
                try await V2HTTPExecutor(session: session, scheduler: scheduler).execute(
                    URLRequest(url: URL(string: "https://example.test/blackhole")!), budget: .init(timeout: 0.03))
            }
            XCTFail("Expected quota wait to consume deadline")
        } catch let error as V2HTTPFailure { XCTAssertEqual(error.certainty, .notStarted) }
        await scheduler.closeAndDrain()
    }
    func testRetryAfterRejectsUnsafeAndAcceptsDate() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(V2RetryAfter.date(from: "120", now: now), now.addingTimeInterval(120))
        for invalid in ["-1", "1.5", "18446744073709551616", "999999999", "nan", ""] {
            XCTAssertNil(V2RetryAfter.date(from: invalid, now: now))
        }
        XCTAssertEqual(V2RetryAfter.date(from: "Thu, 01 Jan 1970 00:02:00 GMT", now: now), now.addingTimeInterval(120))
    }
    func testStatusPreservesUnknownBusinessCertainty() {
        let response = HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 503, httpVersion: nil, headerFields: ["Retry-After": "60"])!
        let error = V2HTTPFailure.status(response, service: "profile", now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(error.statusCode, 503)
        XCTAssertEqual(error.certainty, .responseReceived)
        XCTAssertEqual(error.retryAfter, Date(timeIntervalSince1970: 60))
    }
    func testAdmissionDeadlineIncludesQueueAndNeverStartsTransport() async throws {
        let scheduler = V2AccountWorkScheduler(configuration: .init(ordinaryLimit: 1))
        let permit = try await scheduler.acquire(.init(service: "account"))
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await V2HTTPExecutor(session: session, scheduler: scheduler).execute(
                URLRequest(url: URL(string: "https://example.test/blackhole")!), budget: .init(timeout: 0.03))
            XCTFail("Expected queue deadline")
        } catch let error as V2HTTPFailure {
            XCTAssertEqual(error.kind, .deadlineExceeded)
            XCTAssertEqual(error.certainty, .notStarted)
        }
        let state = await scheduler.snapshot()
        XCTAssertEqual(state.active, 1); XCTAssertEqual(state.waiting, 0)
        _ = await scheduler.release(permit)
    }
    func testStreamingCap() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await V2HTTPExecutor(session: session).execute(URLRequest(url: URL(string: "https://example.test/oversize")!), budget: .init(timeout: 2, maximumResponseBytes: 4))
            XCTFail("must reject unknown-length streamed overflow")
        } catch let error as V2HTTPFailure {
            XCTAssertEqual(error.kind, .responseTooLarge)
        }
    }
    func testExactCapReturnsRawNonSuccessResponse() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await V2HTTPExecutor(session: session).execute(URLRequest(url: URL(string: "https://example.test/status")!), budget: .init(timeout: 2, maximumResponseBytes: 6))
        XCTAssertEqual(data.count, 6)
        XCTAssertEqual(response.statusCode, 503)
    }
    func testDeadlineStopsBlackHole() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let start = ContinuousClock.now
        do {
            _ = try await V2HTTPExecutor(session: session).execute(URLRequest(url: URL(string: "https://example.test/blackhole")!), budget: .init(timeout: 0.05))
            XCTFail("must time out")
        } catch let error as V2HTTPFailure {
            XCTAssertEqual(error.kind, .deadlineExceeded)
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }
    func testCancellationStopsBlackHole() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let task = Task { try await V2HTTPExecutor(session: session).execute(URLRequest(url: URL(string: "https://example.test/blackhole")!)) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do { _ = try await task.value; XCTFail("must cancel") }
        catch is CancellationError {}
    }
    func testExpiredEndToEndDeadlineNeverStarts() async throws {
        do {
            _ = try await V2HTTPExecutor().execute(URLRequest(url: URL(string: "https://example.test")!), budget: .init(deadline: .now.advanced(by: .seconds(-1))))
            XCTFail("must refuse already expired work")
        } catch let error as V2HTTPFailure {
            XCTAssertEqual(error.kind, .deadlineExceeded)
            XCTAssertEqual(error.certainty, .notStarted)
        }
    }
    func testHTTPSRequiredBeforeStarting() async throws {
        do { _ = try await V2HTTPExecutor().execute(URLRequest(url: URL(string: "http://example.test")!)); XCTFail("must reject") }
        catch let error as V2HTTPFailure { XCTAssertEqual(error.certainty, .notStarted) }
    }
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPExecutorProtocol.self]
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }
}

private final class HTTPExecutorProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.path != "/blackhole" else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: request.url?.path == "/status" ? 503 : 200, httpVersion: "HTTP/1.1", headerFields: request.url?.path == "/status" ? ["Retry-After": "60"] : nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([1, 2, 3]))
        client?.urlProtocol(self, didLoad: Data([4, 5, 6]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

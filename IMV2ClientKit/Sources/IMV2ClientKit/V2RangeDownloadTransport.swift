import Foundation

/// Headers are validated before any body bytes are accepted. Implementations
/// drain cancellation before returning so the physical byte permit stays held.
public struct V2RangeDownloadResponse: Sendable {
    public let response: HTTPURLResponse
    public let metric: V2ResourceTransferMetric?
    private let diagnostics: V2NetworkDiagnostics?
    public init(response: HTTPURLResponse) { self.response = response; metric = nil; diagnostics = nil }
    init(response: HTTPURLResponse, metric: V2ResourceTransferMetric, diagnostics: V2NetworkDiagnostics?) {
        self.response = response; self.metric = metric; self.diagnostics = diagnostics
    }
    func record(verifiedPrefixBytes: Int64? = nil) {
        if let metric { diagnostics?.record(metric.verifyingRangeRebuild(prefixBytes: verifiedPrefixBytes)) }
    }
}
public protocol V2RangeDownloadTransport: Sendable {
    func stream(_ request: URLRequest, maximumBytes: Int64,
                receiveResponse: @escaping @Sendable (HTTPURLResponse) throws -> Void,
                consume: @escaping @Sendable (Data) throws -> Void) async throws -> V2RangeDownloadResponse
}

public struct V2URLSessionRangeDownloadTransport: V2RangeDownloadTransport, Sendable {
    private let session: URLSession
    private let scheduler: V2AccountWorkScheduler?
    private let diagnostics: V2NetworkDiagnostics?
    public init(session: URLSession = V2SecureURLSession.mediaProvider, scheduler: V2AccountWorkScheduler? = nil, diagnostics: V2NetworkDiagnostics? = nil) {
        self.session = session; self.scheduler = scheduler; self.diagnostics = diagnostics
    }
    public func stream(_ request: URLRequest, maximumBytes: Int64,
                       receiveResponse: @escaping @Sendable (HTTPURLResponse) throws -> Void,
                       consume: @escaping @Sendable (Data) throws -> Void) async throws -> V2RangeDownloadResponse {
        guard request.timeoutInterval.isFinite,request.timeoutInterval > 0 else { throw V2ClientMediaTransferError.invalidTarget }
        let transportDeadline = ContinuousClock.now.advanced(by: .seconds(min(60, request.timeoutInterval)))
        let deadline = min(transportDeadline, V2HTTPRequestDeadline.deadline(for: request) ?? transportDeadline, V2HTTPRequestDeadline.current ?? transportDeadline)
        let permit = try await scheduler?.acquire(.init(service: "mediaProvider", priority: .interactive, kind: .byteTransfer, isRetry: V2NetworkWorkScope.context?.isRetry ?? false), deadline: deadline)
        do {
            let response = try await perform(request, maximumBytes: maximumBytes, deadline: deadline, receiveResponse: receiveResponse, consume: consume)
            if [429,503].contains(response.response.statusCode), let retry = V2RetryAfter.date(from: response.response.value(forHTTPHeaderField: "Retry-After")) {
                await scheduler?.coolDown(service: "mediaProvider", for: retry.timeIntervalSinceNow)
            }
            if let permit { _ = await scheduler?.release(permit) }
            return response
        } catch {
            if let failure = error as? V2HTTPFailure, [429,503].contains(failure.statusCode ?? 0), let retry = failure.retryAfter {
                await scheduler?.coolDown(service: "mediaProvider", for: retry.timeIntervalSinceNow)
            }
            if let permit { _ = await scheduler?.release(permit) }
            throw error
        }
    }
    private func perform(_ request: URLRequest, maximumBytes: Int64, deadline: ContinuousClock.Instant,
                         receiveResponse: @escaping @Sendable (HTTPURLResponse) throws -> Void,
                         consume: @escaping @Sendable (Data) throws -> Void) async throws -> V2RangeDownloadResponse {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw V2HTTPFailure(kind: .deadlineExceeded, service: "mediaProvider") }
        guard let url = request.url, url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.fragment == nil,
              maximumBytes >= 0, request.timeoutInterval.isFinite, request.timeoutInterval > 0 else { throw V2ClientMediaTransferError.invalidTarget }
        let delegate = V2RangeTaskDelegate(diagnostics: diagnostics, mode: request.value(forHTTPHeaderField: "Range") == nil ? .download : .rangeDownload, retry: V2NetworkWorkScope.context?.isRetry ?? false, maximumBytes: maximumBytes, receiveResponse: receiveResponse, consume: consume)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: V2RangeDownloadResponse.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        let task = session.dataTask(with: request)
                        task.delegate = delegate
                        delegate.start(task, continuation: continuation)
                    }
                }
                group.addTask {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    let failure = V2HTTPFailure(kind: .deadlineExceeded, service: "mediaProvider")
                    delegate.cancel(error: failure)
                    throw failure
                }
                defer { group.cancelAll(); delegate.cancel() }
                return try await group.next()!
            }
        } onCancel: { delegate.cancel() }
    }
}

private final class V2RangeTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let diagnostics: V2NetworkDiagnostics?
    private let mode: V2ResourceTransferMetric.Mode
    private let retry: Bool
    private let started = ContinuousClock.now
    private let maximumBytes: Int64
    private let receiveResponse: @Sendable (HTTPURLResponse) throws -> Void
    private let consume: @Sendable (Data) throws -> Void
    private var task: URLSessionTask?
    private var cancelled = false
    private var continuation: CheckedContinuation<V2RangeDownloadResponse, Error>?
    private var response: HTTPURLResponse?
    private var count: Int64 = 0
    private var failure: (any Error)?
    init(diagnostics: V2NetworkDiagnostics?, mode: V2ResourceTransferMetric.Mode, retry: Bool, maximumBytes: Int64, receiveResponse: @escaping @Sendable (HTTPURLResponse) throws -> Void, consume: @escaping @Sendable (Data) throws -> Void) {
        self.diagnostics = diagnostics; self.mode = mode; self.retry = retry
        self.maximumBytes = maximumBytes; self.receiveResponse = receiveResponse; self.consume = consume
    }
    func start(_ task: URLSessionTask, continuation: CheckedContinuation<V2RangeDownloadResponse, Error>) {
        let cancel = lock.withLock { self.task = task; self.continuation = continuation; return cancelled }
        task.resume(); if cancel { task.cancel() }
    }
    func cancel(error: (any Error)? = nil) {
        let task = lock.withLock { cancelled = true; if failure == nil { failure = error }; return self.task }
        task?.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        v2ForwardAuthenticationChallenge(session: session, task: task, challenge: challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse else { throw V2ClientMediaTransferError.invalidResponse }
            lock.withLock { self.response = http }
            try receiveResponse(http)
            guard http.expectedContentLength <= maximumBytes else { throw V2ClientMediaTransferError.byteCountMismatch }
            lock.withLock { self.response = http }
            completionHandler(.allow)
        } catch { cancel(error: error); completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            let allowed = lock.withLock {
                guard !cancelled, Int64(data.count) <= maximumBytes - count else { return false }
                count += Int64(data.count); return true
            }
            guard allowed else { throw V2ClientMediaTransferError.byteCountMismatch }
            // URLSession supplies bounded chunks; cap each file callback independently.
            var offset = 0
            while offset < data.count {
                let end = min(offset + 64 * 1024, data.count)
                try consume(data.subdata(in: offset..<end)); offset = end
            }
        } catch { cancel(error: error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let outcome = lock.withLock {
            let result = (continuation, response, failure ?? error)
            continuation = nil; self.task = nil
            return result
        }
        if outcome.0 != nil {
            let elapsed = started.duration(to: .now).components
            let metric = V2ResourceTransferMetric(mode: mode, statusCode: outcome.1?.statusCode,
                bodyBytesSent: task.countOfBytesSent, bodyBytesReceived: task.countOfBytesReceived,
                elapsed: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                retryAttempt: retry, cancelled: (outcome.2 as? URLError)?.code == .cancelled || lock.withLock { cancelled },
                failed: outcome.2 != nil)
            if let error = outcome.2 { diagnostics?.record(metric); outcome.0?.resume(throwing: error) }
            else if let response = outcome.1 {
                outcome.0?.resume(returning: V2RangeDownloadResponse(response: response, metric: metric, diagnostics: diagnostics))
            } else { diagnostics?.record(metric); outcome.0?.resume(throwing: V2ClientMediaTransferError.invalidResponse) }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

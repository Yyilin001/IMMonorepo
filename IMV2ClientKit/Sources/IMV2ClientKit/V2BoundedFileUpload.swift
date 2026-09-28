import Foundation

/// File upload task delegate drops response bytes after bounded accounting;
/// it never collects a provider error body or persists a signed request.
struct V2BoundedFileUpload: Sendable {
    let session: URLSession
    var diagnostics: V2NetworkDiagnostics? = nil
    var metricMode: V2ResourceTransferMetric.Mode = .upload
    func send(_ request: URLRequest,file: URL,deadline: ContinuousClock.Instant) async throws -> HTTPURLResponse {
        let deadline = min(deadline, V2HTTPRequestDeadline.deadline(for: request) ?? deadline, V2HTTPRequestDeadline.current ?? deadline)
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw V2HTTPFailure(kind: .deadlineExceeded, service: "mediaProvider") }
        let delegate = V2FileUploadDelegate(diagnostics: diagnostics, mode: metricMode, retry: V2NetworkWorkScope.context?.isRetry ?? false)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: HTTPURLResponse.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        let task = session.uploadTask(with: request,fromFile: file)
                        task.delegate = delegate
                        delegate.start(task,continuation: continuation)
                    }
                }
                group.addTask {
                    try await Task.sleep(until: deadline,clock: .continuous)
                    let failure = V2HTTPFailure(kind: .deadlineExceeded,service:"mediaProvider")
                    delegate.cancel(error: failure)
                    throw failure
                }
                defer { group.cancelAll(); delegate.cancel() }
                return try await group.next()!
            }
        } onCancel: { delegate.cancel() }
    }
}
private final class V2FileUploadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let diagnostics: V2NetworkDiagnostics?
    private let mode: V2ResourceTransferMetric.Mode
    private let retry: Bool
    private let started = ContinuousClock.now
    init(diagnostics: V2NetworkDiagnostics?, mode: V2ResourceTransferMetric.Mode, retry: Bool) {
        self.diagnostics = diagnostics; self.mode = mode; self.retry = retry
    }
    private var task: URLSessionTask?
    private var cancelled = false
    private var continuation: CheckedContinuation<HTTPURLResponse,Error>?
    private var response: HTTPURLResponse?
    private var bytes = 0
    private var failure: (any Error)?
    func start(_ task: URLSessionTask,continuation: CheckedContinuation<HTTPURLResponse,Error>) {
        let cancel = lock.withLock { self.task = task; self.continuation = continuation; return cancelled }
        // Resume even an already-cancelled task: its completion callback is the
        // physical drain barrier for the waiting continuation and byte permit.
        task.resume(); if cancel { task.cancel() }
    }
    func cancel(error: (any Error)? = nil) {
        let task = lock.withLock { cancelled = true; if let error { failure = error }; return self.task }
        task?.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        v2ForwardAuthenticationChallenge(session: session, task: task, challenge: challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession,dataTask: URLSessionDataTask,didReceive response: URLResponse,completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { cancel(error: V2ClientMediaTransferError.invalidResponse); completionHandler(.cancel); return }
        lock.withLock { self.response = http }
        if http.expectedContentLength > 512 * 1024 { cancel(error: V2RangeDownloadError.responseTooLarge); completionHandler(.cancel) }
        else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession,dataTask: URLSessionDataTask,didReceive data: Data) {
        let overflow = lock.withLock { bytes += data.count; return bytes > 512 * 1024 }
        if overflow { cancel(error: V2RangeDownloadError.responseTooLarge) }
    }
    func urlSession(_ session: URLSession,task: URLSessionTask,didCompleteWithError error: (any Error)?) {
        let outcome: (CheckedContinuation<HTTPURLResponse,Error>?,HTTPURLResponse?,(any Error)?) = lock.withLock {
            let result = (continuation,response,failure ?? error)
            continuation = nil; self.task = nil
            return result
        }
        if outcome.0 != nil {
            let elapsed = started.duration(to: .now).components
            diagnostics?.record(.init(mode: mode, statusCode: outcome.1?.statusCode,
                bodyBytesSent: task.countOfBytesSent, bodyBytesReceived: task.countOfBytesReceived,
                elapsed: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                retryAttempt: retry, cancelled: (outcome.2 as? URLError)?.code == .cancelled || lock.withLock { cancelled },
                failed: outcome.2 != nil))
        }
        if let error = outcome.2 { outcome.0?.resume(throwing: error) }
        else if let response = outcome.1 { outcome.0?.resume(returning: response) }
        else { outcome.0?.resume(throwing: V2ClientMediaTransferError.invalidResponse) }
    }
    func urlSession(_ session: URLSession,task: URLSessionTask,willPerformHTTPRedirection response: HTTPURLResponse,newRequest request: URLRequest,completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

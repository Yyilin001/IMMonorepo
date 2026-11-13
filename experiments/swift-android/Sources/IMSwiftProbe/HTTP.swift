import Foundation
import FoundationNetworking
import Synchronization

private struct HTTPResult: Sendable { let status: Int; let body: Data; let redirect: Bool }

// Uses the portable delegate API, with a strict cap before appending each chunk.
// Completion is published only by didCompleteWithError, including cancellation.
private final class HTTPRequest: NSObject, URLSessionDataDelegate, Sendable {
    struct State: Sendable {
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<HTTPResult, any Error>?
        var data = Data()
        var status = 0
        var redirect = false
        var cancelled = false
        var oversized = false
    }
    let state = Mutex(State())
    let limit: Int
    init(limit: Int) { self.limit = limit }
    func execute(_ url: URL) async throws -> HTTPResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: url)
                let cancelled = state.withLock {
                    $0.task = task
                    $0.continuation = continuation
                    return $0.cancelled
                }
                task.resume()
                if cancelled { task.cancel() }
            }
        } onCancel: {
            let task = self.state.withLock { $0.cancelled = true; return $0.task }
            task?.cancel()
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let oversized = response.expectedContentLength > Int64(limit)
        state.withLock { $0.status = (response as? HTTPURLResponse)?.statusCode ?? 0; $0.oversized = oversized }
        completionHandler(oversized ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let stop = state.withLock {
            if $0.oversized || data.count > limit - $0.data.count { $0.oversized = true; return true }
            $0.data.append(data)
            return false
        }
        if stop { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        state.withLock { $0.redirect = true }
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let completion = state.withLock { state -> (CheckedContinuation<HTTPResult, any Error>?, Result<HTTPResult, any Error>) in
            let continuation = state.continuation
            state.continuation = nil
            state.task = nil
            if state.oversized { return (continuation, .failure(ProbeFailure.oversized)) }
            if state.cancelled { return (continuation, .failure(CancellationError())) }
            if let error { return (continuation, .failure(error)) }
            return (continuation, .success(.init(status: state.status, body: state.data, redirect: state.redirect)))
        }
        completion.0?.resume(with: completion.1)
    }
}

func httpProbe(_ input: ProbeInput) async throws -> ProbeResult {
    guard let raw = input.url, let url = URL(string: raw),
          url.scheme == "https" || (url.scheme == "http" && url.host == "127.0.0.1") else {
        throw ProbeFailure.assertion("only HTTPS or loopback HTTP fixtures allowed")
    }
    let request = HTTPRequest(limit: input.maximumBytes ?? 65_536)
    let result = try await withThrowingTaskGroup(of: HTTPResult.self) { group in
        group.addTask { try await request.execute(url) }
        group.addTask {
            try await Task.sleep(for: .milliseconds(input.deadlineMilliseconds ?? 10_000))
            throw ProbeFailure.deadline
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
    try Task.checkCancellation()
    return .init(outcome: "ok", values: ["status": String(result.status), "bytes": String(result.body.count),
        "body": String(decoding: result.body.prefix(128), as: UTF8.self), "redirectRejected": String(result.redirect)])
}

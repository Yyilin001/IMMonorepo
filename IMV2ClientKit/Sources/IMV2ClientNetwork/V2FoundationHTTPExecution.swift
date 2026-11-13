import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2ClientPlatform

/// The delegate path is also compiled on Apple so its lifecycle can be tested
/// without an emulator. Production Apple requests keep URLSession.AsyncBytes.
final class V2FoundationHTTPExecution: NSObject, URLSessionDataDelegate, V2HTTPTransportExecution, @unchecked Sendable {
    private struct State {
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>?
        var headers: Task<Void, Never>?
        var onResponse: (@Sendable (HTTPURLResponse) async -> Void)?
        var body = Data()
        var response: HTTPURLResponse?
        var failure: (any Error)?
        var cancelled = false
        var started = false
        var limit = 0
        var service = "account"
    }
    private let state = V2Lock(initialState: State())
    private let pool: V2FoundationHTTPSession
    private let events: V2HTTPTransportEvents
    init(pool: V2FoundationHTTPSession, events: V2HTTPTransportEvents) { self.pool = pool; self.events = events }
    convenience init(session: URLSession, events: V2HTTPTransportEvents) {
        self.init(pool: .init(configurationSource: session), events: events)
    }
    var observation: (Int, Bool, Int, Int?) { state.withLock { (0, false, $0.body.count, $0.response?.statusCode) } }
    var phaseTiming: V2HTTPPhaseTiming? { nil }

    func execute(_ request: URLRequest, maximumResponseBytes: Int, service: String,
                 onResponse: @escaping @Sendable (HTTPURLResponse) async -> Void) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard !state.withLock({ $0.cancelled }) else { throw CancellationError() }
        guard maximumResponseBytes >= 0 else { throw V2HTTPFailure(kind: .invalidEndpoint, service: service, certainty: .notStarted) }
        guard state.withLock({ state in
            guard !state.started else { return false }
            state.started = true
            return true
        }) else { throw V2HTTPFailure(kind: .invalidResponse, service: service, certainty: .notStarted) }
        let result: Result<(Data, HTTPURLResponse), any Error>
        do {
            let value = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let task = pool.makeTask(request, execution: self)
                    state.withLock { state in
                        state.limit = maximumResponseBytes; state.service = service
                        state.onResponse = onResponse; state.continuation = continuation; state.task = task
                    }
                    task.resume()
                    if state.withLock({ $0.cancelled }) { task.cancel() }
                }
            } onCancel: { self.cancel() }
            result = .success(value)
        } catch { result = .failure(error) }
        // Header admission callbacks also belong to the physical operation.
        let headers = state.withLock { $0.headers }
        await headers?.value
        state.withLock { $0.headers = nil; $0.onResponse = nil }
        try Task.checkCancellation()
        return try result.get()
    }
    func cancel() {
        events.active()
        let tasks = state.withLock { $0.cancelled = true; return ($0.task, $0.headers) }
        tasks.1?.cancel()
        tasks.0?.cancel()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        events.active()
        guard let response = response as? HTTPURLResponse else {
            state.withLock { $0.failure = V2HTTPFailure(kind: .invalidResponse, service: $0.service) }
            completionHandler(.cancel); return
        }
        state.withLock { state in
            state.response = response
            let callback = state.onResponse
            state.headers = Task { [self] in
                await callback?(response)
                let stop = self.state.withLock { state in
                    if response.expectedContentLength > Int64(state.limit) {
                        state.failure = V2HTTPFailure(kind: .responseTooLarge, service: state.service, statusCode: response.statusCode)
                    }
                    return state.cancelled || state.failure != nil
                }
                completionHandler(stop ? .cancel : .allow)
            }
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let stop = state.withLock { state -> Bool in
            guard !state.cancelled, state.failure == nil else { return true }
            guard data.count <= state.limit - state.body.count else {
                state.failure = V2HTTPFailure(kind: .responseTooLarge, service: state.service, statusCode: state.response?.statusCode)
                return true
            }
            state.body.append(data)
            return false
        }
        if stop { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        events.active()
        let completion = state.withLock { state -> (CheckedContinuation<(Data, HTTPURLResponse), any Error>?, Result<(Data, HTTPURLResponse), any Error>) in
            let continuation = state.continuation
            state.continuation = nil; state.task = nil
            if let failure = state.failure { return (continuation, .failure(failure)) }
            if state.cancelled { return (continuation, .failure(CancellationError())) }
            if let error { return (continuation, .failure(error)) }
            guard let response = state.response else {
                return (continuation, .failure(V2HTTPFailure(kind: .invalidResponse, service: state.service)))
            }
            return (continuation, .success((state.body, response)))
        }
        completion.0?.resume(with: completion.1)
    }
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) { events.waiting() }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        v2ForwardAuthenticationChallenge(session: session, task: task, challenge: challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

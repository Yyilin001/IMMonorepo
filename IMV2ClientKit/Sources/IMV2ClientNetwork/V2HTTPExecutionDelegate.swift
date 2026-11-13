import Foundation
#if canImport(Darwin)
final class V2HTTPExecutionDelegate: NSObject, URLSessionTaskDelegate, V2HTTPTransportExecution, @unchecked Sendable {
    private let lock = NSLock()
    private let session: URLSession
    private let events: V2HTTPTransportEvents
    init(session: URLSession = V2SecureURLSession.account, events: V2HTTPTransportEvents = .init()) {
        self.session = session; self.events = events
    }
    func execute(_ request: URLRequest, maximumResponseBytes: Int, service: String,
                 onResponse: @escaping @Sendable (HTTPURLResponse) async -> Void) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard !lock.withLock({ isCancelled }) else { throw CancellationError() }
        guard maximumResponseBytes >= 0 else { throw V2HTTPFailure(kind: .invalidEndpoint, service: service, certainty: .notStarted) }
        let (bytes, response) = try await session.bytes(for: request, delegate: self)
        guard let response = response as? HTTPURLResponse else {
            throw V2HTTPFailure(kind: .invalidResponse, service: service)
        }
        self.record(response: response.statusCode, bytes: 0)
        await onResponse(response)
        guard response.expectedContentLength <= Int64(maximumResponseBytes) else {
            self.cancel()
            throw V2HTTPFailure(kind: .responseTooLarge, service: service, statusCode: response.statusCode)
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumResponseBytes else {
                self.record(response: response.statusCode, bytes: data.count)
                self.cancel()
                throw V2HTTPFailure(kind: .responseTooLarge, service: service, statusCode: response.statusCode)
            }
            data.append(byte)
            if data.count.isMultiple(of: 4096) { self.record(response: response.statusCode, bytes: data.count) }
        }
        self.record(response: response.statusCode, bytes: data.count)
        return (data, response)
    }
    private var task: URLSessionTask?
    private var isCancelled = false
    private var transactions = 0
    private var reused = false
    private var phases: V2HTTPPhaseTiming?
    var phaseTiming: V2HTTPPhaseTiming? { lock.withLock { phases } }
    private var receivedBytes = 0
    private var responseStatus: Int?
    var observation: (Int, Bool, Int, Int?) { lock.withLock { (transactions, reused, receivedBytes, responseStatus) } }
    func record(response: Int, bytes: Int) { events.active(); lock.withLock { responseStatus = response; receivedBytes = bytes } }
    func cancel() {
        events.active()
        let task = lock.withLock { isCancelled = true; return self.task }
        task?.cancel()
    }
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        events.waiting()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        v2ForwardAuthenticationChallenge(session: session, task: task, challenge: challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let cancel = lock.withLock { self.task = task; return isCancelled }
        if cancel { task.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock {
            transactions = metrics.transactionMetrics.count
            reused = metrics.transactionMetrics.contains { $0.isReusedConnection }
            func sum(_ field: (URLSessionTaskTransactionMetrics) -> TimeInterval?) -> TimeInterval? {
                let values = metrics.transactionMetrics.compactMap(field)
                guard !values.isEmpty else { return nil }
                let total = values.reduce(0, +)
                return total.isFinite ? total : nil
            }
            let rawProtocol = metrics.transactionMetrics.last?.networkProtocolName
            phases = .init(dns: sum { V2HTTPPhaseTiming.duration($0.domainLookupStartDate, $0.domainLookupEndDate) },
                connect: sum { V2HTTPPhaseTiming.duration($0.connectStartDate, $0.connectEndDate) },
                tls: sum { V2HTTPPhaseTiming.duration($0.secureConnectionStartDate, $0.secureConnectionEndDate) },
                request: sum { V2HTTPPhaseTiming.duration($0.requestStartDate, $0.requestEndDate) },
                response: sum { V2HTTPPhaseTiming.duration($0.responseStartDate, $0.responseEndDate) },
                networkProtocol: rawProtocol.map { ["h2", "h3", "http/1.1"].contains($0) ? $0 : "other" })
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

#endif

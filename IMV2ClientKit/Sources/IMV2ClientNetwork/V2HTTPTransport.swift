import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One execution is owned by one request. Cancellation must stop physical I/O;
/// execute must drain its callbacks before returning. Implementations must cap
/// buffering, reject redirects and call onResponse before consuming the body.
public protocol V2HTTPTransport: Sendable {
    func makeExecution(events: V2HTTPTransportEvents) -> any V2HTTPTransportExecution
}

public protocol V2HTTPTransportExecution: Sendable {
    var observation: (Int, Bool, Int, Int?) { get }
    var phaseTiming: V2HTTPPhaseTiming? { get }
    func execute(_ request: URLRequest, maximumResponseBytes: Int, service: String,
                 onResponse: @escaping @Sendable (HTTPURLResponse) async -> Void) async throws -> (Data, HTTPURLResponse)
    func cancel()
}

public struct V2HTTPTransportEvents: Sendable {
    public let waiting: @Sendable () -> Void
    public let active: @Sendable () -> Void
    public init(waiting: @escaping @Sendable () -> Void = {}, active: @escaping @Sendable () -> Void = {}) {
        self.waiting = waiting; self.active = active
    }
}

/// Apple keeps the caller's exact session. FoundationNetworking owns a session
/// per adapter with the supplied configuration and forwarded authentication policy.
public struct V2URLSessionHTTPTransport: V2HTTPTransport {
    private let session: URLSession
    #if !canImport(Darwin)
    private let pool: V2FoundationHTTPSession
    #endif
    public init(session: URLSession = V2SecureURLSession.account) {
        self.session = session
        #if !canImport(Darwin)
        pool = .init(configurationSource: session)
        #endif
    }
    public func makeExecution(events: V2HTTPTransportEvents) -> any V2HTTPTransportExecution {
        #if canImport(Darwin)
        V2HTTPExecutionDelegate(session: session, events: events)
        #else
        V2FoundationHTTPExecution(pool: pool, events: events)
        #endif
    }
}


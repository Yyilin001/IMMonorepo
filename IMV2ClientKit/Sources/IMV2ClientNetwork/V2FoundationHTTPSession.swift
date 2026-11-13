import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2ClientPlatform

/// Use a session router so corelibs data completion does not rely on task.delegate.
/// Own one session per transport and route by task identity, preserving pooling.
/// The router retains active executions only until didCompleteWithError.
final class V2FoundationHTTPSession: Sendable {
    private let router: Router
    private let session: URLSession
    init(configurationSource: URLSession) {
        router = Router(authenticationSource: configurationSource)
        session = URLSession(configuration: configurationSource.configuration, delegate: router, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func makeTask(_ request: URLRequest, execution: V2FoundationHTTPExecution) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        router.executions.withLock { $0[task.taskIdentifier] = execution }
        return task
    }
    private final class Router: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        // All mutable state is protected by the lock; source session is immutable.
        let executions = V2Lock<[Int: V2FoundationHTTPExecution]>(initialState: [:])
        private let authenticationSource: URLSession
        init(authenticationSource: URLSession) { self.authenticationSource = authenticationSource }
        private func execution(_ task: URLSessionTask) -> V2FoundationHTTPExecution? {
            executions.withLock { $0[task.taskIdentifier] }
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let execution = execution(dataTask) else { completionHandler(.cancel); return }
            execution.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            execution(dataTask)?.urlSession(session, dataTask: dataTask, didReceive: data)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let execution = executions.withLock { $0.removeValue(forKey: task.taskIdentifier) }
            execution?.urlSession(session, task: task, didCompleteWithError: error)
        }
        func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
            execution(task)?.urlSession(session, taskIsWaitingForConnectivity: task)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            v2ForwardAuthenticationChallenge(session: authenticationSource, task: task, challenge: challenge, completionHandler: completionHandler)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

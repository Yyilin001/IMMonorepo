import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Per-task instrumentation must preserve the injected session's authentication
/// policy. Prefer its task callback, then its session callback; absent either,
/// Foundation performs its normal system trust evaluation.
package func v2ForwardAuthenticationChallenge(
    session: URLSession, task: URLSessionTask, challenge: URLAuthenticationChallenge,
    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
) {
    #if canImport(ObjectiveC)
    if let delegate = session.delegate as? any URLSessionTaskDelegate,
       delegate.urlSession?(session, task: task, didReceive: challenge, completionHandler: completionHandler) != nil {
        return
    }
    if let delegate = session.delegate,
       delegate.urlSession?(session, didReceive: challenge, completionHandler: completionHandler) != nil {
        return
    }
    #else
    if let delegate = session.delegate as? any URLSessionTaskDelegate {
        delegate.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
        return
    }
    if let delegate = session.delegate {
        delegate.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
        return
    }
    #endif
    completionHandler(.performDefaultHandling, nil)
}

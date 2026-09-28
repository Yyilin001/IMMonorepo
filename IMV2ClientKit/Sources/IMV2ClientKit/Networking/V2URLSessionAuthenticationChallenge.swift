import Foundation

/// Per-task instrumentation must preserve the injected session's authentication
/// policy. Prefer its task callback, then its session callback; absent either,
/// Foundation performs its normal system trust evaluation.
func v2ForwardAuthenticationChallenge(
    session: URLSession, task: URLSessionTask, challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
) {
    if let delegate = session.delegate as? any URLSessionTaskDelegate,
       delegate.urlSession?(session, task: task, didReceive: challenge, completionHandler: completionHandler) != nil {
        return
    }
    if let delegate = session.delegate,
       delegate.urlSession?(session, didReceive: challenge, completionHandler: completionHandler) != nil {
        return
    }
    completionHandler(.performDefaultHandling, nil)
}

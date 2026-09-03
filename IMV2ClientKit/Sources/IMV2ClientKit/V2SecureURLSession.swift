import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sensitive account and signed-media exchanges do not share cookies, cache,
/// HTTP credentials, or redirect policy with unrelated application traffic.
public enum V2SecureURLSession {
    /// One account-edge pool is shared by the small transport adapters. This
    /// preserves cookie/credential isolation while allowing HTTP/2 connection
    /// and TLS-session reuse across authentication, profile, device and media
    /// target-resolution requests.
    public static let account = make()

    /// Provider bytes stay in a separate pool because signed target headers
    /// have a different trust and credential boundary from the account edge.
    public static let mediaProvider = make()

    public static func make() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        return URLSession(
            configuration: configuration,
            delegate: V2RejectingRedirectDelegate.shared,
            delegateQueue: nil
        )
    }
}

final class V2RejectingRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = V2RejectingRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Authentication bodies and provider authorization headers must never
        // be replayed to a Location selected by an intermediary.
        completionHandler(nil)
    }
}

enum V2HTTPContract {
    static func isJSON(_ response: HTTPURLResponse) -> Bool {
        guard let raw = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return false }
        return raw == "application/json" || raw.hasSuffix("+json")
    }
}

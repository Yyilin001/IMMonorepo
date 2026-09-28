import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Production account leaf. Unknown routes and other capability boundaries fail
/// before I/O. The session owner still checks credential epoch before and after I/O.
public struct V2RegisteredAccountHTTPTransport: V2AuthHTTPTransport, Sendable {
    public enum RegistrationError: Error, Equatable, Sendable { case invalidScope, invalidOrigin }
    private let executor: V2HTTPExecutor
    private let bases: [URL]
    public let scope: V2QueryScope
    public init(executor: V2HTTPExecutor, allowedBases: [URL], scope: V2QueryScope) throws {
        guard !scope.accountID.isEmpty, scope.accountID.utf8.count <= 128,
              scope.authorizationDomain == "accountHTTP" else { throw RegistrationError.invalidScope }
        guard !allowedBases.isEmpty, allowedBases.allSatisfy({
            $0.scheme?.lowercased() == "https" && $0.host != nil && $0.user == nil && $0.password == nil && $0.fragment == nil && $0.query == nil
        }) else { throw RegistrationError.invalidOrigin }
        self.executor = executor; bases = allowedBases.sorted { $0.path.count > $1.path.count }; self.scope = scope
    }
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard let url = request.url, url.user == nil, url.password == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedPath.utf8.count <= 4096,
              components.percentEncodedPath.split(separator: "/").allSatisfy({
                  guard let decoded = String($0).removingPercentEncoding else { return false }
                  return !decoded.contains("/") && !decoded.contains("\\") && decoded != "." && decoded != ".."
              }),
              let base = bases.first(where: {
                  let prefix = $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                  return $0.scheme?.lowercased() == url.scheme?.lowercased() && $0.host?.lowercased() == url.host?.lowercased()
                    && ($0.port ?? 443) == (url.port ?? 443)
                    && (prefix.isEmpty || url.path.hasPrefix("/" + prefix + "/"))
              }) else { throw V2HTTPFailure(kind: .invalidEndpoint, service: "accountPolicy", certainty: .notStarted) }
        let prefix = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = prefix.isEmpty ? url.path : String(url.path.dropFirst(prefix.count + 1))
        guard let policy = V2HTTPRouteRegistry.policy(method: request.httpMethod ?? "GET", path: path) else { throw V2HTTPFailure(kind: .invalidEndpoint, service: "accountPolicy", certainty: .notStarted) }
        guard policy.kind.accountTransportAllowed else { throw V2HTTPFailure(kind: .invalidEndpoint, service: "accountPolicy", certainty: .notStarted) }
        return try await executor.execute(request, budget: .init(timeout: 15, maximumResponseBytes: policy.maximumResponseBytes), service: "accountAPI")
    }
}

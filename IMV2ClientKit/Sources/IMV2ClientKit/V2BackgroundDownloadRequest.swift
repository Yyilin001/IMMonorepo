import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The request exists only in memory until transferred to the OS. Business journals
/// retain the grant ID and immutable byte facts, never this URL or its headers.
enum V2BackgroundDownloadRequest {
    static func make(target: V2ClientMediaTransferTarget, now: Date = Date()) throws -> URLRequest {
        guard let grant = target.backgroundDownloadAuthorization,
              grant.expectedByteCount == target.expectedByteCount, grant.checksum == target.checksum,
              target.expiresAt > now,
              Double(grant.issuedAtMilliseconds) <= now.timeIntervalSince1970 * 1_000,
              target.url.scheme?.lowercased() == "https", target.url.host != nil,
              target.url.user == nil, target.url.password == nil, target.url.fragment == nil,
              !target.headers.keys.contains(where: { $0.lowercased() == "authorization" || $0.lowercased() == "cookie" })
        else { throw V2BackgroundTransferError.invalidAuthorization }
        var request = URLRequest(url: target.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: min(30, target.expiresAt.timeIntervalSince(now)))
        request.httpMethod = "GET"
        for (name, value) in target.headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
}

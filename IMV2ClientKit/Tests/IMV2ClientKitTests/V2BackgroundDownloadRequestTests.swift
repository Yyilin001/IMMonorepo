import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

struct V2BackgroundDownloadRequestTests {
    @Test(arguments: ["allowed", "foreground-only", "expired", "not-issued"])
    func onlyCurrentlyDelegatedRequestsCanEnterTheSystemSession(mode: String) throws {
        let issued = Date(timeIntervalSince1970: 1_750_000_000), expiry = issued.addingTimeInterval(60)
        let checksum = try V2ResourceChecksum(value: String(repeating: "a", count: 64))
        let grant = try V2ResourceBackgroundDownloadAuthorization(id: UUID(), expectedByteCount: 3,
            checksum: checksum, issuedAt: issued, expiresAt: expiry)
        let target = try V2ClientMediaTransferTarget(downloadPlan: .init(mode: .httpGet,
            url: #require(URL(string: "https://objects.invalid/opaque?cap=delegated")),
            expiresAt: expiry, expectedByteCount: 3, checksum: checksum,
            backgroundDownloadAuthorization: mode == "foreground-only" ? nil : grant))
        let now = mode == "expired" ? expiry : mode == "not-issued" ? issued.addingTimeInterval(-1) : issued
        if mode == "allowed" {
            let request = try V2BackgroundDownloadRequest.make(target: target, now: now)
            #expect(request.httpMethod == "GET" && request.url == target.url)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil && request.timeoutInterval <= 30)
        } else {
            #expect(throws: V2BackgroundTransferError.invalidAuthorization) {
                try V2BackgroundDownloadRequest.make(target: target, now: now)
            }
        }
    }
}

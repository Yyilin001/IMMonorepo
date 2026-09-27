import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
@testable import IMV2ClientKit
import Testing

struct V2ResourceCapabilitiesTests {
    @Test func readsAuthenticatedBoundedCapabilityEndpoint() async throws {
        let endpoint=try #require(URL(string:"https://account.invalid/v2/resource-uploads"))
        let expected=try V2ResourceCapabilities(uploadModes:[.httpPut],maximumBytes:4096,allowedUsages:[.messageAttachment],maximumParts:0,backgroundTransfer:false)
        let transport=CapabilityHTTPTransport(body:try JSONEncoder().encode(expected))
        let client=try V2HTTPResourceUploadClient(endpoint:endpoint,credentials:CapabilityCredentials(),transport:transport)
        #expect(try await client.capabilities()==expected)
        let request=try #require(await transport.request)
        #expect(request.url?.path=="/v2/resource-capabilities")
        #expect(request.httpMethod=="GET" && request.httpBody==nil)
        #expect(request.value(forHTTPHeaderField:"Authorization")=="Bearer account-only")
        #expect(request.value(forHTTPHeaderField:"Cache-Control")=="no-store")
        #expect(request.timeoutInterval==5)
    }

    @Test func offlineCapabilityReadKeepsDraftAdmissionOpenAndBacksOff() async throws {
        let reader=OfflineCapabilityReader()
        let cache=V2ResourceCapabilitiesCache(reader:reader)
        try await cache.refreshIfNeeded()
        try await cache.refreshIfNeeded()
        #expect(await reader.reads==1)
        let request=try V2ResourceUploadRequest(operationID:.init(UUID().uuidString),mediaID:.init(UUID().uuidString),usage:.userAvatar,contentType:"image/png",byteCount:100,checksum:.init(value:String(repeating:"a",count:64)))
        try await cache.validateNewUpload(request)
        await cache.close()
        await #expect(throws:CancellationError.self) { try await cache.validateNewUpload(request) }
    }
}

private actor OfflineCapabilityReader:V2ResourceCapabilityReading {
    var reads=0
    func capabilities() throws -> V2ResourceCapabilities { reads += 1;throw URLError(.notConnectedToInternet) }
}
private struct CapabilityCredentials:V2ClientMediaEdgeCredentialProvider {
    func mediaEdgeCredentials() throws -> V2ClientMediaEdgeCredentials {
        .init(accessToken:"account-only",deviceID:try .init("00000000-0000-0000-0000-000000000001"))
    }
}
private actor CapabilityHTTPTransport:V2ClientMediaEdgeHTTPTransport {
    let body:Data
    var request:URLRequest?
    init(body:Data) {self.body=body}
    func data(for request:URLRequest) throws -> (Data,HTTPURLResponse) {
        self.request=request
        let url=try #require(request.url)
        return (body,try #require(HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])))
    }
}

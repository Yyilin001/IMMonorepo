import Foundation
import Crypto
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Local native multipart upload")
struct V2LocalMultipartUploadTests {
    @Test func backgroundGrantIsExactBoundedAndSignedIntoNativePart() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let provider=try V2LocalFilesystemMediaProvider(rootDirectory:root,targetBaseURL:URL(string:"https://provider.invalid")!,signingKey:Data(repeating:7,count:32))
        let transport=V2LocalResourceUploadTransport(binding:try .init(id:"background",configurationRevision:1),provider:provider)
        let media=MediaID(uuid:UUID()),session=MediaUploadSessionID(uuid:UUID()),issued=Date()
        let bytes=Data("part".utf8),checksum=try V2ResourceChecksum(value:SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined())
        let plans=try await transport.backgroundPartPlans(mediaID:media,contentType:"text/plain",byteCount:4,checksum:checksum,requestedParts:[],sessionID:session,generation:3,issuedAt:issued,expiresAt:issued.addingTimeInterval(600))
        let plan=try #require(plans.first),grant=try #require(plan.backgroundAuthorization)
        #expect(grant.sessionID==session && grant.generation==3 && grant.mediaID==media && grant.partNumber==1)
        #expect(plan.expiresAt.timeIntervalSince(issued)>120)
        #expect(plan.headers.allSatisfy { !$0.name.lowercased().contains("authorization") })
        try await provider.storeUploadedObject(mediaID:try .init(plan.url.lastPathComponent),targetURL:plan.url,contentType:"text/plain",bytes:bytes)
        #expect(try await transport.confirmedParts(mediaID:media,byteCount:4,checksum:checksum).count==1)
        await #expect(throws:(any Error).self) {
            _ = try await transport.backgroundPartPlans(mediaID:MediaID(uuid:UUID()),contentType:"text/plain",byteCount:4,checksum:checksum,requestedParts:[],sessionID:session,generation:3,issuedAt:issued,expiresAt:issued.addingTimeInterval(901))
        }
    }
    @Test func providerRestartKeepsConfirmedPartsAndOnlyIssuesMissingTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("multipart-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        let binding = try V2StorageBinding(id:"local-parts",configurationRevision:1)
        let signing = Data(repeating:42,count:32)
        let provider = try V2LocalFilesystemMediaProvider(rootDirectory:root,targetBaseURL:URL(string:"https://provider.invalid")!,signingKey:signing)
        let transport = V2LocalResourceUploadTransport(binding:binding,provider:provider)
        let first = Data(repeating:7,count:8 * 1_024 * 1_024), last = Data("end".utf8)
        var hash = SHA256(); hash.update(data:first); hash.update(data:last)
        let checksum = try V2ResourceChecksum(value:hash.finalize().map {String(format:"%02x",$0)}.joined())
        let media = MediaID(uuid:UUID()), total = Int64(first.count + last.count)
        let plans = try await transport.partPlans(mediaID:media,contentType:"application/octet-stream",byteCount:total,checksum:checksum,requestedParts:[],expiresAt:.now.addingTimeInterval(60))
        let one = try #require(plans.first)
        #expect(one.mode == .httpPartPut && one.partNumber == 1 && one.byteRange?.lowerBound == 0)
        try await provider.storeUploadedObject(mediaID:try .init(one.url.lastPathComponent),targetURL:one.url,contentType:"application/octet-stream",bytes:first)
        // A fresh provider has no in-memory upload state to recover from.
        let reopened = try V2LocalFilesystemMediaProvider(rootDirectory:root,targetBaseURL:URL(string:"https://provider.invalid")!,signingKey:signing)
        let recovered = V2LocalResourceUploadTransport(binding:binding,provider:reopened)
        let confirmed = try await recovered.confirmedParts(mediaID:media,byteCount:total,checksum:checksum)
        #expect(confirmed.count == 1 && confirmed[0].number == 1)
        let missing = try await recovered.partPlans(mediaID:media,contentType:"application/octet-stream",byteCount:total,checksum:checksum,requestedParts:[],expiresAt:.now.addingTimeInterval(60))
        let two = try #require(missing.first)
        #expect(two.partNumber == 2 && two.byteRange?.lowerBound == Int64(first.count) && two.expectedByteCount == 3)
        try await reopened.storeUploadedObject(mediaID:try .init(two.url.lastPathComponent),targetURL:two.url,contentType:"application/octet-stream",bytes:last)
        let all = try await recovered.confirmedParts(mediaID:media,byteCount:total,checksum:checksum)
        #expect(all.map(\.number) == [1,2])
        #expect(try await recovered.partPlans(mediaID:media,contentType:"application/octet-stream",byteCount:total,checksum:checksum,requestedParts:[],expiresAt:.now.addingTimeInterval(60)).isEmpty)
        let stream = try await recovered.completedParts(mediaID:media,byteCount:total,checksum:checksum,parts:all)
        var result = SHA256(), count:Int64 = 0
        while let chunk = try await stream.next() { #expect(chunk.count <= 65_536); count += Int64(chunk.count); result.update(data:chunk) }
        #expect(count == total)
        #expect(result.finalize().map {String(format:"%02x",$0)}.joined() == checksum.value)
        await #expect(throws:V2ResourceProviderError.preconditionFailed) {
            _ = try await recovered.completedParts(mediaID:media,byteCount:total,checksum:checksum,parts:confirmed)
        }
        try await recovered.abortParts(mediaID:media,byteCount:total,checksum:checksum)
        await #expect(throws:V2LocalFilesystemMediaProviderError.objectUnavailable) {
            try await reopened.storeUploadedObject(mediaID:try .init(two.url.lastPathComponent),targetURL:two.url,contentType:"application/octet-stream",bytes:last)
        }
    }
}

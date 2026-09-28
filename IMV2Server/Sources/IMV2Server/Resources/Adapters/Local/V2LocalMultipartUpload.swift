import Foundation
import Crypto
import IMV2Core

extension V2LocalResourceUploadTransport: V2BackgroundUploadTransport {
    public var maximumParts: Int { 32 }
    private static let partBytes: Int64 = 8 * 1_024 * 1_024
    private func partCount(_ count: Int64) throws -> Int {
        guard count > 0, count <= capabilities.maximumBytes else { throw V2ResourceProviderError.unsupportedCapability }
        return Int((count + Self.partBytes - 1) / Self.partBytes)
    }
    private func partID(mediaID: MediaID, checksum: V2ResourceChecksum, number: Int) -> MediaID {
        let digest = SHA256.hash(data: Data("local-part-v1|\(mediaID.rawValue)|\(checksum.value)|\(number)".utf8))
        let bytes = Array(digest.prefix(16))
        let uuid = UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
        return .init(uuid: uuid)
    }
    public func partPlans(mediaID: MediaID, contentType: String, byteCount: Int64, checksum: V2ResourceChecksum, requestedParts: [Int], expiresAt: Date) async throws -> [V2ResourceTransferPlan] {
        try await makePartPlans(mediaID:mediaID,contentType:contentType,byteCount:byteCount,checksum:checksum,
            requestedParts:requestedParts,expiresAt:expiresAt,grant:{ _ in nil })
    }
    public func backgroundPartPlans(mediaID:MediaID,contentType:String,byteCount:Int64,checksum:V2ResourceChecksum,
        requestedParts:[Int],sessionID:MediaUploadSessionID,generation:Int64,issuedAt:Date,expiresAt:Date) async throws -> [V2ResourceTransferPlan] {
        try await makePartPlans(mediaID:mediaID,contentType:contentType,byteCount:byteCount,checksum:checksum,
            requestedParts:requestedParts,expiresAt:expiresAt,grant:{ number in
                try .init(id:UUID(),sessionID:sessionID,generation:generation,mediaID:mediaID,partNumber:number,issuedAt:issuedAt,expiresAt:expiresAt)
            })
    }
    private func makePartPlans(mediaID:MediaID,contentType:String,byteCount:Int64,checksum:V2ResourceChecksum,
        requestedParts:[Int],expiresAt:Date,grant:(Int) throws -> V2ResourceBackgroundAuthorization?) async throws -> [V2ResourceTransferPlan] {
        let count = try partCount(byteCount)
        guard requestedParts.count <= 16, requestedParts.allSatisfy({ (1...count).contains($0) }) else { throw V2ResourceProviderError.preconditionFailed }
        let confirmed = Set(try await confirmedParts(mediaID: mediaID,byteCount: byteCount,checksum: checksum).map(\.number))
        let requested = requestedParts.isEmpty ? Array((1...count).filter { !confirmed.contains($0) }.prefix(1)) : requestedParts.filter { !confirmed.contains($0) }
        var plans: [V2ResourceTransferPlan] = []
        for number in requested {
            let start = Int64(number - 1) * Self.partBytes
            let length = min(Self.partBytes,byteCount - start)
            let id = partID(mediaID:mediaID,checksum:checksum,number:number)
            let authorization = try grant(number)
            let target: V2MediaProviderUploadTarget
            if let authorization { target = try await provider.issueBackgroundUploadTarget(mediaID:id,contentType:contentType,byteCount:length,authorization:authorization) }
            else { target = try await provider.issueUploadTarget(mediaID:id,contentType:contentType,byteCount:length,expiresAt:expiresAt) }
            plans.append(try .init(mode:.httpPartPut,url:target.url,headers:target.headers.map { try .init(name:$0.key,value:$0.value) },expiresAt:expiresAt,expectedByteCount:length,byteRange:.init(lowerBound:start,upperBound:start + length - 1),partNumber:number,backgroundAuthorization:authorization))
        }
        return plans
    }
    public func confirmedParts(mediaID: MediaID, byteCount: Int64, checksum: V2ResourceChecksum) async throws -> [V2ResourceUploadPart] {
        var parts:[V2ResourceUploadPart] = []
        for number in 1...(try partCount(byteCount)) {
            let id = partID(mediaID:mediaID,checksum:checksum,number:number)
            do {
                let target = try await provider.issueDownloadTarget(mediaID:id,expiresAt:Date().addingTimeInterval(60))
                let object = try await provider.downloadedObject(mediaID:id,targetURL:target.url)
                let expected = min(Self.partBytes,byteCount - Int64(number - 1) * Self.partBytes)
                guard object.byteCount == expected else { throw V2ResourceProviderError.integrityMismatch }
                parts.append(try .init(number:number,byteCount:expected,receipt:id.rawValue))
            } catch V2LocalFilesystemMediaProviderError.objectUnavailable { continue }
        }
        return parts
    }
    public func completedParts(mediaID: MediaID, byteCount: Int64, checksum: V2ResourceChecksum, parts: [V2ResourceUploadPart]) async throws -> V2ResourceByteStream {
        let confirmed = try await confirmedParts(mediaID:mediaID,byteCount:byteCount,checksum:checksum)
        guard confirmed.count == (try partCount(byteCount)), parts == confirmed else { throw V2ResourceProviderError.preconditionFailed }
        var files:[URL] = []
        for part in confirmed {
            let id = partID(mediaID:mediaID,checksum:checksum,number:part.number)
            let target = try await provider.issueDownloadTarget(mediaID:id,expiresAt:Date().addingTimeInterval(60))
            files.append(try await provider.downloadedObject(mediaID:id,targetURL:target.url).fileURL)
        }
        let reader = MultipartReader(files:files)
        return V2ResourceByteStream { try await reader.next() }
    }
    public func abortParts(mediaID: MediaID, byteCount: Int64, checksum: V2ResourceChecksum) async throws {
        for number in 1...(try partCount(byteCount)) { try await provider.purge(mediaID:partID(mediaID:mediaID,checksum:checksum,number:number)) }
    }
}
private actor MultipartReader {
    private var files:[URL]
    private var handle:FileHandle?
    init(files:[URL]) { self.files = files }
    deinit { try? handle?.close() }
    func next() async throws -> Data? {
        try Task.checkCancellation()
        while true {
            if handle == nil {
                guard !files.isEmpty else { return nil }
                let file = files.removeFirst()
                handle = try await Task.detached(priority:.utility) { try FileHandle(forReadingFrom:file) }.value
            }
            let input = handle!
            let data = try await Task.detached(priority:.utility) { try input.read(upToCount:65_536) }.value
            if let data, !data.isEmpty { return data }
            try await Task.detached(priority:.utility) { try input.close() }.value
            handle = nil
        }
    }
}

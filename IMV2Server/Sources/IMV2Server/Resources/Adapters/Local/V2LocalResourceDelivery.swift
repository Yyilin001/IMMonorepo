import Crypto
import Foundation
import IMV2Core
import Synchronization

/// Authenticates before every cache lookup. Capabilities are encrypted, so internal placement
/// handles never leak into client-visible object paths. Shared cache keys exclude actor/token.
public actor V2LocalResourceDelivery: V2ResourceDelivery {
    private let registry:V2ResourceStorageRegistry
    private let baseURL:URL
    private let keyID:String
    private let keys:[String:Data]
    private let now:@Sendable () -> Date
    private let maximumCacheBytes:Int
    private let maximumObjectBytes:Int64
    private let streamAdmissions = ResourceStreamAdmissions()
    private var cache:[DeliveryCacheKey:Data]=[:]
    private var order:[DeliveryCacheKey]=[]
    private var cacheBytes=0
    private var inFlight:[DeliveryCacheKey:DeliveryFlight]=[:]
    private var originReads=0
    public init(registry:V2ResourceStorageRegistry,baseURL:URL,keyID:String,keys:[String:Data],maximumCacheBytes:Int=32*1_024*1_024,
                now:@escaping @Sendable () -> Date=Date.init, maximumObjectBytes:Int64=256*1_024*1_024) throws {
        guard baseURL.scheme=="https",baseURL.host != nil,baseURL.query==nil,baseURL.fragment==nil,
              keys[keyID]?.count==32,keys.values.allSatisfy({$0.count==32}),maximumCacheBytes>=512*1_024,
              maximumObjectBytes > 0, maximumObjectBytes <= Int64(Int.max),
              !keyID.isEmpty,keyID.utf8.count<=64,keyID.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||$0==45})
        else { throw V2ResourceProviderError.configurationInvalid }
        self.registry=registry;self.baseURL=baseURL;self.keyID=keyID;self.keys=keys;self.maximumCacheBytes=maximumCacheBytes;self.now=now
        self.maximumObjectBytes=maximumObjectBytes
    }
    public func issue(_ request:V2AuthorizedResourceDelivery) async throws -> V2ResourceTransferPlan {
        let instant=now()
        guard request.expiresAt>instant,request.expiresAt<=instant.addingTimeInterval(120),request.facts.byteCount<=maximumObjectBytes
        else { throw V2ResourceProviderError.preconditionFailed }
        _ = try registry.storage(for:request.facts.reference.binding)
        let claims=DeliveryClaims(reference:request.facts.reference,byteCount:request.facts.byteCount,
            sha256:request.facts.sha256,expiresAt:request.expiresAt.timeIntervalSince1970,audience:"resource-bytes-v1",method:"GET")
        let encrypted=try AES.GCM.seal(JSONEncoder().encode(claims),using:SymmetricKey(data:keys[keyID]!))
        guard let combined=encrypted.combined else { throw V2ResourceProviderError.configurationInvalid }
        let token=keyID+"."+combined.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        var url=URLComponents(url:baseURL.appendingPathComponent("v2/resource-bytes").appendingPathComponent(request.facts.reference.placementID.uuidString.lowercased()),resolvingAgainstBaseURL:false)!
        url.queryItems=[.init(name:"cap",value:token)]
        return try .init(mode:.httpGet,url:url.url!,expiresAt:request.expiresAt,expectedByteCount:request.facts.byteCount,
            checksum:.init(value:request.facts.sha256.map { String(format:"%02x",$0) }.joined()))
    }
    public func bytes(placementID:UUID,capability:String) async throws -> Data {
        let claims=try verify(placementID:placementID,capability:capability)
        guard claims.byteCount <= 512*1_024 else { throw V2ResourceProviderError.unsupportedCapability }
        let cacheKey = DeliveryCacheKey(reference:claims.reference,byteCount:claims.byteCount,sha256:claims.sha256)
        if let cached=cache[cacheKey] { return cached }
        let flight:DeliveryFlight
        if let existing=inFlight[cacheKey] { flight=existing }
        else {
            guard inFlight.count<64 else { throw V2ResourceProviderError.throttled(retryAfter:1) }
            let storage=try registry.storage(for:claims.reference.binding)
            originReads += 1
            let task=Task {
                let facts=try await storage.inspect(claims.reference)
                guard facts.byteCount==claims.byteCount,facts.sha256==claims.sha256 else { throw V2ResourceProviderError.integrityMismatch }
                let stream=try await storage.read(claims.reference)
                var data=Data()
                while let chunk=try await stream.next() {
                    guard chunk.count<=512*1_024-data.count else { throw V2ResourceProviderError.integrityMismatch }
                    data.append(chunk)
                }
                guard Int64(data.count)==claims.byteCount,Data(SHA256.hash(data:data))==claims.sha256 else { throw V2ResourceProviderError.integrityMismatch }
                return data
            }
            flight = .init(id:UUID(),task:task)
            inFlight[cacheKey]=flight
        }
        do {
            let data=try await flight.task.value
            if inFlight[cacheKey]?.id == flight.id { inFlight[cacheKey]=nil }
            _ = try verify(placementID:placementID,capability:capability)
            if cache[cacheKey]==nil {
                while (cacheBytes+data.count>maximumCacheBytes || cache.count>=512),!order.isEmpty {
                    let old=order.removeFirst();cacheBytes -= cache.removeValue(forKey:old)?.count ?? 0
                }
                cache[cacheKey]=data;order.append(cacheKey);cacheBytes += data.count
            }
            return data
        } catch {
            // A late waiter for a failed task must not remove the next recovery attempt.
            if inFlight[cacheKey]?.id == flight.id { inFlight[cacheKey]=nil }
            throw error
        }
    }
    /// Large attachments bypass the small-image cache and stream with bounded memory.
    /// A permit is retained by the stream and released on EOF, failure or abandonment.
    public func stream(placementID:UUID,capability:String) async throws -> (byteCount:Int64,etag:String,bytes:V2ResourceByteStream,close:@Sendable () async -> Void) {
        let claims=try verify(placementID:placementID,capability:capability)
        let etag = "\"" + claims.sha256.map { String(format:"%02x",$0) }.joined() + "\""
        if claims.byteCount <= 512*1_024 {
            let cached = try await bytes(placementID:placementID,capability:capability)
            let reader = CachedResourceReader(cached,expiresAt:claims.expiresAt,now:now)
            return (claims.byteCount, etag, .init { try await reader.next() }, { await reader.close() })
        }
        let permit = try streamAdmissions.acquire()
        do {
            let storage=try registry.storage(for:claims.reference.binding)
            let facts=try await storage.inspect(claims.reference)
            guard facts.byteCount==claims.byteCount,facts.sha256==claims.sha256 else { throw V2ResourceProviderError.integrityMismatch }
            _ = try verify(placementID:placementID,capability:capability)
            let input=try await storage.read(claims.reference)
            let reader=VerifiedResourceReader(input:input,claims:claims,permit:permit,now:now)
            return (claims.byteCount,etag,.init { try await reader.next() }, { await reader.close() })
        } catch { permit.release(); throw error }
    }
    package func originReadCount() -> Int { originReads }
    private func verify(placementID:UUID,capability:String) throws -> DeliveryClaims {
        guard capability.utf8.count<=8192 else { throw V2ResourceProviderError.notFound }
        let parts=capability.split(separator:".",maxSplits:1)
        guard parts.count==2,let key=keys[String(parts[0])] else { throw V2ResourceProviderError.notFound }
        var encoded=String(parts[1]).replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
        encoded += String(repeating:"=",count:(4-encoded.count%4)%4)
        guard let encrypted=Data(base64Encoded:encoded),
              let box=try? AES.GCM.SealedBox(combined:encrypted),
              let plaintext=try? AES.GCM.open(box,using:SymmetricKey(data:key)),
              let claims=try? JSONDecoder().decode(DeliveryClaims.self,from:plaintext),
              claims.reference.placementID==placementID,claims.audience=="resource-bytes-v1",claims.method=="GET",
              claims.expiresAt>now().timeIntervalSince1970,claims.sha256.count==32,claims.byteCount>0,claims.byteCount<=maximumObjectBytes
        else { throw V2ResourceProviderError.notFound }
        return claims
    }
}
private struct DeliveryCacheKey:Hashable,Sendable {
    let reference:V2StoredObjectReference
    let byteCount:Int64
    let sha256:Data
}
private struct DeliveryFlight:Sendable {
    let id:UUID
    let task:Task<Data,any Error>
}
private struct DeliveryClaims:Codable,Sendable {
    let reference:V2StoredObjectReference;let byteCount:Int64;let sha256:Data
    let expiresAt:TimeInterval;let audience:String;let method:String
}

private actor CachedResourceReader {
    let data:Data
    let expiresAt:TimeInterval
    let now:@Sendable () -> Date
    var offset=0
    init(_ data:Data,expiresAt:TimeInterval,now:@escaping @Sendable () -> Date) {
        self.data=data;self.expiresAt=expiresAt;self.now=now
    }
    func close() { offset=data.count }
    func next() throws -> Data? {
        try Task.checkCancellation()
        guard expiresAt>now().timeIntervalSince1970 else { throw V2ResourceProviderError.notFound }
        guard offset < data.count else { return nil }
        let end=min(offset+65_536,data.count)
        defer { offset=end }
        return data.subdata(in:offset..<end)
    }
}

private final class ResourceStreamPermit:Sendable {
    private let admissions:ResourceStreamAdmissions
    private let active=Mutex(true)
    init(admissions:ResourceStreamAdmissions) { self.admissions=admissions }
    func release() {
        let owned=active.withLock { active in let previous=active; active=false; return previous }
        if owned { admissions.release() }
    }
    deinit { release() }
}

private final class ResourceStreamAdmissions:Sendable {
    private let count=Mutex(0)
    func acquire() throws -> ResourceStreamPermit {
        try count.withLock { value in
            guard value < 16 else { throw V2ResourceProviderError.throttled(retryAfter:1) }
            value += 1
        }
        return .init(admissions:self)
    }
    func release() { count.withLock { $0 -= 1 } }
}

private actor VerifiedResourceReader {
    let input:V2ResourceByteStream
    let claims:DeliveryClaims
    let permit:ResourceStreamPermit
    let now:@Sendable () -> Date
    var count:Int64=0
    var digest=SHA256()
    var finished=false
    var reading=false
    var closeWaiters:[CheckedContinuation<Void,Never>]=[]
    init(input:V2ResourceByteStream,claims:DeliveryClaims,permit:ResourceStreamPermit,now:@escaping @Sendable () -> Date) {
        self.input=input;self.claims=claims;self.permit=permit;self.now=now
    }
    /// Close waits for an outstanding storage read instead of releasing its slot early.
    func close() async {
        finished=true
        if reading {
            await withCheckedContinuation { closeWaiters.append($0) }
        } else { permit.release() }
    }
    func next() async throws -> Data? {
        guard !finished else { return nil }
        guard !reading else { throw V2ResourceProviderError.preconditionFailed }
        reading=true
        defer {
            reading=false
            if finished {
                permit.release()
                let waiters=closeWaiters;closeWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        do {
            try Task.checkCancellation()
            guard claims.expiresAt > now().timeIntervalSince1970 else { throw V2ResourceProviderError.notFound }
            let next=try await input.next()
            guard !finished else { throw CancellationError() }
            try Task.checkCancellation()
            guard claims.expiresAt > now().timeIntervalSince1970 else { throw V2ResourceProviderError.notFound }
            guard let chunk=next else {
                guard count==claims.byteCount,Data(digest.finalize())==claims.sha256 else { throw V2ResourceProviderError.integrityMismatch }
                finished=true;permit.release();return nil
            }
            guard Int64(chunk.count)<=claims.byteCount-count else { throw V2ResourceProviderError.integrityMismatch }
            count += Int64(chunk.count);digest.update(data:chunk)
            return chunk
        } catch { finished=true;permit.release();throw error }
    }
}

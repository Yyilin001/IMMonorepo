@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Crypto
import Foundation
import Synchronization
import Testing
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

struct V2ResourceDeliveryContractTests {
    @Test func aSlowOriginCannotReleaseBytesAfterCapabilityExpiry() async throws {
        let clock=DeliveryTestClock(Date())
        let binding=try V2StorageBinding(id:"slow-origin",configurationRevision:1)
        let reference=try V2StoredObjectReference(placementID:UUID(),binding:binding,handle:Data([1]))
        let facts=try V2StoredObjectFacts(reference:reference,byteCount:700_000,sha256:Data(repeating:0,count:32))
        let storage=ExpiryDuringReadStorage(facts:facts,clock:clock)
        let registry=try V2ResourceStorageRegistry(storages:[storage],defaultBinding:binding)
        let delivery=try V2LocalResourceDelivery(registry:registry,baseURL:URL(string:"https://resources.example")!,keyID:"test",keys:["test":Data(repeating:3,count:32)],now:{clock.get()})
        let plan=try await delivery.issue(.init(facts:facts,expiresAt:clock.get().addingTimeInterval(5)))
        let token=try #require(URLComponents(url:plan.url,resolvingAgainstBaseURL:false)?.queryItems?.first?.value)
        let opened=try await delivery.stream(placementID:reference.placementID,capability:token)
        await #expect(throws:V2ResourceProviderError.notFound) { _ = try await opened.bytes.next() }
    }
    @Test func sharedCacheRequiresExactBindingAndVerifiedFacts() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let a=try V2LocalResourceStorage(root:root.appendingPathComponent("a"),binding:.init(id:"a",configurationRevision:1))
        let b=try V2LocalResourceStorage(root:root.appendingPathComponent("b"),binding:.init(id:"b",configurationRevision:2))
        let id=UUID()
        let first=try a.allocate(placementID:id), second=try b.allocate(placementID:id)
        let bytesA=Data([1,2,3]), bytesB=Data([4,5,6])
        let sourceA=DeliveryTestChunks(bytesA), sourceB=DeliveryTestChunks(bytesB)
        let factsA=try await a.write(first,byteCount:3,sha256:Data(SHA256.hash(data:bytesA)),bytes:.init { await sourceA.next() })
        let factsB=try await b.write(second,byteCount:3,sha256:Data(SHA256.hash(data:bytesB)),bytes:.init { await sourceB.next() })
        let registry=try V2ResourceStorageRegistry(storages:[a,b],defaultBinding:b.binding)
        let delivery=try V2LocalResourceDelivery(registry:registry,baseURL:URL(string:"https://resources.example")!,keyID:"test",keys:["test":Data(repeating:3,count:32)])
        func token(_ facts:V2StoredObjectFacts) async throws -> String {
            let plan=try await delivery.issue(.init(facts:facts,expiresAt:Date().addingTimeInterval(30)))
            return try #require(URLComponents(url:plan.url,resolvingAgainstBaseURL:false)?.queryItems?.first?.value)
        }
        #expect(try await delivery.bytes(placementID:id,capability:token(factsA))==bytesA)
        #expect(try await delivery.bytes(placementID:id,capability:token(factsB))==bytesB)
        let conflictingFacts=try V2StoredObjectFacts(reference:first,byteCount:3,sha256:factsB.sha256)
        let conflictingToken=try await token(conflictingFacts)
        await #expect(throws:V2ResourceProviderError.integrityMismatch) {
            _ = try await delivery.bytes(placementID:id,capability:conflictingToken)
        }
        #expect(await delivery.originReadCount()==3)
    }
    @Test func largeAttachmentsStreamUnderAdmissionAndExpiryLimits() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let storage=try V2LocalResourceStorage(root:root,binding:.init(id:"stream",configurationRevision:1))
        let reference=try storage.allocate()
        let payload=Data(repeating:9,count:700_000)
        let source=DeliveryTestChunks(payload)
        let facts=try await storage.write(reference,byteCount:Int64(payload.count),sha256:Data(SHA256.hash(data:payload)),bytes:.init { await source.next() })
        let registry=try V2ResourceStorageRegistry(storages:[storage],defaultBinding:storage.binding)
        let clock=DeliveryTestClock(Date())
        let delivery=try V2LocalResourceDelivery(registry:registry,baseURL:URL(string:"https://resources.example")!,keyID:"test",keys:["test":Data(repeating:3,count:32)],now:{clock.get()})
        let plan=try await delivery.issue(.init(facts:facts,expiresAt:clock.get().addingTimeInterval(30)))
        let token=try #require(URLComponents(url:plan.url,resolvingAgainstBaseURL:false)?.queryItems?.first?.value)
        await #expect(throws:V2ResourceProviderError.unsupportedCapability) { _ = try await delivery.bytes(placementID:reference.placementID,capability:token) }
        var readers:[V2ResourceByteStream]=[]
        for _ in 0..<16 { readers.append(try await delivery.stream(placementID:reference.placementID,capability:token).bytes) }
        await #expect(throws:V2ResourceProviderError.throttled(retryAfter:1)) { _ = try await delivery.stream(placementID:reference.placementID,capability:token) }
        var received=Data()
        while let chunk=try await readers[0].next() { #expect(chunk.count<=65_536);received.append(chunk) }
        #expect(received==payload)
        let replacement=try await delivery.stream(placementID:reference.placementID,capability:token)
        #expect(replacement.byteCount==Int64(payload.count))
        clock.advance(31)
        await #expect(throws:V2ResourceProviderError.notFound) { _ = try await replacement.bytes.next() }
        await #expect(throws:V2ResourceProviderError.notFound) { _ = try await delivery.stream(placementID:reference.placementID,capability:token) }
        #expect(await delivery.originReadCount()==0)
    }
    @Test func warmCacheStillRequiresValidCapabilityAndColdMissesCoalesce() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let binding=try V2StorageBinding(id:"a",configurationRevision:1)
        let storage=try V2LocalResourceStorage(root:root,binding:binding)
        let reference=try storage.allocate()
        let bytes=Data(repeating:1,count:40_000)
        let source=DeliveryTestChunks(bytes)
        let facts=try await storage.write(reference,byteCount:Int64(bytes.count),sha256:Data(SHA256.hash(data:bytes)),bytes:.init { await source.next() })
        let registry=try V2ResourceStorageRegistry(storages:[storage],defaultBinding:binding)
        let clock=DeliveryTestClock(Date())
        let delivery=try V2LocalResourceDelivery(registry:registry,baseURL:URL(string:"https://resources.example")!,keyID:"test",keys:["test":Data(repeating:3,count:32)],now:{clock.get()})
        let plan=try await delivery.issue(.init(facts:facts,expiresAt:clock.get().addingTimeInterval(30)))
        let token=try #require(URLComponents(url:plan.url,resolvingAgainstBaseURL:false)?.queryItems?.first?.value)
        try await withThrowingTaskGroup(of:Void.self) { group in
            for _ in 0..<100 { group.addTask { () async throws -> Void in
                let value=try await delivery.bytes(placementID:reference.placementID,capability:token)
                #expect(value==bytes)
            } }
            try await group.waitForAll()
        }
        #expect(await delivery.originReadCount()==1)
        await #expect(throws:V2ResourceProviderError.notFound) { _ = try await delivery.bytes(placementID:reference.placementID,capability:token+"tamper") }
        await #expect(throws:V2ResourceProviderError.notFound) { _ = try await delivery.bytes(placementID:UUID(),capability:token) }
        let openCachedStream=try await delivery.stream(placementID:reference.placementID,capability:token)
        clock.advance(31)
        await #expect(throws:V2ResourceProviderError.notFound) { _ = try await openCachedStream.bytes.next() }
        await #expect(throws:V2ResourceProviderError.notFound) { _ = try await delivery.bytes(placementID:reference.placementID,capability:token) }
        #expect(await delivery.originReadCount()==1)
    }
}
private struct ExpiryDuringReadStorage:V2ObjectStorage {
    let facts:V2StoredObjectFacts
    let clock:DeliveryTestClock
    var binding:V2StorageBinding { facts.reference.binding }
    func inspect(_ reference:V2StoredObjectReference) async throws -> V2StoredObjectFacts { facts }
    func read(_ reference:V2StoredObjectReference) async throws -> V2ResourceByteStream {
        .init { clock.advance(10);return Data([1]) }
    }
    func write(_ reference:V2StoredObjectReference,byteCount:Int64,sha256:Data,bytes:V2ResourceByteStream) async throws -> V2StoredObjectFacts { throw V2ResourceProviderError.unsupportedCapability }
    func delete(_ reference:V2StoredObjectReference) async throws { throw V2ResourceProviderError.unsupportedCapability }
}
private actor DeliveryTestChunks {
    let data:Data
    var offset=0
    init(_ data:Data) {self.data=data}
    func next() -> Data? {
        guard offset<data.count else {return nil}
        let end=min(offset+65_536,data.count)
        defer {offset=end}
        return data.subdata(in:offset..<end)
    }
}
private final class DeliveryTestClock:Sendable {
    let value:Mutex<Date>
    init(_ date:Date) {value=Mutex(date)}
    func get() -> Date {value.withLock {$0}}
    func advance(_ seconds:TimeInterval) {value.withLock {$0=$0.addingTimeInterval(seconds)}}
}

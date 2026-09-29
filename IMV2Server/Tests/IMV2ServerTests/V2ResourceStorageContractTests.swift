@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Crypto
import Foundation
import Testing
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

struct V2ResourceStorageContractTests {
    @Test func configurationDoesNotSilentlyChooseAnInvalidOrAmbiguousRevision() throws {
        let bindings="""
        [{"id":"old","revision":1,"directory":"/tmp/old"},{"id":"next","revision":2,"directory":"/tmp/next"}]
        """
        var values=["IM_V2_RESOURCE_STORAGE_BINDINGS_JSON":bindings,"IM_V2_RESOURCE_DEFAULT_BINDING":"next"]
        let selected=try V2ResourceBackendConfiguration(environment:V2DictionaryRuntimeEnvironment(values),defaultDirectory:URL(fileURLWithPath:"/tmp/legacy"))
        #expect(selected.defaultBinding == (try .init(id:"next",configurationRevision:2)))
        values["IM_V2_RESOURCE_DEFAULT_REVISION"]="invalid"
        #expect(throws:V2ResourceProviderError.configurationInvalid) {
            _ = try V2ResourceBackendConfiguration(environment:V2DictionaryRuntimeEnvironment(values),defaultDirectory:URL(fileURLWithPath:"/tmp/legacy"))
        }
        values["IM_V2_RESOURCE_DEFAULT_REVISION"]=nil
        values["IM_V2_RESOURCE_STORAGE_BINDINGS_JSON"]="""
        [{"id":"next","revision":1,"directory":"/tmp/one"},{"id":"next","revision":2,"directory":"/tmp/two"}]
        """
        #expect(throws:V2ResourceProviderError.configurationInvalid) {
            _ = try V2ResourceBackendConfiguration(environment:V2DictionaryRuntimeEnvironment(values),defaultDirectory:URL(fileURLWithPath:"/tmp/legacy"))
        }
    }
    @Test func malformedPersistedPlacementCannotBypassConstructorValidation() throws {
        let binding=try V2StorageBinding(id:"original",configurationRevision:1)
        let reference=try V2StoredObjectReference(placementID:UUID(),binding:binding,handle:Data([1]))
        let encoded=try JSONEncoder().encode(reference)
        var value=try #require(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        value["handle"]=""
        let emptyHandle=try JSONSerialization.data(withJSONObject:value)
        #expect(throws:V2ResourceProviderError.configurationInvalid) { _ = try JSONDecoder().decode(V2StoredObjectReference.self,from:emptyHandle) }
        value["handle"]=Data([1]).base64EncodedString()
        value["binding"]=["id":"original","configurationRevision":0]
        let invalidBinding=try JSONSerialization.data(withJSONObject:value)
        #expect(throws:V2ResourceProviderError.configurationInvalid) { _ = try JSONDecoder().decode(V2StoredObjectReference.self,from:invalidBinding) }
    }
    @Test func immutableIdentityRetryDeleteAndBackendSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try V2LocalResourceStorage(root: root.appendingPathComponent("a"), binding: .init(id: "a", configurationRevision: 1))
        let b = try V2LocalResourceStorage(root: root.appendingPathComponent("b"), binding: .init(id: "b", configurationRevision: 2))
        let reference = try a.allocate()
        let payload = Data(repeating: 42, count: 180_000)
        let digest = Data(SHA256.hash(data: payload))
        _ = try await a.write(reference, byteCount: Int64(payload.count), sha256: digest, bytes: stream(payload))
        // A response may be lost after publication: same identity + bytes returns the same receipt.
        _ = try await a.write(reference, byteCount: Int64(payload.count), sha256: digest, bytes: stream(payload))
        let registry = try V2ResourceStorageRegistry(storages: [a, b], defaultBinding: b.binding)
        let original = try registry.storage(for: reference.binding)
        #expect(try await original.inspect(reference).sha256 == digest)
        let read = try await original.read(reference)
        var count = 0
        while let chunk = try await read.next() { #expect(chunk.count <= 65_536); count += chunk.count }
        #expect(count == payload.count)
        let wrong = Data(repeating: 43, count: payload.count)
        await #expect(throws: V2ResourceProviderError.integrityMismatch) {
            _ = try await a.write(reference, byteCount: Int64(wrong.count), sha256: Data(SHA256.hash(data: wrong)), bytes: stream(wrong))
        }
        try await a.delete(reference)
        try await a.delete(reference)
        await #expect(throws: V2ResourceProviderError.preconditionFailed) {
            _ = try await a.write(reference, byteCount: Int64(payload.count), sha256: digest, bytes: stream(payload))
        }
        await #expect(throws: V2ResourceProviderError.notFound) { _ = try await a.inspect(reference) }
        #expect(throws: V2ResourceProviderError.configurationInvalid) {
            try V2ResourceStorageRegistry(storages: [b], defaultBinding: b.binding).verifyReferencedBindings([a.binding])
        }
    }
    @Test func digestMismatchCannotPublish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try V2LocalResourceStorage(root: root, binding: .init(id: "local", configurationRevision: 1))
        let ref = try storage.allocate()
        await #expect(throws: V2ResourceProviderError.integrityMismatch) {
            _ = try await storage.write(ref, byteCount: 3, sha256: Data(repeating: 0, count: 32), bytes: stream(Data([1,2,3])))
        }
        await #expect(throws: V2ResourceProviderError.notFound) { _ = try await storage.inspect(ref) }
    }
}
private actor ResourceTestChunks {
    let data: Data
    var offset = 0
    init(_ data: Data) { self.data = data }
    func next() -> Data? {
        guard offset < data.count else { return nil }
        let end = min(offset + 32_768, data.count)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }
}
private func stream(_ data: Data) -> V2ResourceByteStream {
    let chunks = ResourceTestChunks(data)
    return .init { await chunks.next() }
}

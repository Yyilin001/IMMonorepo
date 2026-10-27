import Foundation
import Testing
@testable import IMV2Core

struct ResourceVariantTests {
    @Test func originalMetadataRevisionDoesNotChangeByteIdentity() throws {
        let resource = V2ResourceKey(home: .room(.init(uuid: UUID())), mediaID: .init(uuid: UUID()))
        let key = V2ResourceVariantKey(resource: resource)
        let facts = try V2ResourceVariantDescriptor(key: key, checksum: .init(value: String(repeating: "a", count: 64)), byteCount: 12)
        #expect(try JSONDecoder().decode(V2ResourceVariantDescriptor.self, from: JSONEncoder().encode(facts)) == facts)
        let variant = ResourceVariantID(uuid: UUID())
        let first = V2ResourceVariantKey(resource: resource, rendition: .derived(id: variant, version: try .init(1)))
        let second = V2ResourceVariantKey(resource: resource, rendition: .derived(id: variant, version: try .init(2)))
        #expect(Set([key, first, second]).count == 3)
        #expect(V2ResourceVariantKey(resource: .init(home: .room(.init(uuid: UUID())), mediaID: resource.mediaID)) != key)
    }

    @Test(arguments: [Int64.min, -1, 0]) func invalidVersionsCannotCrossCodable(value: Int64) throws {
        #expect(throws: V2ResourceValidationError.invalidDescriptor) { try V2ResourceVariantVersion(value) }
        #expect(throws: V2ResourceValidationError.invalidDescriptor) {
            try JSONDecoder().decode(V2ResourceVariantVersion.self, from: JSONEncoder().encode(value))
        }
    }

    @Test func decodedByteFactsUseTheSameValidation() throws {
        let key = V2ResourceVariantKey(resource: .init(home: .account(.init(uuid: UUID())), mediaID: .init(uuid: UUID())))
        let value = try V2ResourceVariantDescriptor(key: key, checksum: .init(value: String(repeating: "b", count: 64)), byteCount: 1)
        var body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        body["byteCount"] = 0
        #expect(throws: V2ResourceValidationError.invalidDescriptor) {
            try JSONDecoder().decode(V2ResourceVariantDescriptor.self, from: JSONSerialization.data(withJSONObject: body))
        }
    }
}

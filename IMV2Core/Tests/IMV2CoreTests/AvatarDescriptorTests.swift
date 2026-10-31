import Foundation
import IMV2Core
import Testing

@Suite("Stable avatar content and temporary delivery")
struct AvatarDescriptorTests {
    @Test func metadataRoundTripsWithoutDownloadPlanAndRequiresByteCount() throws {
        let value = try descriptor()
        let encoded = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(V2ResourceAvatarAccess.self, from: encoded) == value)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "byteCount")
        let missing = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(V2ResourceAvatarAccess.self, from: missing) }
    }

    @Test func rotatingDeliveryDoesNotChangeContentIdentity() throws {
        let value = try descriptor()
        func delivery(_ path: String) throws -> V2ResourceAvatarAccess {
            try .init(mediaID: value.mediaID, variantID: value.variantID, version: value.version,
                checksum: value.checksum, byteCount: value.byteCount,
                plan: .init(mode: .httpGet, url: #require(URL(string: "https://objects.invalid/\(path)")),
                    expiresAt: Date().addingTimeInterval(60), expectedByteCount: value.byteCount, checksum: value.checksum))
        }
        let first = try delivery("first"), second = try delivery("second")
        #expect(first.hasSameContent(as: second) && first.hasSameContent(as: value))
        #expect(first.withoutDownloadPlan() == value)
        let changed = try V2ResourceAvatarAccess(mediaID: value.mediaID, variantID: value.variantID,
            version: 2, checksum: value.checksum, byteCount: value.byteCount, plan: nil)
        #expect(!changed.hasSameContent(as: value))
    }

    @Test func planCannotDescribeDifferentBytes() throws {
        let value = try descriptor()
        let plan = try V2ResourceTransferPlan(mode: .httpGet, url: #require(URL(string: "https://objects.invalid/avatar")),
            expiresAt: Date().addingTimeInterval(60), expectedByteCount: 8, checksum: value.checksum)
        #expect(throws: V2ResourceValidationError.invalidDescriptor) {
            try V2ResourceAvatarAccess(mediaID: value.mediaID, variantID: value.variantID, version: 1,
                checksum: value.checksum, byteCount: 4, plan: plan)
        }
    }

    private func descriptor() throws -> V2ResourceAvatarAccess {
        try .init(mediaID: .init(uuid: UUID()), variantID: .init(uuid: UUID()), version: 1,
            checksum: .init(value: String(repeating: "a", count: 64)), byteCount: 4, plan: nil)
    }
}

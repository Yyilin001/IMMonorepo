import Foundation
import IMV2Core
import Testing

@Suite("Durable resource metadata")
struct ResourceDescriptorTests {
    @Test(arguments: ["image/jpeg", "application/octet-stream", "application/vnd.example+json"])
    func contentTypesRemainValidatedAfterPersistence(value: String) throws {
        let type = try V2ResourceContentType(value)
        #expect(try JSONDecoder().decode(V2ResourceContentType.self, from: JSONEncoder().encode(type)) == type)
    }

    @Test(arguments: ["image", "image/", "IMAGE/JPEG", "image/jpeg\r\nAuthorization: bad", "text/plain; charset=utf-8"])
    func malformedContentTypesCannotEnterTheLocalCatalog(value: String) throws {
        #expect(throws: V2ResourceValidationError.invalidUploadRequest) { try V2ResourceContentType(value) }
        let encoded = try JSONEncoder().encode(value)
        #expect(throws: V2ResourceValidationError.invalidUploadRequest) { try JSONDecoder().decode(V2ResourceContentType.self, from: encoded) }
    }
    @Test func uploadNameRoundTripsAndIsRequiredOnWire() throws {
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()),
            usage: .messageAttachment(.init(uuid: UUID())), contentType: "image/jpeg", byteCount: 32,
            checksum: .init(value: String(repeating: "a", count: 64)), displayName: .init("../photo.jpg"))
        let encoded = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(V2ResourceUploadRequest.self, from: encoded).displayName.value == "photo.jpg")
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "displayName")
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(V2ResourceUploadRequest.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }
    @Test func filenamesAreDisplayValuesAndNeverPaths() throws {
        #expect(try V2ResourceDisplayName("../folder/照片.jpg").value == "照片.jpg")
        #expect(try V2ResourceDisplayName("C:\\folder\\file\n.pdf").value == "file.pdf")
        #expect(throws: V2ResourceValidationError.invalidDescriptor) { try V2ResourceDisplayName("..") }
        #expect(throws: V2ResourceValidationError.invalidDescriptor) { try V2ResourceDisplayName(String(repeating: "字", count: 100)) }
    }

    @Test func presentationDescriptorRoundTripsAndCannotDisagreeWithTheDisplayEnvelope() throws {
        let descriptor = try V2ResourceDescriptor(key: .init(home: .room(.init(uuid: UUID())), mediaID: .init(uuid: UUID())),
            revision: 1, displayName: .init("照片.png"), contentType: "image/png", byteCount: 42,
            checksum: .init(value: String(repeating: "a", count: 64)), state: .ready)
        let presentation = try V2MediaPresentation(mediaID: descriptor.key.mediaID, kind: .image,
            contentType: descriptor.contentType, byteCount: descriptor.byteCount, resourceDescriptor: descriptor)
        let encoded = try JSONEncoder().encode(presentation)
        #expect(try JSONDecoder().decode(V2MediaPresentation.self, from: encoded) == presentation)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["byteCount"] = 99
        #expect(throws: V2MediaValidationError.invalidPresentation) {
            try JSONDecoder().decode(V2MediaPresentation.self, from: JSONSerialization.data(withJSONObject: object))
        }
        #expect(throws: V2MediaValidationError.invalidPresentation) {
            try V2MediaPresentation(mediaID: .init(uuid: UUID()), kind: .image, contentType: descriptor.contentType,
                byteCount: descriptor.byteCount, resourceDescriptor: descriptor)
        }
    }

    @Test func wireDecodeCannotBypassValidation() throws {
        let descriptor = try V2ResourceDescriptor(key: .init(home: .room(.init(uuid: UUID())), mediaID: .init(uuid: UUID())),
            revision: 1, displayName: .init("photo.jpg"), contentType: "image/jpeg", byteCount: 32,
            checksum: .init(value: String(repeating: "a", count: 64)), state: .ready, pixelWidth: 100, pixelHeight: 200)
        #expect(try JSONDecoder().decode(V2ResourceDescriptor.self, from: JSONEncoder().encode(descriptor)) == descriptor)
        let encoded = try JSONEncoder().encode(descriptor)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["revision"] = 0
        #expect(throws: V2ResourceValidationError.invalidDescriptor) {
            try JSONDecoder().decode(V2ResourceDescriptor.self, from: JSONSerialization.data(withJSONObject: object))
        }
        #expect(throws: V2ResourceValidationError.invalidDescriptor) {
            try V2ResourceDescriptor(key: descriptor.key, revision: 1, displayName: descriptor.displayName,
                contentType: "image/jpeg", byteCount: 32, checksum: nil, state: .ready)
        }
    }
}

import Foundation

public struct V2ResourceVariantVersion: Hashable, Codable, Sendable {
    public let value: Int64
    public init(_ value: Int64) throws {
        guard value > 0 else { throw V2ResourceValidationError.invalidDescriptor }
        self.value = value
    }
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(Int64.self)) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(value)
    }
}

/// Original bytes are immutable for a resource identity. Metadata descriptor
/// revisions do not mint a new original. Derived renditions have explicit versions.
public struct V2ResourceVariantKey: Hashable, Codable, Sendable {
    public enum Rendition: Hashable, Codable, Sendable {
        case original
        case derived(id: ResourceVariantID, version: V2ResourceVariantVersion)
    }
    public let resource: V2ResourceKey
    public let rendition: Rendition
    public init(resource: V2ResourceKey, rendition: Rendition = .original) {
        self.resource = resource; self.rendition = rendition
    }
}

/// Durable byte facts, never a delivery plan or access grant. An immutable key
/// cannot be rebound to a different checksum or length.
public struct V2ResourceVariantDescriptor: Equatable, Codable, Sendable {
    public let key: V2ResourceVariantKey
    public let checksum: V2ResourceChecksum
    public let byteCount: Int64
    public init(key: V2ResourceVariantKey, checksum: V2ResourceChecksum, byteCount: Int64) throws {
        guard byteCount > 0 else { throw V2ResourceValidationError.invalidDescriptor }
        self.key = key; self.checksum = checksum; self.byteCount = byteCount
    }
    private enum CodingKeys: CodingKey { case key, checksum, byteCount }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(key: values.decode(V2ResourceVariantKey.self, forKey: .key),
                      checksum: values.decode(V2ResourceChecksum.self, forKey: .checksum), byteCount: values.decode(Int64.self, forKey: .byteCount))
    }
}

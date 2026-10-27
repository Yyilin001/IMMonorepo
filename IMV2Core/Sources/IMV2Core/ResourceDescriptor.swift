import Foundation

/// Logical identity, independent of storage placement and access credentials.
public struct V2ResourceKey: Hashable, Codable, Sendable {
    public let home: V2ResourceHome
    public let mediaID: MediaID
    public init(home: V2ResourceHome, mediaID: MediaID) {
        self.home = home; self.mediaID = mediaID
    }
}

/// Display-only filename. Never use it as a filesystem component or object key.
public struct V2ResourceDisplayName: Hashable, Codable, Sendable {
    public let value: String
    public static let attachment = Self(validatedValue: "附件")
    private init(validatedValue: String) { value = validatedValue }
    public init(_ rawValue: String) throws {
        let component = rawValue.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let normalized = component.precomposedStringWithCanonicalMapping
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let value = String(String.UnicodeScalarView(normalized)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != ".", value != "..", value.utf8.count <= 255 else {
            throw V2ResourceValidationError.invalidDescriptor
        }
        self.value = value
    }
    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(value)
    }
}

/// Durable descriptive facts. No URL, grant, storage key or provider credentials.
public struct V2ResourceDescriptor: Hashable, Codable, Sendable {
    public let key: V2ResourceKey
    public let revision: Int64
    public let displayName: V2ResourceDisplayName
    public let contentType: String
    public let byteCount: Int64
    public let checksum: V2ResourceChecksum?
    public let state: V2ResourceState
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let durationMilliseconds: Int64?

    public var kind: V2MediaPresentation.Kind { V2MediaPresentation.kind(forContentType: contentType) }

    public init(key: V2ResourceKey, revision: Int64, displayName: V2ResourceDisplayName, contentType: String,
                byteCount: Int64, checksum: V2ResourceChecksum?, state: V2ResourceState,
                pixelWidth: Int? = nil, pixelHeight: Int? = nil, durationMilliseconds: Int64? = nil) throws {
        guard revision > 0, byteCount > 0, V2ResourceMetadataValidation.contentType(contentType),
              (pixelWidth == nil) == (pixelHeight == nil), pixelWidth.map({ $0 > 0 }) ?? true,
              pixelHeight.map({ $0 > 0 }) ?? true, durationMilliseconds.map({ $0 >= 0 }) ?? true,
              state != .ready || checksum != nil else { throw V2ResourceValidationError.invalidDescriptor }
        self.key = key; self.revision = revision; self.displayName = displayName
        self.contentType = contentType; self.byteCount = byteCount; self.checksum = checksum; self.state = state
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.durationMilliseconds = durationMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case key, revision, displayName, contentType, byteCount, checksum, state, pixelWidth, pixelHeight, durationMilliseconds
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(key: c.decode(V2ResourceKey.self, forKey: .key), revision: c.decode(Int64.self, forKey: .revision),
            displayName: c.decode(V2ResourceDisplayName.self, forKey: .displayName), contentType: c.decode(String.self, forKey: .contentType),
            byteCount: c.decode(Int64.self, forKey: .byteCount), checksum: c.decodeIfPresent(V2ResourceChecksum.self, forKey: .checksum),
            state: c.decode(V2ResourceState.self, forKey: .state), pixelWidth: c.decodeIfPresent(Int.self, forKey: .pixelWidth),
            pixelHeight: c.decodeIfPresent(Int.self, forKey: .pixelHeight), durationMilliseconds: c.decodeIfPresent(Int64.self, forKey: .durationMilliseconds))
    }
}

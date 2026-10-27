import Foundation

public enum V2ResourceTimedMediaKind: String, Codable, Sendable { case audio, video }

/// Metadata measured from the immutable original, never accepted from an upload request.
public struct V2ResourceTimedMediaMetadata: Codable, Equatable, Sendable {
    public static let maximumDurationMilliseconds: Int64 = 31 * 24 * 60 * 60 * 1_000
    public let kind: V2ResourceTimedMediaKind
    public let durationMilliseconds: Int64
    public let dimensions: V2ResourceImageDimensions?
    public init(kind: V2ResourceTimedMediaKind, durationMilliseconds: Int64, dimensions: V2ResourceImageDimensions?) throws {
        guard durationMilliseconds > 0, durationMilliseconds <= Self.maximumDurationMilliseconds,
              (kind == .video) == (dimensions != nil) else { throw V2ResourceTransformError.contentRejected }
        self.kind = kind; self.durationMilliseconds = durationMilliseconds; self.dimensions = dimensions
    }
    private enum CodingKeys: CodingKey { case kind, durationMilliseconds, dimensions }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(kind: values.decode(V2ResourceTimedMediaKind.self, forKey: .kind),
            durationMilliseconds: values.decode(Int64.self, forKey: .durationMilliseconds),
            dimensions: values.decodeIfPresent(V2ResourceImageDimensions.self, forKey: .dimensions))
    }
}
public protocol V2ResourceMediaProbing: Sendable {
    func probe(_ input: V2StoredObjectFacts, contentType: String, storage: any V2ObjectStorage) async throws -> V2ResourceTimedMediaMetadata
}

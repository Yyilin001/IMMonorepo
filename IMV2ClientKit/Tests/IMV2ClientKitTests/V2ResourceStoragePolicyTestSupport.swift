import IMV2ClientKit

// Tests that intentionally exercise one finite total use explicit category
// limits as well. Production defaults do not impose this synthetic total cap.
extension V2ResourceStoragePolicy {
    static func testBounded(_ bytes: Int64) throws -> Self {
        try .init(maximumCacheBytes: bytes, maximumOriginalBytes: bytes,
                  maximumTemporaryBytes: bytes, maximumManagedBytes: bytes)
    }
}

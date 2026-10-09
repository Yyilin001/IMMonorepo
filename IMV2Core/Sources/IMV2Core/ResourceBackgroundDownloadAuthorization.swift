import Foundation

/// A provider explicitly permits the OS to retain one redirect-free GET request.
/// Its signed object capability binds this opaque grant to the exact bytes.
/// This descriptor contains no URL, login credentials or internal storage handle.
public struct V2ResourceBackgroundDownloadAuthorization: Equatable, Codable, Sendable {
    public let id: UUID
    public let expectedByteCount: Int64
    public let checksum: V2ResourceChecksum
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64

    public init(id: UUID, expectedByteCount: Int64, checksum: V2ResourceChecksum,
                issuedAt: Date, expiresAt: Date) throws {
        try self.init(id: id, expectedByteCount: expectedByteCount, checksum: checksum,
            issuedAtMilliseconds: V2ResourceTime.milliseconds(issuedAt),
            expiresAtMilliseconds: V2ResourceTime.milliseconds(expiresAt))
    }

    private init(id: UUID, expectedByteCount: Int64, checksum: V2ResourceChecksum,
                 issuedAtMilliseconds: Int64, expiresAtMilliseconds: Int64) throws {
        guard expectedByteCount > 0, expectedByteCount <= 512 * 1_024 * 1_024,
              issuedAtMilliseconds > 0, expiresAtMilliseconds > issuedAtMilliseconds,
              expiresAtMilliseconds - issuedAtMilliseconds <= 900_000
        else { throw V2ResourceValidationError.invalidTransferPlan }
        self.id = id; self.expectedByteCount = expectedByteCount; self.checksum = checksum
        self.issuedAtMilliseconds = issuedAtMilliseconds; self.expiresAtMilliseconds = expiresAtMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, expectedByteCount, checksum, issuedAtMilliseconds, expiresAtMilliseconds
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id),
            expectedByteCount: c.decode(Int64.self, forKey: .expectedByteCount),
            checksum: c.decode(V2ResourceChecksum.self, forKey: .checksum),
            issuedAtMilliseconds: c.decode(Int64.self, forKey: .issuedAtMilliseconds),
            expiresAtMilliseconds: c.decode(Int64.self, forKey: .expiresAtMilliseconds))
    }
}

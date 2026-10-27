import Foundation

/// Account preferences and admission bounds. A quota change never authorizes
/// deletion of originals, retained files or an active file consumer.
public struct V2ResourceStoragePolicy: Equatable, Codable, Sendable {
    public let maximumCacheBytes: Int64
    public let maximumOriginalBytes: Int64
    public let maximumTemporaryBytes: Int64
    public let maximumManagedBytes: Int64?
    public let minimumFreeBytes: Int64
    public let retainedWarningBytes: Int64

    public static let standard = Self(cache: 512 * 1_024 * 1_024, originals: 2 * 1_024 * 1_024 * 1_024,
        temporary: 512 * 1_024 * 1_024, managed: nil, free: 16 * 1_024 * 1_024, warning: 2 * 1_024 * 1_024 * 1_024)

    public init(maximumCacheBytes: Int64, maximumOriginalBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
                maximumTemporaryBytes: Int64 = 512 * 1_024 * 1_024, maximumManagedBytes: Int64? = nil,
                minimumFreeBytes: Int64 = 16 * 1_024 * 1_024, retainedWarningBytes: Int64 = 2 * 1_024 * 1_024 * 1_024) throws {
        let sizes = [maximumCacheBytes,maximumOriginalBytes,maximumTemporaryBytes,retainedWarningBytes]
        guard sizes.allSatisfy({ $0 > 0 && $0 <= Int64.max / 8 }), minimumFreeBytes >= 0, minimumFreeBytes <= Int64.max / 8,
              maximumManagedBytes.map({ $0 > 0 && $0 <= Int64.max / 8 }) ?? true else { throw V2ResourceStorageError.invalidRecord }
        self.init(cache: maximumCacheBytes, originals: maximumOriginalBytes, temporary: maximumTemporaryBytes,
                  managed: maximumManagedBytes, free: minimumFreeBytes, warning: retainedWarningBytes)
    }
    private init(cache: Int64, originals: Int64, temporary: Int64, managed: Int64?, free: Int64, warning: Int64) {
        maximumCacheBytes = cache; maximumOriginalBytes = originals; maximumTemporaryBytes = temporary
        maximumManagedBytes = managed; minimumFreeBytes = free; retainedWarningBytes = warning
    }
    private enum CodingKeys: CodingKey {
        case maximumCacheBytes, maximumOriginalBytes, maximumTemporaryBytes, maximumManagedBytes, minimumFreeBytes, retainedWarningBytes
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(maximumCacheBytes: values.decode(Int64.self, forKey: .maximumCacheBytes),
            maximumOriginalBytes: values.decode(Int64.self, forKey: .maximumOriginalBytes),
            maximumTemporaryBytes: values.decode(Int64.self, forKey: .maximumTemporaryBytes),
            maximumManagedBytes: values.decodeIfPresent(Int64.self, forKey: .maximumManagedBytes),
            minimumFreeBytes: values.decode(Int64.self, forKey: .minimumFreeBytes),
            retainedWarningBytes: values.decode(Int64.self, forKey: .retainedWarningBytes))
    }
}

public struct V2ResourceQuotaSnapshot: Equatable, Sendable {
    public let policy: V2ResourceStoragePolicy
    /// These charges use max(logical, allocated) for known file rows. They are
    /// distinct from UI allocated-byte totals and from future capacity promises.
    public let cacheBytes: Int64
    public let originalBytes: Int64
    public let retainedBytes: Int64
    /// Temporary source capacity plus any future publication still held by
    /// active or resumable work. Publication transfers that credit to a file.
    public let temporaryReservedBytes: Int64
    public var managedBytes: Int64 {
        [cacheBytes,originalBytes,retainedBytes,temporaryReservedBytes].reduce(0) { total, value in
            let sum = total.addingReportingOverflow(value)
            return sum.overflow ? .max : sum.partialValue
        }
    }
    public var cacheOverageBytes: Int64 { max(0, cacheBytes - policy.maximumCacheBytes) }
    public var originalOverageBytes: Int64 { max(0, originalBytes - policy.maximumOriginalBytes) }
    public var temporaryOverageBytes: Int64 { max(0, temporaryReservedBytes - policy.maximumTemporaryBytes) }
    public var retainedWarning: Bool { retainedBytes >= policy.retainedWarningBytes }
}

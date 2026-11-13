import Foundation

package enum V2AvailableDiskCapacity {
    package static func bytes(at directory: URL) throws -> Int64 {
        #if canImport(Darwin)
        let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        // Preserve Apple's purge-aware estimate and ordinary-block fallback.
        let estimate = capacity.volumeAvailableCapacityForImportantUsage ?? 0
        return estimate > 0 ? estimate : capacity.volumeAvailableCapacity.map(Int64.init) ?? 0
        #else
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        #endif
    }
}

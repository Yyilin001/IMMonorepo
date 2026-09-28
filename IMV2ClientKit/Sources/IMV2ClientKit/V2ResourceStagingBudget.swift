import Foundation
import Synchronization
#if canImport(OSLog)
import OSLog
#endif

/// Serializes checked file growth across attachment, foreground part and background
/// copies. Background source bytes reserve another equal amount for the OS upload copy.
public enum V2ResourceStagingBudget {
    public enum Failure:Error,Sendable { case exceeded,tooManyRoots,usageUnavailable }
    /// Process-wide admission observations, including the reserved OS upload copy.
    /// These are sampled during existing quota scans, not live filesystem usage.
    /// Both peaks include weighting/reservations and are not measured disk peaks.
    /// Peaks are nil until observed/admitted respectively. Early rejected scans
    /// contribute a known lower bound to observedPeakBytes, not a complete total.
    public struct Snapshot: Sendable {
        public let lastObservedBytes: Int64?
        public let observedPeakBytes: Int64?
        public let admittedReservationPeakBytes: Int64?
        public let capacityRejections: UInt64
        public let rootLimitRejections: UInt64
        public let unavailableUsageRejections: UInt64
    }
    private struct Observations: Sendable {
        var lastBytes: Int64?
        var observedPeak: Int64?
        var reservationPeak: Int64?
        var capacityRejections: UInt64 = 0
        var rootLimitRejections: UInt64 = 0
        var unavailableUsageRejections: UInt64 = 0
    }
    private static let observations = Mutex(Observations())
    public static func snapshot() -> Snapshot {
        observations.withLock { value in
            Snapshot(lastObservedBytes: value.lastBytes, observedPeakBytes: value.observedPeak,
                admittedReservationPeakBytes: value.reservationPeak,
                capacityRejections: value.capacityRejections, rootLimitRejections: value.rootLimitRejections,
                unavailableUsageRejections: value.unavailableUsageRejections)
        }
    }
    // An early quota stop observes only a lower bound. Do not publish it as
    // the completed scan total; the peak remains a sampled lower bound.
    private static func recordUsage(_ bytes: Int64, admittedReservation: Int64?, scanComplete: Bool = true) {
        let sample = observations.withLock { value in
            value.lastBytes = scanComplete ? bytes : nil
            value.observedPeak = max(value.observedPeak ?? 0, bytes)
            if let admittedReservation { value.reservationPeak = max(value.reservationPeak ?? 0, admittedReservation) }
            return value
        }
        #if canImport(OSLog)
        let reservation = admittedReservation.map { String($0) } ?? "denied"
        let peak = sample.observedPeak.map { String($0) } ?? "unknown"
        let reservationPeak = sample.reservationPeak.map { String($0) } ?? "unknown"
        Logger(subsystem: "IMV2ClientKit", category: "ResourceStaging").debug("Staging observedWeightedBytes=\(bytes) scanComplete=\(scanComplete) observedWeightedPeakBytes=\(peak, privacy: .public) admittedReservationBytes=\(reservation, privacy: .public) admittedReservationPeakBytes=\(reservationPeak, privacy: .public)")
        #endif
    }
    private static func recordRejection(_ failure: Failure) {
        let totals = observations.withLock { value in
            switch failure {
            case .exceeded: if value.capacityRejections < .max { value.capacityRejections += 1 }
            case .tooManyRoots: if value.rootLimitRejections < .max { value.rootLimitRejections += 1 }
            case .usageUnavailable:
                value.lastBytes = nil
                if value.unavailableUsageRejections < .max { value.unavailableUsageRejections += 1 }
            }
            return (value.capacityRejections, value.rootLimitRejections, value.unavailableUsageRejections)
        }
        #if canImport(OSLog)
        let reason: String
        switch failure { case .exceeded: reason = "capacity"; case .tooManyRoots: reason = "roots"; case .usageUnavailable: reason = "usageUnavailable" }
        Logger(subsystem: "IMV2ClientKit", category: "ResourceStaging").debug("Staging rejected reason=\(reason, privacy: .public) capacityRejections=\(totals.0) rootLimitRejections=\(totals.1) unavailableUsageRejections=\(totals.2)")
        #endif
    }
    private struct Root:Sendable { let url:URL;let background:Bool;let accountTree:Bool }
    private static let roots=Mutex<[String:Root]>([:])
    /// One admission scan is bounded even when a directory contains tiny files.
    /// Exhausting this limit leaves usage unknown and refuses growth.
    private static let maximumScanEntries = 65_536
    private static func pruneMissingRoots(_ registered: inout [String: Root]) throws {
        var missing: [String] = []
        for (key, root) in registered {
            do {
                guard try root.url.checkResourceIsReachable() else { throw Failure.usageUnavailable }
                let attributes = try root.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw Failure.usageUnavailable }
            } catch {
                let failure = error as NSError
                if failure.domain == NSCocoaErrorDomain &&
                    (failure.code == CocoaError.Code.fileNoSuchFile.rawValue || failure.code == CocoaError.Code.fileReadNoSuchFile.rawValue) {
                    missing.append(key)
                } else { throw Failure.usageUnavailable }
            }
        }
        for key in missing { registered.removeValue(forKey: key) }
    }
    public static let maximumBytes:Int64=512*1_024*1_024
    public static func register(directory:URL,background:Bool=false) throws {
        do { try registerChecked(directory: directory, background: background) }
        catch let failure as Failure { recordRejection(failure); throw failure }
    }
    private static func registerChecked(directory:URL,background:Bool) throws {
        try roots.withLock { registered in
            try pruneMissingRoots(&registered)
            let accountTree = !background && directory.lastPathComponent=="media-staging"
            let root=accountTree ? directory.deletingLastPathComponent().deletingLastPathComponent() : directory
            let key=root.standardizedFileURL.path+"|"+String(background)
            guard registered[key] != nil || registered.count<64 else { throw Failure.tooManyRoots }
            registered[key]=Root(url:root,background:background,accountTree:accountTree)
            try pruneMissingRoots(&registered)
            guard registered[key] != nil else { throw Failure.usageUnavailable }
        }
    }
    public static func withCopy<T>(directory:URL,additionalBytes:Int64,background:Bool=false,
                                   operation:() throws -> T) throws -> T {
        var enteredOperation = false
        do {
            return try checkedCopy(directory: directory, additionalBytes: additionalBytes, background: background) {
                enteredOperation = true
                return try operation()
            }
        } catch let failure as Failure {
            // A caller can throw the same error type after admission. That is a
            // copy/business failure, not another quota rejection.
            if !enteredOperation { recordRejection(failure) }
            throw failure
        }
    }
    private static func checkedCopy<T>(directory:URL,additionalBytes:Int64,background:Bool,
                                       operation:() throws -> T) throws -> T {
        guard additionalBytes>0,additionalBytes<=maximumBytes else { throw Failure.exceeded }
        return try roots.withLock { registered in
            try pruneMissingRoots(&registered)
            let accountTree = !background && directory.lastPathComponent=="media-staging"
            let root=accountTree ? directory.deletingLastPathComponent().deletingLastPathComponent() : directory
            let key=root.standardizedFileURL.path+"|"+String(background)
            guard registered[key] != nil || registered.count<64 else { throw Failure.tooManyRoots }
            registered[key]=Root(url:root,background:background,accountTree:accountTree)
            try pruneMissingRoots(&registered)
            guard registered[key] != nil else { throw Failure.usageUnavailable }
            var bytes: Int64 = 0
            var observed: [String: (size: Int64, weight: Int64)] = [:]
            var scannedEntries = 0
            do {
                for entry in registered.values {
                    let enumerationFailed = Mutex(false)
                    guard let files = FileManager.default.enumerator(at: entry.url,
                        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey],
                        errorHandler: { _, _ in enumerationFailed.withLock { $0 = true }; return false }) else {
                        throw Failure.usageUnavailable
                    }
                    while let file = files.nextObject() as? URL {
                        scannedEntries += 1
                        guard scannedEntries <= maximumScanEntries else { throw Failure.usageUnavailable }
                        if entry.accountTree && !file.pathComponents.contains("media-staging") { continue }
                        if entry.background && !file.pathComponents.contains("sources") { continue }
                        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
                        if values.isSymbolicLink == true { files.skipDescendants(); continue }
                        if values.isDirectory == true { continue }
                        guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize >= 0 else {
                            throw Failure.usageUnavailable
                        }
                        let path = file.standardizedFileURL.path
                        let size = Int64(fileSize), weight: Int64 = entry.background ? 2 : 1
                        let previous = observed[path]
                        // A file shared by ordinary and background roots reserves
                        // its source plus OS copy regardless of dictionary order.
                        guard previous == nil || previous?.size == size else { throw Failure.usageUnavailable }
                        let desiredWeight = max(previous?.weight ?? 0, weight)
                        let increment = size.multipliedReportingOverflow(by: desiredWeight - (previous?.weight ?? 0))
                        let total = bytes.addingReportingOverflow(increment.partialValue)
                        guard !increment.overflow, !total.overflow else { throw Failure.exceeded }
                        bytes = total.partialValue
                        observed[path] = (size, desiredWeight)
                        guard bytes <= maximumBytes else { throw Failure.exceeded }
                    }
                    guard !enumerationFailed.withLock({ $0 }) else { throw Failure.usageUnavailable }
                }
            } catch {
                recordUsage(bytes, admittedReservation: nil, scanComplete: false)
                if let failure = error as? Failure { throw failure }
                throw Failure.usageUnavailable
            }
            let addition=additionalBytes*(background ? 2 : 1)
            guard bytes<=maximumBytes-addition else {
                recordUsage(bytes, admittedReservation: nil)
                throw Failure.exceeded
            }
            recordUsage(bytes, admittedReservation: bytes + addition)
            return try operation()
        }
    }
}

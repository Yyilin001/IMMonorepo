import Foundation
import IMV2ServerContracts

/// Composition-time map of configured pool identities. Schemas and logical
/// shard aliases must use the same key when they share a physical pool.
public struct V2PhysicalDatabaseWorkAdmissions: Sendable {
    private let byKey: [String: V2DatabaseWorkAdmissionController]
    public var controllers: [V2DatabaseWorkAdmissionController] { Array(byKey.values) }

    public init(primaryKey: String, primary: V2DatabaseWorkAdmissionController,
                keys: [String], policy: V2DatabaseWorkAdmissionPolicy,
                coverageReservedQueued: [String: Int] = [:]) {
        let unique = Set(keys)
        precondition(!unique.isEmpty && unique.count <= 512 && unique.contains(primaryKey))
        byKey = Dictionary(uniqueKeysWithValues: unique.map { key in
            (key, key == primaryKey ? primary : V2DatabaseWorkAdmissionController(policy: policy,
                interactiveReadCoverageReservedQueued: coverageReservedQueued[key] ?? 0))
        })
    }

    public func controller(for key: String) -> V2DatabaseWorkAdmissionController? { byKey[key] }
}

/// Aggregate counters without merging the scheduling authority of independent
/// databases. Repeated references to one controller count only once.
public struct V2DatabaseWorkAdmissionMetricsGroup: Sendable {
    private let controllers: [V2DatabaseWorkAdmissionController]
    public init(_ controllers: [V2DatabaseWorkAdmissionController]) {
        var seen = Set<ObjectIdentifier>()
        self.controllers = controllers.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    public func snapshot() async -> V2DatabaseWorkAdmissionSnapshot {
        let snapshots = await withTaskGroup(of: V2DatabaseWorkAdmissionSnapshot.self) { group in
            for controller in controllers { group.addTask { await controller.snapshot() } }
            var result: [V2DatabaseWorkAdmissionSnapshot] = []
            for await snapshot in group { result.append(snapshot) }
            return result
        }
        return .init(foregroundWrite: merge(snapshots.map(\.foregroundWrite)),
            foregroundControlWrite: merge(snapshots.map(\.foregroundControlWrite)),
            interactiveRead: merge(snapshots.map(\.interactiveRead)), sync: merge(snapshots.map(\.sync)),
            interactiveReadPurposes: Dictionary(uniqueKeysWithValues: V2InteractiveReadAdmissionPurpose.allCases.map { purpose in
                (purpose, merge(snapshots.map { $0.interactiveReadPurposes[purpose] ?? .empty }))
            }))
    }

    private func merge(_ values: [V2DatabaseWorkAdmissionClassSnapshot]) -> V2DatabaseWorkAdmissionClassSnapshot {
        func count(_ key: KeyPath<V2DatabaseWorkAdmissionClassSnapshot, UInt64>) -> UInt64 {
            values.reduce(0) { saturating($0, $1[keyPath: key]) }
        }
        let waits = values.map(\.queueWait)
        let buckets = Dictionary(uniqueKeysWithValues: V2DatabaseWorkAdmissionWaitBucket.allCases.map { bucket in
            (bucket, waits.reduce(UInt64(0)) { saturating($0, $1.count(atOrBelow: bucket)) })
        })
        return .init(inFlight: values.reduce(0) { $0 + $1.inFlight }, queued: values.reduce(0) { $0 + $1.queued },
            admittedRequests: count(\.admittedRequests), queueFullRejections: count(\.queueFullRejections),
            timeoutRejections: count(\.timeoutRejections), cancelledRequests: count(\.cancelledRequests),
            queueWait: .init(samples: waits.reduce(0) { saturating($0, $1.samples) },
                sumMilliseconds: waits.reduce(0) { saturating($0, $1.sumMilliseconds) }, cumulativeBuckets: buckets))
    }

    private func saturating(_ first: UInt64, _ second: UInt64) -> UInt64 {
        let sum = first.addingReportingOverflow(second)
        return sum.overflow ? .max : sum.partialValue
    }
}

import Foundation
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts

struct V2PublicProfileSnapshotKey: Hashable, Codable, Sendable {
    let userID: UUID
    let revision: Int64
}

/// Immutable content by an authoritatively observed revision. No device,
/// relationship, visibility decision, alias or access lease enters this cache.
actor V2PublicProfileSnapshotCache {
    typealias Load = @Sendable ([V2PublicProfileSnapshotKey], ContinuousClock.Instant) async throws -> [V2PublicProfileSnapshotKey: V2PublicIdentity]
    private struct Entry { let value: V2PublicIdentity; let bytes: Int; var touched: ContinuousClock.Instant }
    private struct Flight { let keys: [V2PublicProfileSnapshotKey]; let task: Task<[V2PublicProfileSnapshotKey: V2PublicIdentity], any Error> }
    private let load: Load
    private var values: [V2PublicProfileSnapshotKey: Entry] = [:]
    private var flights: [UUID: Flight] = [:]
    private var loading: [V2PublicProfileSnapshotKey: UUID] = [:]
    private var bytes = 0
    private var closed = false
    private(set) var originBatches = 0

    init(load: @escaping Load) { self.load = load }

    func read(_ requested: [V2PublicProfileSnapshotKey], deadline: ContinuousClock.Instant) async throws -> [V2PublicProfileSnapshotKey: V2PublicIdentity] {
        guard !closed else { throw V2ProfileControlBatchError.closed }
        guard requested.count <= 100, requested.allSatisfy({ $0.revision > 0 }) else { throw V2ProfileViewReadError.invalidRequest }
        try Task.checkCancellation()
        guard .now < deadline else { throw V2ProfileControlBatchError.deadlineExceeded }
        let keys = Set(requested)
        var result: [V2PublicProfileSnapshotKey: V2PublicIdentity] = [:]
        for key in keys {
            if var entry = values[key] { entry.touched = .now; values[key] = entry; result[key] = entry.value }
        }
        let missing = keys.filter { values[$0] == nil && loading[$0] == nil }
        if !missing.isEmpty {
            guard flights.count < 4 else { throw V2ResourceProviderError.throttled(retryAfter: 1) }
            let id = UUID(), batch = Array(missing), loader = load
            let task = Task { try await loader(batch, deadline) }
            flights[id] = .init(keys: batch, task: task)
            for key in batch { loading[key] = id }
            originBatches += 1
        }
        // Capture the actual tasks before suspending: another waiter can finish
        // and remove their table entries without invalidating this ownership.
        let waits = Set(keys.compactMap { loading[$0] }).compactMap { id in flights[id].map { (id, $0) } }
        for (id, flight) in waits {
            do {
                let loaded = try await flight.task.value
                guard Set(loaded.keys).isSubset(of: Set(flight.keys)),
                      loaded.allSatisfy({ $0.value.userID.uuidValue == $0.key.userID }) else { throw V2ProfileControlBatchError.corruptResult }
                complete(id, flight: flight, values: loaded)
                for (key, value) in loaded where keys.contains(key) { result[key] = value }
            } catch { complete(id, flight: flight, values: [:]); throw error }
        }
        try Task.checkCancellation()
        guard !closed else { throw V2ProfileControlBatchError.closed }
        guard .now < deadline else { throw V2ProfileControlBatchError.deadlineExceeded }
        return result
    }

    private func complete(_ id: UUID, flight: Flight, values loaded: [V2PublicProfileSnapshotKey: V2PublicIdentity]) {
        guard flights.removeValue(forKey: id) != nil else { return }
        for key in flight.keys where loading[key] == id { loading.removeValue(forKey: key) }
        guard !closed else { return }
        for (key, value) in loaded {
            guard let cost = try? JSONEncoder().encode(value).count, cost <= 16 * 1_024 else { continue }
            if let old = values.removeValue(forKey: key) { bytes -= old.bytes }
            while values.count >= 2_048 || bytes + cost > 4 * 1_024 * 1_024 {
                guard let oldest = values.min(by: { $0.value.touched < $1.value.touched }) else { break }
                bytes -= oldest.value.bytes; values.removeValue(forKey: oldest.key)
            }
            values[key] = .init(value: value, bytes: cost, touched: .now); bytes += cost
        }
    }

    func close() async {
        closed = true; values.removeAll(); bytes = 0
        let running = flights.values.map(\.task)
        for task in running { task.cancel() }
        for task in running { _ = await task.result }
    }
}

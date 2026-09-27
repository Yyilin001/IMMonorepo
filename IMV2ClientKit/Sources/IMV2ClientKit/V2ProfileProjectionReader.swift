import IMV2Core

/// Refreshes content used by local search/routing through the account's shared
/// authorization and HTTP budget. Returned content is not a display permission:
/// a view must obtain its own activation and current presentation snapshot.
public struct V2ProfileProjectionReader: V2ProfileViewReading {
    private let presentations: V2ProfilePresentationRepository

    public init(presentations: V2ProfilePresentationRepository) {
        self.presentations = presentations
    }

    public func readProfileViews(_ keys: [V2ProfileViewLookupKey]) async throws -> [V2ProfileViewLookupResult] {
        guard !keys.isEmpty, keys.count <= V2ProfileViewLookupLimits.maximumKeys,
              Set(keys).count == keys.count else { throw V2ProfileViewClientError.invalidRequest }
        try Task.checkCancellation()
        let activation = await presentations.activate()
        do {
            // The repository splits distinct room/direct contexts into batches
            // of at most eight, with at most two actual HTTP flights for the
            // whole account. Projection refreshes never outrank visible rows.
            let values = try await withThrowingTaskGroup(of: (Int, V2ProfileViewLookupResult).self) { group in
                for (index, key) in keys.enumerated() {
                    group.addTask {
                        let value = try await presentations.presentation(for: key, activation: activation, priority: .prefetch)
                        try Task.checkCancellation()
                        return (index, value.map { .profile(key: key, view: $0.view) } ?? .unavailable(key: key))
                    }
                }
                var values: [(Int, V2ProfileViewLookupResult)] = []
                for try await value in group { values.append(value) }
                return values.sorted { $0.0 < $1.0 }.map(\.1)
            }
            // Waiting for later batches may outlive an earlier grant, or an
            // invalidation may replace it. Do not persist a partial/stale batch.
            for value in values {
                try Task.checkCancellation()
                if case .profile(let key, let profile) = value {
                    guard let current = await presentations.cachedSnapshot(for: key, activation: activation),
                          current.presentation.view == profile else { throw V2ProfilePresentationError.staleResponse }
                }
            }
            await presentations.deactivate(activation)
            try Task.checkCancellation()
            return values
        } catch {
            await presentations.deactivate(activation)
            throw error
        }
    }
}

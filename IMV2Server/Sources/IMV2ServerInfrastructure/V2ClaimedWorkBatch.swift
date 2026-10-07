/// Executes only an already bounded, already claimed batch. The caller owns the
/// claim policy and lease lifecycle; no shared queue or nested concurrency budget.
/// Results are reduced in completion order on the parent task. Child failures
/// cancel siblings and all children finish before this function returns.
func v2ProcessClaimedWorkBatch<Lease: Sendable, Outcome: Sendable, Summary: Sendable>(
    _ leases: [Lease], initial: Summary,
    process: @escaping @Sendable (Lease) async throws -> Outcome,
    accumulate: (inout Summary, Outcome) -> Void
) async throws -> Summary {
    try await withThrowingTaskGroup(of: Outcome.self) { group in
        for lease in leases { group.addTask { try await process(lease) } }
        var summary = initial
        for try await outcome in group { accumulate(&summary, outcome) }
        return summary
    }
}

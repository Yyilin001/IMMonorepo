import IMV2ServerContracts
import Foundation

/// Owns the optional author's complete dependency order. The caller must finish
/// close before destroying its reader's database/Actor/provider dependencies.
public actor V2AuthorPresentationRuntime {
    public nonisolated let dispatcher: V2AuthorPresentationDispatcher
    public nonisolated let ingress: V2AuthorPresentationIngress
    public nonisolated let readDiagnostics: @Sendable () -> V2ProfilePresentationReadDiagnostics.Snapshot
    private let closeReader: @Sendable () async -> Void
    private var closing: Task<Void, Never>?
    private var startingChanges: Task<V2AuthorProfileChangeBatch, any Error>?
    private var changeWorker: Task<Void, Never>?
    private var changeReadFailures = 0

    public init(configuration: V2AuthorPresentationDispatcher.Configuration,
                ingressConfiguration: V2AuthorPresentationIngress.Configuration,
                readBatch: @escaping V2AuthorPresentationDispatcher.BatchRead,
                readDiagnostics: @escaping @Sendable () -> V2ProfilePresentationReadDiagnostics.Snapshot = { .init() },
                closeReader: @escaping @Sendable () async -> Void) {
        let dispatcher = V2AuthorPresentationDispatcher(configuration: configuration, readBatch: readBatch)
        self.dispatcher = dispatcher
        ingress = .init(configuration: ingressConfiguration, dispatcher: dispatcher)
        self.closeReader = closeReader
        self.readDiagnostics = { readDiagnostics().merging(dispatcher.readDiagnostics.snapshot()) }
    }

    public func close() async {
        if let closing { await closing.value; return }
        // Even a cancelled composition task must drain the actual operations.
        // Reentrant closes join this same task; the reader closes exactly once.
        let starting = startingChanges, worker = changeWorker
        starting?.cancel(); worker?.cancel()
        let task = Task { [ingress, dispatcher, closeReader] in
            _ = await starting?.result
            await worker?.value
            await ingress.close()
            await dispatcher.close()
            await closeReader()
        }
        closing = task
        await task.value
    }

    /// Establish the source boundary before accepting connections. Startup and
    /// shutdown retain their real database task even if cancellation is ignored.
    public func startProfileChanges(_ reader: any V2AuthorProfileChangeReading) async throws {
        guard closing == nil, startingChanges == nil, changeWorker == nil else {
            throw V2ResourceProviderError.configurationInvalid
        }
        let start = Task { try await reader.readChanges(after: nil) }
        startingChanges = start
        defer { startingChanges = nil }
        let initial = try await withTaskCancellationHandler {
            let value = try await start.value
            try Task.checkCancellation()
            return value
        } onCancel: { start.cancel() }
        guard closing == nil, initial.resetRequired else { throw V2ResourceProviderError.configurationInvalid }
        await dispatcher.resetVisibleProfiles()
        await dispatcher.profileSourceCaughtUp()
        guard closing == nil else { throw CancellationError() }
        changeWorker = Task { await self.runProfileChanges(reader, cursor: initial.head) }
    }

    public func profileChangeFailures() -> Int { changeReadFailures }

    private func runProfileChanges(_ reader: any V2AuthorProfileChangeReading, cursor initial: UInt64) async {
        var cursor = initial
        while !Task.isCancelled {
            var delay = Duration.milliseconds(100)
            do {
                let batch = try await reader.readChanges(after: cursor)
                try Task.checkCancellation()
                if batch.resetRequired || batch.head != cursor { await dispatcher.profileSourceUnavailable() }
                if batch.resetRequired {
                    await dispatcher.resetVisibleProfiles()
                    cursor = batch.head
                } else {
                    guard batch.head >= cursor, !batch.changes.isEmpty || batch.head == cursor else {
                        throw V2ResourceProviderError.configurationInvalid
                    }
                    for change in batch.changes {
                        try Task.checkCancellation()
                        guard change.sequence == cursor + 1 else { throw V2ResourceProviderError.configurationInvalid }
                        await dispatcher.profileDidChange(change)
                        cursor = change.sequence
                    }
                    if cursor < batch.head { delay = .milliseconds(1) }
                }
                if cursor == batch.head { await dispatcher.profileSourceCaughtUp() }
                else { await dispatcher.profileSourceUnavailable() }
            } catch {
                await dispatcher.profileSourceUnavailable()
                if Task.isCancelled { return }
                changeReadFailures += 1
                delay = .milliseconds(500)
            }
            await dispatcher.retryVisibleProfiles()
            do { try await Task.sleep(for: delay) } catch { return }
        }
    }
}

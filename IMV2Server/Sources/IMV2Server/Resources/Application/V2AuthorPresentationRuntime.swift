import Foundation

/// Owns the optional author's complete dependency order. The caller must finish
/// close before destroying its reader's database/Actor/provider dependencies.
public actor V2AuthorPresentationRuntime {
    public nonisolated let dispatcher: V2AuthorPresentationDispatcher
    public nonisolated let ingress: V2AuthorPresentationIngress
    private let closeReader: @Sendable () async -> Void
    private var closing: Task<Void, Never>?

    public init(configuration: V2AuthorPresentationDispatcher.Configuration,
                ingressConfiguration: V2AuthorPresentationIngress.Configuration,
                read: @escaping V2AuthorPresentationDispatcher.Read,
                closeReader: @escaping @Sendable () async -> Void) {
        let dispatcher = V2AuthorPresentationDispatcher(configuration: configuration, read: read)
        self.dispatcher = dispatcher
        ingress = .init(configuration: ingressConfiguration, dispatcher: dispatcher)
        self.closeReader = closeReader
    }

    public func close() async {
        if let closing { await closing.value; return }
        // Even a cancelled composition task must drain the actual operations.
        // Reentrant closes join this same task; the reader closes exactly once.
        let task = Task { [ingress, dispatcher, closeReader] in
            await ingress.close()
            await dispatcher.close()
            await closeReader()
        }
        closing = task
        await task.value
    }
}

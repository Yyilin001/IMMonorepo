/// Installed by trusted gateway composition, never supplied by an RPC publisher.
/// Implementations synchronously validate current source lease, routing, session,
/// interest and pre-authorized cold cut before committing the shared projection.
/// An applied result must describe that actual commit, not ingress admission.
public protocol V2RealtimeJournalProjectionHandler: Sendable {
    func applyJournalProjection(_ batch: V2RealtimeJournalProjectionBatch,
                                authenticatedServiceID: String) -> V2RealtimeJournalProjectionResult
}

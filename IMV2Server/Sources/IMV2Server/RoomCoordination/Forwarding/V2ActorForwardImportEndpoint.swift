import Foundation
import IMV2ActorContracts

/// Durable target delivery calls the same RoomRef import capability as the
/// foreground coordinator. Media byte copying retains its own work lease.
public struct V2ActorForwardImportEndpoint: V2ForwardExportDelivering {
    private let inbox: PostgresV2ForwardInboxStore
    private let media: V2ForwardMediaImportWorker?
    private let roomCommand: @Sendable (V2RoomForwardCommand, ContinuousClock.Instant) async throws -> V2RoomForwardResult
    private let deadline: @Sendable () -> ContinuousClock.Instant

    public init(inbox: PostgresV2ForwardInboxStore,
                media: V2ForwardMediaImportWorker? = nil,
                roomCommand: @escaping @Sendable (V2RoomForwardCommand, ContinuousClock.Instant) async throws -> V2RoomForwardResult,
                deadline: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.inbox = inbox; self.media = media
        self.roomCommand = roomCommand; self.deadline = deadline
    }

    public func deliver(_ export: V2ForwardExport) async throws -> V2ForwardTerminalReceipt? {
        try Task.checkCancellation()
        var outcome = try await importOnce(export)
        if outcome == .pending(.media) {
            guard let media else { throw V2ForwardDeliveryError.targetUnavailable }
            // Media copy is an independent leased workflow: its inbox/media
            // rows carry exact export, owner epoch, claim, object and upload
            // identities. Copy readiness grants no message acceptance. Always
            // return through a fresh RoomRef import turn after the copy, so
            // target membership and activation are checked again.
            switch try await media.runOnce(exportID: export.intent.exportID) {
            case .ready, .rejected: outcome = try await importOnce(export)
            case .paused: throw V2ForwardDeliveryError.mediaPaused
            case .idle, .retryScheduled, .superseded: return nil
            }
        }
        if case .pending = outcome { return nil }
        guard let receipt = try await inbox.terminalReceipt(exportID: export.intent.exportID),
              receipt.matches(export) else { throw V2ForwardDeliveryError.receiptMismatch }
        return receipt
    }

    private func importOnce(_ export: V2ForwardExport) async throws -> V2ForwardImportOutcome {
        guard case .imported(let result) = try await roomCommand(
            .importExport(.init(domain: export)), deadline()) else {
            throw V2ForwardDeliveryError.receiptMismatch
        }
        return try result.toDomain()
    }
}

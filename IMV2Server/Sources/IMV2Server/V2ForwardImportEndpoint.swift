import Foundation
import IMV2Core

/// Reuses the target owner's configured write store, including admission,
/// projection shadow forwarding and post-commit recovery adapters.
public struct V2ForwardImportEndpoint: V2ForwardExportDelivering {
    private let inbox: PostgresV2ForwardInboxStore
    private let write: PostgresV2RoomWriteStore
    private let media: V2ForwardMediaImportWorker?
    private let profile: V2CapacityProfile
    private let limits: V2MessageCommandLimits
    private let now: @Sendable () -> Date

    public init(inbox: PostgresV2ForwardInboxStore, write: PostgresV2RoomWriteStore,
                media: V2ForwardMediaImportWorker? = nil, capacityProfile: V2CapacityProfile,
                limits: V2MessageCommandLimits, now: @escaping @Sendable () -> Date = Date.init) {
        self.inbox = inbox; self.write = write; self.media = media
        profile = capacityProfile; self.limits = limits; self.now = now
    }

    public func deliver(_ export: V2ForwardExport) async throws -> V2ForwardTerminalReceipt? {
        try Task.checkCancellation()
        var outcome = try await accept(export)
        if outcome == .pending(.media) {
            guard let media else { throw V2ForwardDeliveryError.targetUnavailable }
            switch try await media.runOnce(exportID: export.intent.exportID) {
            case .ready, .rejected: outcome = try await accept(export)
            case .paused: throw V2ForwardDeliveryError.mediaPaused
            case .idle, .retryScheduled, .superseded: return nil
            }
        }
        if case .pending = outcome { return nil }
        guard let receipt = try await inbox.terminalReceipt(exportID: export.intent.exportID), receipt.export == export
        else { throw V2ForwardDeliveryError.receiptMismatch }
        return receipt
    }

    private func accept(_ export: V2ForwardExport) async throws -> V2ForwardImportOutcome {
        try Task.checkCancellation()
        let time = now()
        return try await write.importForwardExport(export, capacityProfile: profile, limits: limits,
                                                   identifiers: V2AcceptanceIDFactory().make(at: time), now: time)
    }
}

/// Physical owner registry, never a fallback scan or a substitute owner.
public struct V2ConfiguredForwardExportDelivery: V2ForwardExportDelivering {
    private let targets: [String: any V2ForwardExportDelivering]
    public init(targets: [String: any V2ForwardExportDelivering]) throws {
        guard !targets.isEmpty, targets.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw V2ForwardDeliveryError.invalidConfiguration }
        self.targets = targets
    }
    public func deliver(_ export: V2ForwardExport) async throws -> V2ForwardTerminalReceipt? {
        guard let target = targets[export.intent.targetShardID] else { throw V2ForwardDeliveryError.targetUnavailable }
        return try await target.deliver(export)
    }
}

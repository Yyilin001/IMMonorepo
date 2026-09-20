@testable import IMV2Server

/// Target commits normally, but the source never receives the terminal ACK.
struct ForwardReceiptLosingDelivery: V2ForwardExportDelivering {
    let target: V2ForwardImportEndpoint

    func deliver(_ export: V2ForwardExport) async throws -> V2ForwardTerminalReceipt? {
        guard try await target.deliver(export) != nil else { return nil }
        throw V2ForwardDeliveryError.targetUnavailable
    }
}

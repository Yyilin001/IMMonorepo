import Foundation
import IMV2Core

/// Created only by reading a durable terminal target inbox. The trusted owner
/// transport carries this capability; a client status or checksum is not one.
public struct V2ForwardTerminalReceipt: Equatable, Sendable {
    public let export: V2ForwardExport
    public let outcome: V2ForwardImportOutcome

    init(export: V2ForwardExport, outcome: V2ForwardImportOutcome) throws {
        switch outcome {
        case .accepted(let messageID, let sequence):
            guard messageID.uuidValue != nil, sequence > 0, sequence <= UInt64(Int64.max)
            else { throw V2ForwardInboxError.corruptPersistenceState }
        case .rejected(let code):
            guard !code.isEmpty, code.utf8.count <= 128
            else { throw V2ForwardInboxError.corruptPersistenceState }
        case .pending: throw V2ForwardInboxError.corruptPersistenceState
        }
        self.export = export
        self.outcome = outcome
    }
}

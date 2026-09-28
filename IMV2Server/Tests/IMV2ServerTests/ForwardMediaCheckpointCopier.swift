@testable import IMV2Server

/// Runs a controlled database/provider interleaving inside the real worker's
/// outstanding copy call. Byte I/O still uses the actual local copier.
struct ForwardMediaCheckpointCopier: V2ForwardMediaObjectCopying {
    let base: any V2ForwardMediaObjectCopying
    let beforeCopy: Bool
    let checkpoint: @Sendable (V2ForwardMediaImportLease) async throws -> Void

    func copy(_ lease: V2ForwardMediaImportLease) async throws -> V2ForwardMediaCopyReceipt {
        if beforeCopy { try await checkpoint(lease) }
        let receipt = try await base.copy(lease)
        if !beforeCopy { try await checkpoint(lease) }
        return receipt
    }
}

import Foundation

/// An in-memory projection of an already adopted durable mapping. It grants
/// neither transfer admission nor file access and contains no URL or path.
struct V2ResourceNativeProgressBinding: Sendable {
    let transfer: V2ManagedResourceTransferID
    let mapping: UUID
    let identifier: Int
    let expectedBytes: Int64
    let expiresAt: Date
}

enum V2ResourceNativeProgress {
    static func snapshot(bindings: [V2ResourceNativeProgressBinding], tasks: [V2BackgroundSystemTask], now: Date) -> [V2ManagedResourceTransferID: V2ResourceTransferAttemptProgress] {
        guard tasks.count <= 64, bindings.count <= 64 else { return [:] }
        var result: [V2ManagedResourceTransferID: V2ResourceTransferAttemptProgress] = [:]
        var seen: Set<V2ManagedResourceTransferID> = []
        for binding in bindings {
            guard seen.insert(binding.transfer).inserted else { result[binding.transfer] = nil; continue }
            guard binding.expectedBytes > 0, binding.expiresAt > now else { continue }
            let matches = tasks.filter { $0.mappingID == binding.mapping && $0.identifier == binding.identifier }
            guard matches.count == 1, let task = matches.first else { continue }
            let bytes: Int64?
            switch binding.transfer {
            case .upload: bytes = task.sentBytes
            case .download: bytes = task.receivedBytes
            case .serverImport: continue
            }
            guard let bytes, bytes >= 0, bytes <= binding.expectedBytes else { continue }
            result[binding.transfer] = .init(attemptID: binding.mapping, transferredBytes: bytes, expectedBytes: binding.expectedBytes)
        }
        return result
    }
}

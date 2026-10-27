import Foundation
import IMV2Core

public struct V2ResourceVariantSnapshot: Equatable, Sendable {
    public enum LocalState: Equatable, Sendable {
        case needsDownload
        case available(storage: V2ResourceFileStorage, allocatedBytes: Int64)
        case invalid
    }
    public let descriptor: V2ResourceVariantDescriptor
    public let isRetained: Bool
    public let localState: LocalState
}

struct V2ResourceVariantRecord: Sendable {
    let descriptor: V2ResourceVariantDescriptor
    let fileID: V2LocalResourceFileID?
    let isRetained: Bool
}

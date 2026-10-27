import Foundation

/// A download owns its network output and a future immutable publication.
/// Slices own one temporary file and never become a published resource.
enum V2ResourceTemporaryFootprint: Sendable {
    case singleFile
    case downloadAndPublication

    func publicationBytes(for bytes: Int64) -> Int64 {
        switch self { case .singleFile: 0; case .downloadAndPublication: bytes }
    }
}

struct V2ResourceTemporaryReservationRecord: Sendable {
    enum Location: Equatable, Sendable {
        case foreground
        case backgroundDownload(session: UUID, mapping: UUID)
    }
    let id: UUID
    let identity: String
    let bytes: Int64
    let publicationBytes: Int64
    let location: Location
    var reservedBytes: Int64 { bytes + publicationBytes }
}

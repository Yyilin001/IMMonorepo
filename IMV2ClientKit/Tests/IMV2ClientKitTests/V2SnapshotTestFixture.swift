import Foundation
import IMV2Core
@testable import IMV2ClientKit

struct SnapshotFixture {
    let manifest: V2ClientSnapshotManifest
    let pages: [V2ClientSnapshotPage]
}

func makeSnapshotFixture(
    reset: V2ClientResetRequired,
    pages: [V2SnapshotProjectionV3Page],
    capabilityProfile: String = "base"
) throws -> SnapshotFixture {
    var rolling = V2SnapshotV3Digest.initial(
        baseSequence: reset.baseSequence,
        capabilityProfile: capabilityProfile
    )
    var totalBytes: UInt64 = 0
    var totalItems: UInt64 = 0
    var encoded: [(payload: Data, digest: String, page: V2SnapshotProjectionV3Page)] = []
    for (index, page) in pages.enumerated() {
        let payload = try V2SnapshotProjectionV3Codec.encode(page)
        let digest = V2SnapshotV3Digest.page(payload)
        rolling = V2SnapshotV3Digest.next(
            previous: rolling,
            pageIndex: UInt32(index),
            pageDigest: digest,
            firstKey: page.firstKey,
            lastKey: page.lastKey,
            itemCount: UInt32(page.items.count)
        )
        totalBytes += UInt64(payload.count)
        totalItems += UInt64(page.items.count)
        encoded.append((payload, digest, page))
    }
    let manifest = try V2ClientSnapshotManifest(
        reset: reset,
        rootDigest: rolling,
        pageCount: pages.count,
        totalItems: totalItems,
        totalBytes: totalBytes,
        nextSyncToken: .init("snapshot-v3-token"),
        receipt: .init("snapshot-v3-receipt"),
        capabilityProfile: capabilityProfile
    )
    return .init(
        manifest: manifest,
        pages: try encoded.enumerated().map { index, value in
            try .init(
                index: index,
                digest: value.digest,
                firstKey: value.page.firstKey,
                lastKey: value.page.lastKey,
                itemCount: value.page.items.count,
                payload: value.payload
            )
        }
    )
}

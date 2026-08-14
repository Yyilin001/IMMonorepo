import Foundation
import Testing
@testable import IMV2Core

struct SnapshotProjectionV3Tests {
    @Test func pageRoundTripsInStableKeyOrder() throws {
        let first = try item(kind: "message", key: "0001", sequence: 4)
        let second = try item(kind: "message", key: "0002", sequence: 8)
        let page = try V2SnapshotProjectionV3Page(items: [first, second])

        let encoded = try V2SnapshotProjectionV3Codec.encode(page)

        #expect(try V2SnapshotProjectionV3Codec.decode(encoded) == page)
        #expect(page.firstKey == first.key)
        #expect(page.lastKey == second.key)
    }

    @Test func pageRejectsDuplicateOrDescendingKeys() throws {
        let later = try item(kind: "room", key: "b", sequence: 1)
        let earlier = try item(kind: "room", key: "a", sequence: 2)

        #expect(throws: V2SnapshotProjectionV3Error.invalidPage) {
            _ = try V2SnapshotProjectionV3Page(items: [later, earlier])
        }
        #expect(throws: V2SnapshotProjectionV3Error.invalidPage) {
            _ = try V2SnapshotProjectionV3Page(items: [earlier, earlier])
        }
    }

    @Test func itemAndPageSizeLimitsAreEnforced() throws {
        let oversized = Data(repeating: 1, count: V2SnapshotProjectionV3Codec.maximumItemBytes + 1)
        #expect(throws: V2SnapshotProjectionV3Error.invalidItem) {
            _ = try V2SnapshotProjectionItem(
                key: .init(projectionKind: "message", entityKey: "m"),
                sourceEventID: .init("00000000-0000-0000-0000-000000000001"),
                sequence: 1,
                payload: oversized
            )
        }
    }

    @Test func maximumValidItemAlwaysFitsAProtocolPage() throws {
        let item = try V2SnapshotProjectionItem(
            key: .init(
                projectionKind: String(repeating: "k", count: 64),
                entityKey: String(repeating: "e", count: 512)
            ),
            sourceEventID: .init("ffffffff-ffff-ffff-ffff-ffffffffffff"),
            sequence: UInt64.max,
            payload: Data(repeating: 0xff, count: V2SnapshotProjectionV3Codec.maximumItemBytes)
        )

        let encoded = try V2SnapshotProjectionV3Codec.encode(.init(items: [item]))

        #expect(encoded.count <= V2SnapshotProjectionV3Codec.maximumPageBytes)
        #expect(try V2SnapshotProjectionV3Codec.decode(encoded).items == [item])
    }

    private func item(kind: String, key: String, sequence: UInt64) throws -> V2SnapshotProjectionItem {
        try .init(
            key: .init(projectionKind: kind, entityKey: key),
            sourceEventID: .init(String(format: "00000000-0000-0000-0000-%012llu", sequence)),
            sequence: sequence,
            payload: Data("{\"value\":\(sequence)}".utf8)
        )
    }
}

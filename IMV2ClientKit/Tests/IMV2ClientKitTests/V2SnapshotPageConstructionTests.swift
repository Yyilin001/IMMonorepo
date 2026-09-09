import Foundation
import IMV2Core
import IMV2ClientKit
import Testing

struct V2SnapshotPageConstructionTests {
    @Test(arguments: ["index", "count"], [Int.min, -1, 0, 1, 499, 500, 501, 4095, 4096, Int.max])
    func bounds(field: String, value: Int) throws {
        let key = try V2SnapshotProjectionKey(projectionKind: "message", entityKey: "message")
        func construct() throws -> Int {
            let page = try V2ClientSnapshotPage(index: field == "index" ? value : 0, digest: "digest", firstKey: key, lastKey: key, itemCount: field == "count" ? value : 1, payload: Data())
            return field == "index" ? page.index : page.itemCount
        }
        let valid = field == "index" ? (0..<V2SnapshotProjectionV3Codec.maximumPageCount).contains(value) : (1...V2SnapshotProjectionV3Codec.maximumPageItems).contains(value)
        if valid { #expect(try construct() == value) }
        else {
            let error: V2ClientSyncError = field == "index" ? .snapshotMismatch : .snapshotProjectionConflict
            #expect(throws: error) { try construct() }
        }
    }
}

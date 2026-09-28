import Foundation
import GRDB
@testable import IMV2ClientKit
import Testing

@Suite("V2 pending-intent lookup indexes")
struct V2PendingIntentIndexTests {
    @Test("the local-store migration creates every semantic pending-intent index")
    func createsSemanticIntentIndexes() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "im-v2-pending-intent-indexes-\(UUID().uuidString).sqlite")
        _ = try GRDBV2LocalSyncStore(
            databaseURL: url,
            installationBinding: .init(value: UUID(uuidString: "00000000-0000-0000-0000-000000000990")!)
        )
        let database = try DatabasePool(path: url.path)
        let actual = try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name IN ('v2_operation_work_intent','v2_operation_work_order')"
            )
        }
        #expect(Set(actual) == [
            "v2_operation_work_intent",
            "v2_operation_work_order"
        ])
    }

    @Test("the local-store migration indexes terminal command expiry")
    func createsTerminalRetentionIndexes() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "im-v2-terminal-retention-indexes-\(UUID().uuidString).sqlite")
        _ = try GRDBV2LocalSyncStore(
            databaseURL: url,
            installationBinding: .init(value: UUID(uuidString: "00000000-0000-0000-0000-000000000996")!)
        )
        let database = try DatabasePool(path: url.path)
        let actual = try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'v2_operation_work_retention'"
            )
        }
        #expect(Set(actual) == [
            "v2_operation_work_retention",
        ])
    }
}

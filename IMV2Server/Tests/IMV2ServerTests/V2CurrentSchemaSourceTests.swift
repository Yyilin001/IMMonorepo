import Foundation
import Testing

@Suite("V2 current schema source")
struct V2CurrentSchemaSourceTests {
    @Test("the unreleased server ships a current schema without historical upgrade SQL")
    func currentSchemaWithoutUpgradeChain() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let files = FileManager.default
        #expect(files.fileExists(atPath: repository.appending(path: "IMV2/sql/schema.sql").path))
        let rootSQLFiles = try files.contentsOfDirectory(atPath: repository.appending(path: "IMV2/sql").path)
        #expect(rootSQLFiles.filter { $0.hasPrefix("migrate-") && $0.hasSuffix(".sql") }.isEmpty)
        let schema = try String(contentsOf: repository.appending(path: "IMV2/sql/schema.sql"), encoding: .utf8)
        #expect(!schema.contains("CREATE TABLE im_v2.message_operation_closures"))
        #expect(!schema.contains("CREATE TABLE im_v2.direct_message_denials"))
        let journal = try String(contentsOf: repository.appending(path: "IMV2/sql/realtime-change-journal.sql"), encoding: .utf8)
        #expect(!journal.contains("ADD COLUMN IF NOT EXISTS"))
        for directory in ["IMV2/sql/migrations", "IMV2/sql/changes"] {
            let url = repository.appending(path: directory)
            guard files.fileExists(atPath: url.path) else { continue }
            let sqlFiles = try files.contentsOfDirectory(atPath: url.path)
                .filter { $0.hasSuffix(".sql") }
            #expect(sqlFiles.isEmpty, "Historical schema upgrades are outside the current contract: \(sqlFiles)")
        }
    }
}

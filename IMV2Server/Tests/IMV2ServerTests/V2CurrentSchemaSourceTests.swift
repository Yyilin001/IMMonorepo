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
        for directory in ["IMV2/sql/migrations", "IMV2/sql/changes"] {
            let url = repository.appending(path: directory)
            guard files.fileExists(atPath: url.path) else { continue }
            let sqlFiles = try files.contentsOfDirectory(atPath: url.path)
                .filter { $0.hasSuffix(".sql") }
            #expect(sqlFiles.isEmpty, "Historical schema upgrades are outside the current contract: \(sqlFiles)")
        }
    }
}

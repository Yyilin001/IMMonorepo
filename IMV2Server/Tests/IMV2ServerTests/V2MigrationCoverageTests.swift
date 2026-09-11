import Foundation
import Testing

/// 迁移目录与迁移链测试之间的覆盖门禁。
///
/// 迁移链用例按场景**手工挑选并排序**文件（有些用例只需要与其场景相关的一小段），
/// 因此不能简单地"按目录自动展开"。代价是：新增迁移文件时很容易忘记把它接进任何一条
/// 链，症状要到真实数据库套件的 readiness 校验才暴露（本项目已经发生过两次）。
///
/// 这条门禁把该遗漏提前成一次廉价的静态失败：目录里的每个 `.sql` 都必须在测试源码里
/// 至少被引用一次。它不检查"引用得对不对"（那由迁移链用例本身验证），只保证新文件不会
/// 悄无声息地游离在所有迁移链之外。
@Suite("V2 migration coverage")
struct V2MigrationCoverageTests {
    @Test("every migration file is referenced by at least one migration chain")
    func everyMigrationFileIsExercised() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let migrationsDirectory = repositoryRoot.appending(path: "IMV2/sql/migrations")
        let migrations = try FileManager.default
            .contentsOfDirectory(atPath: migrationsDirectory.path)
            .filter { $0.hasSuffix(".sql") }
            .sorted()
        #expect(!migrations.isEmpty)

        let testsRoot = repositoryRoot.appending(path: "IMV2Server/Tests")
        var sources = ""
        if let enumerator = FileManager.default.enumerator(
            at: testsRoot,
            includingPropertiesForKeys: nil
        ) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                // 本文件本身只描述规则，引用文件名不算"接进迁移链"。
                guard url.lastPathComponent != testFile.lastPathComponent else { continue }
                sources += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }

        let unreferenced = migrations.filter { !sources.contains($0) }
        // 两条早期迁移刻意不接进任何链：它们创建的对象在迁移链夹具的起始形态里已经存在
        // （链夹具从 canonical schema 出发、只回退合同号），重复应用会与外键/建表冲突。
        // 它们的结构由 canonical schema 与漂移门禁覆盖，因此在这里显式豁免而不是遗忘。
        let legacyExcluded: Set<String> = [
            "20260819_direct_send_policy_cache.sql",
            "20260903_group_invitations.sql",
        ]
        let missing = unreferenced.filter { !legacyExcluded.contains($0) }
        #expect(
            missing.isEmpty,
            "这些迁移文件没有被任何迁移链用例引用，新增迁移必须接进对应链路：\(missing)"
        )
        #expect(
            Set(unreferenced).isSubset(of: legacyExcluded),
            "豁免名单只允许包含上述早期迁移；若新迁移被加进豁免，请先说明它为什么无法进链"
        )
    }
}

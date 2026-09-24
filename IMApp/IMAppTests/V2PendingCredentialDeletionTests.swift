import Foundation
import Testing
@testable import IMApp

struct V2PendingCredentialDeletionTests {
    @Test("退出记录跨实例恢复，完成后不再报告待删除")
    func persistsAndClearsDeletionIntent() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.cleanup() }
        let first = fixture.store()
        #expect(try await first.isPending() == false)
        try await first.markPending()
        let restored = fixture.store()
        #expect(try await restored.isPending())
        try await restored.clearPending()
        #expect(try await first.isPending() == false)
        #expect(try await fixture.store().isPending() == false)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url)) as? [String: Any])
        #expect(Set(object.keys) == ["version", "pending"])
        #expect(try fixture.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        // iOS simulator accepts protection writes but does not expose the
        // attribute. The actual protection assertion requires a device.
        #if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.url.path)
        let protection = (attributes[.protectionKey] as? FileProtectionType)
            ?? (attributes[.protectionKey] as? String).map(FileProtectionType.init(rawValue:))
        #expect(protection == .complete)
        #endif
    }

    @Test("损坏或未知版本不能被当作没有退出意图", arguments: ["broken", "{\"version\":2,\"pending\":false}"])
    func invalidRecordsFailClosed(contents: String) async throws {
        let fixture = try DeletionFixture()
        defer { fixture.cleanup() }
        try Data(contents.utf8).write(to: fixture.url)
        await #expect(throws: V2PendingCredentialDeletionError.self) { _ = try await fixture.store().isPending() }
    }

    @Test("完成记录写入失败向调用方报告，不伪造完成")
    func failedClearRemainsAnError() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await fixture.store().clearPending() }
        await #expect(throws: (any Error).self) { _ = try await fixture.store().isPending() }
    }

    @Test("不同存储域的退出记录互不影响")
    func markerScopeIsIsolated() async throws {
        let a = try DeletionFixture(), b = try DeletionFixture()
        defer { a.cleanup(); b.cleanup() }
        try await a.store().markPending()
        #expect(try await b.store().isPending() == false)
        try await b.store().clearPending()
        #expect(try await a.store().isPending())
    }

    @Test("同一数据库路径的不同 Keychain service 不共享退出记录")
    func keychainServicesHaveIndependentFiles() {
        let database = URL(fileURLWithPath: "/fixture/sync.sqlite")
        let a = V2FilePendingCredentialDeletionStore.fileURL(databaseURL: database, serviceIdentifier: "service-a")
        let b = V2FilePendingCredentialDeletionStore.fileURL(databaseURL: database, serviceIdentifier: "service-b")
        #expect(a != b)
        #expect(a == V2FilePendingCredentialDeletionStore.fileURL(databaseURL: database, serviceIdentifier: "service-a"))
        #expect(a.deletingLastPathComponent() == database.deletingLastPathComponent())
        #expect(!a.lastPathComponent.contains("service-a"))
    }
}

private struct DeletionFixture {
    let root: URL
    let url: URL
    init() throws {
        let id = UUID().uuidString
        root = FileManager.default.temporaryDirectory.appending(path: "im-deletion-marker-" + id)
        url = root.appending(path: "marker.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func store() -> V2FilePendingCredentialDeletionStore {
        .init(url: url)
    }
    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

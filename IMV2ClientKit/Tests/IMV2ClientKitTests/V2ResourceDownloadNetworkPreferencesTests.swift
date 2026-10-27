import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

struct V2ResourceDownloadNetworkPreferencesTests {
    @Test func databaseReopenPreservesPreferencesWithoutSharingThemWithAnotherAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "download-network-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = UserID(uuid: UUID()), binding = V2LocalInstallationBinding(value: UUID())
        let database = root.appending(path: "account.sqlite")
        let first = try GRDBV2LocalSyncStore(databaseURL: database, installationBinding: binding, userID: account)
        let expected = try V2ResourceDownloadNetworkPreferences(allowsCellular: false, allowsConstrained: true,
            automaticDownloads: .init(categories: [.video, .audio, .file], maximumByteCount: 1024))
        try await first.resourceFileJournal().setDownloadNetworkPreferences(expected)
        try await first.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: database, installationBinding: binding, userID: account)
        #expect(try await reopened.resourceFileJournal().downloadNetworkPreferences() == expected)
        let other = try GRDBV2LocalSyncStore(databaseURL: root.appending(path: "other.sqlite"),
            installationBinding: .init(value: UUID()), userID: .init(uuid: UUID()))
        #expect(try await other.resourceFileJournal().downloadNetworkPreferences() == .init())
        try await reopened.close(); try await other.close()
    }
}

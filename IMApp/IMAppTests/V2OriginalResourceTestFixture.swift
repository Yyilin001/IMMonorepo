import Foundation
import IMV2Core
@testable import IMV2ClientKit
@testable import IMApp

// Test doubles that exercise presentation or command behavior do not acquire
// filesystem access. Original-lifetime tests use the real fixture below.
extension V2ConversationAttachmentStaging {
    func stageNormalizedPhoto(_ photo: V2NormalizedPhoto, purpose: V2LocalResourceAssetPurpose) async throws -> V2StagedConversationAttachment { throw V2ResourceStorageError.unavailable }
    func selectedAttachments(purpose: V2LocalResourceAssetPurpose) async throws -> [V2StagedConversationAttachment] { [] }
    func borrow(_ context: V2LocalResourceReadContext) async throws -> V2ResourceFileLease { throw V2ResourceStorageError.unavailable }
}

@MainActor
struct V2OriginalResourceTestFixture {
    let scope: V2AccountStorageScope
    let store: GRDBV2LocalSyncStore
    let resources: V2ResourceCenter
    let stager: V2FileConversationAttachmentStager
    static let binding = V2LocalInstallationBinding(value: UUID(uuidString: "183501E1-2C63-481A-BFE6-E31341446A75")!)
    init(root: URL, scope: V2AccountStorageScope? = nil,
         policy: V2ConversationAttachmentStagingPolicy = .standard, byteBudget: Int64 = 512 * 1_024 * 1_024,
         protection: any V2ResourceFileProtectionWriting = V2SystemResourceFileProtectionWriter()) async throws {
        self.scope = scope ?? .init(incarnation: UUID(), accountID: .init(uuid: UUID()), directory: root, cacheDirectory: root.appending(path: "cache-scope"))
        store = try .init(databaseURL: self.scope.database.primary, installationBinding: Self.binding, userID: self.scope.accountID)
        resources = try await .make(scope: self.scope, store: store, policy: .testBounded(byteBudget), protection: protection)
        stager = .init(resources: resources, policy: policy)
    }
    func read(_ context: V2LocalResourceReadContext) async throws -> Data {
        let lease = try await stager.borrow(context)
        do { let data = try Data(contentsOf: lease.fileURL); await lease.release(); return data }
        catch { await lease.release(); throw error }
    }
    func close() async throws {
        await stager.close(); await resources.close(); try await store.close()
    }
}

@MainActor
func makeAppResourceTestCenter(store: GRDBV2LocalSyncStore, root: URL) async throws -> V2ResourceCenter {
    let user = try await store.resourceFileJournal().accountID()
    return try await .make(scope: .init(incarnation: UUID(), accountID: user, directory: root, cacheDirectory: root.appending(path: "cache-scope")), store: store)
}

import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2PublicIdentitySettingsStoreTests {
    @Test("显示名保存忽略取消后的迟到成功")
    func saveIgnoresLateSuccessAfterCancellation() async throws {
        let manager = V2LateProfileManager()
        let store = try V2PublicIdentitySettingsStore(manager: manager)
        store.displayName = "本地草稿"

        let save = Task { await store.save() }
        await manager.waitUntilUpdateIsPending()
        save.cancel()
        try await manager.resumeWithRemoteProfile()
        await save.value

        #expect(store.displayName == "本地草稿")
        #expect(store.handle.isEmpty)
        #expect(!store.isSaving)
        #expect(store.feedback == nil)
    }
}

private actor V2LateProfileManager: V2PublicIdentityProfileManaging {
    private var responseWaiter: CheckedContinuation<V2PublicIdentity, Never>?
    private var responseReadyWaiter: CheckedContinuation<Void, Never>?

    func currentProfile() async throws -> V2PublicIdentity {
        try profile(displayName: "当前显示名")
    }

    func updateDisplayName(_: String) async throws -> V2PublicIdentity {
        await withCheckedContinuation { continuation in
            responseWaiter = continuation
            responseReadyWaiter?.resume()
            responseReadyWaiter = nil
        }
    }

    func waitUntilUpdateIsPending() async {
        guard responseWaiter == nil else { return }
        await withCheckedContinuation { responseReadyWaiter = $0 }
    }

    func resumeWithRemoteProfile() throws {
        guard let responseWaiter else { return }
        self.responseWaiter = nil
        responseWaiter.resume(returning: try profile(displayName: "远端迟到结果"))
    }

    private func profile(displayName: String) throws -> V2PublicIdentity {
        try .init(
            userID: .init("00000000-0000-0000-0000-000000000515"),
            handle: .init("profile_test"),
            displayName: displayName
        )
    }
}

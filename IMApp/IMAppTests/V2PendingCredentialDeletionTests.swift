import Foundation
import Testing
@testable import IMApp

struct V2PendingCredentialDeletionTests {
    @Test("退出意图只保存非敏感删除标记，并可跨存储实例完成")
    func persistsAndClearsDeletionIntent() async {
        let key = "V2PendingCredentialDeletionTests." + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let firstStore = V2UserDefaultsPendingCredentialDeletionStore(key: key)

        #expect(await firstStore.isPending() == false)
        await firstStore.markPending()

        let restoredStore = V2UserDefaultsPendingCredentialDeletionStore(key: key)
        #expect(await restoredStore.isPending())

        await restoredStore.clearPending()
        #expect(await firstStore.isPending() == false)
    }
}

import Testing
import IMV2Core
@testable import IMApp

struct V2LiveLocalAccountE2ETestScopeTests {
    @Test("本地账号 E2E 存储域与常规 Keychain 隔离")
    func derivesIsolatedDeviceAndStorageNames() throws {
        let rawID = "00000000-0000-0000-0000-000000000901"
        let scope = try #require(V2LiveLocalAccountE2ETestScope(rawValue: rawID))

        #expect(scope.deviceID.rawValue == rawID)
        #expect(scope.keychainService(basedOn: "com.example.app.v2") == "com.example.app.v2.local-e2e.\(rawID)")
        #expect(scope.databaseFileName == "sync-local-e2e-\(rawID).sqlite")
    }

    @Test("本地账号 E2E 存储域拒绝无效设备 ID")
    func rejectsInvalidDeviceID() {
        #expect(V2LiveLocalAccountE2ETestScope(rawValue: "not-a-uuid") == nil)
    }
}

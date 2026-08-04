import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2DeviceSessionsStoreTests {
    @Test("remote revoke removes only the selected non-current session")
    func revokesRemoteSession() async throws {
        let current = try DeviceID("00000000-0000-0000-0000-000000000601")
        let remote = try DeviceID("00000000-0000-0000-0000-000000000602")
        let manager = DeviceSessionStoreManager(sessions: [
            .init(deviceID: current, deviceName: "iPhone", platform: "iPhone", createdAt: .distantPast, lastActiveAt: .distantFuture, isCurrentDevice: true),
            .init(deviceID: remote, deviceName: "iPad", platform: "iPad", createdAt: .distantPast, lastActiveAt: .distantPast, isCurrentDevice: false)
        ])
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000603")!
        let store = V2DeviceSessionsStore(manager: manager, makeUUID: { operationID })

        await store.refresh()
        await store.revoke(try #require(store.sessions.first { $0.deviceID == remote }))

        #expect(store.sessions.map(\.deviceID) == [current])
        #expect(store.feedback == "已退出该设备。")
        let call = try #require(await manager.revokeCall())
        #expect(call.deviceID == remote)
        #expect(call.operationID == operationID)
    }

    @Test("already-removed device is treated as successful revoke")
    func unavailableSessionIsIdempotentForUI() async throws {
        let remote = try DeviceID("00000000-0000-0000-0000-000000000612")
        let manager = DeviceSessionStoreManager(sessions: [
            .init(deviceID: remote, deviceName: "iPad", platform: "iPad", createdAt: .distantPast, lastActiveAt: .distantPast, isCurrentDevice: false)
        ], revokeError: .sessionUnavailable)
        let store = V2DeviceSessionsStore(manager: manager)
        await store.refresh()
        await store.revoke(try #require(store.sessions.first))
        #expect(store.sessions.isEmpty)
        #expect(store.feedback == "该设备已退出。")
    }
}

private actor DeviceSessionStoreManager: V2ClientDeviceSessionManaging {
    struct RevokeCall: Sendable { let deviceID: DeviceID; let operationID: UUID }
    let storedSessions: [V2ClientDeviceSession]
    let revokeError: V2ClientDeviceSessionError?
    private var recorded: RevokeCall?
    init(sessions: [V2ClientDeviceSession], revokeError: V2ClientDeviceSessionError? = nil) {
        storedSessions = sessions; self.revokeError = revokeError
    }
    func list() -> [V2ClientDeviceSession] { storedSessions }
    func revoke(deviceID: DeviceID, operationID: UUID) throws {
        if let revokeError { throw revokeError }
        recorded = .init(deviceID: deviceID, operationID: operationID)
    }
    func revokeOtherDevices(operationID _: UUID) {}
    func revokeCall() -> RevokeCall? { recorded }
}

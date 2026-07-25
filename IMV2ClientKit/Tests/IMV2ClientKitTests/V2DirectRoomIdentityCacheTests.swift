import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 direct room identity cache")
struct V2DirectRoomIdentityCacheTests {
    @Test("an explicitly resolved direct identity survives a local-store restart and refreshes in place")
    func persistsResolvedIdentity() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-direct-identity-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000d01")!)
        let roomID: RoomID = try .init("00000000-0000-0000-0000-000000000d02")
        let identity = try V2PublicIdentity(
            userID: .init("00000000-0000-0000-0000-000000000d03"),
            handle: .init("direct_user"),
            displayName: "初始名称"
        )
        let first = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        try await first.cacheDirectRoomIdentity(roomID: roomID, publicIdentity: identity, updatedAt: Date(timeIntervalSince1970: 1_750_000_000))

        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        #expect(try await restarted.directRoomIdentities() == [.init(roomID: roomID, publicIdentity: identity, updatedAt: Date(timeIntervalSince1970: 1_750_000_000))])

        let refreshed = try V2PublicIdentity(userID: identity.userID, handle: identity.handle, displayName: "更新名称")
        try await restarted.cacheDirectRoomIdentity(roomID: roomID, publicIdentity: refreshed, updatedAt: Date(timeIntervalSince1970: 1_750_000_100))
        #expect(try await restarted.directRoomIdentities().first?.publicIdentity.displayName == "更新名称")
    }
}

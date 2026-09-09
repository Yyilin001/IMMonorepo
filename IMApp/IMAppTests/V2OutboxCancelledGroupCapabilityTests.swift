import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2OutboxCancelledGroupCapabilityTests {
    @Test("cancelled group settings do not enqueue or send", arguments: ["pin", "announcement", "role", "policy"])
    func cancelledSetting(kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-app-cancelled-group-setting-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        do {
            let now = Date(timeIntervalSince1970: 1_000)
            let outbox = V2GroupCapabilitiesOutboxEngine(store: store, transport: UnexpectedGroupSettingTransport(), now: { now })
            let pinner = V2OutboxGroupMessagePinner(outbox: outbox)
            let announcement = V2OutboxGroupAnnouncementManager(outbox: outbox)
            let role = V2OutboxGroupMemberRoleChanger(outbox: outbox)
            let policy = V2OutboxGroupRolePolicyChanger(outbox: outbox)
            let room = RoomID(uuid: UUID())
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                switch kind {
                case "pin": return try await pinner.setPinned(roomID: room.rawValue, messageID: MessageID(uuid: UUID()).rawValue, isPinned: true)
                case "announcement": return try await announcement.setAnnouncement(roomID: room.rawValue, body: "new announcement", expectedRevision: 1)
                case "role": return try await role.setRole(roomID: room.rawValue, userID: UserID(uuid: UUID()).rawValue, role: .admin, expectedMembershipRevision: 1)
                default: return try await policy.setPolicy(roomID: room.rawValue, role: .member, permissions: [.sendMessages], expectedRevision: 1)
                }
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.nextReadyGroupCapability(now: now) == nil)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }
}

private struct UnexpectedGroupSettingTransport: V2ClientGroupCapabilitiesTransport {
    func setPinnedMessage(command: V2PinnedMessageCommand) async throws -> V2PinnedMessage {
        Issue.record("cancelled pin must not reach transport")
        throw CancellationError()
    }
    func setGroupAnnouncement(command: V2GroupAnnouncementCommand) async throws -> V2GroupAnnouncement {
        Issue.record("cancelled announcement must not reach transport")
        throw CancellationError()
    }
    func setGroupRolePermissions(command: V2GroupRolePermissionsCommand) async throws -> V2GroupRolePermissionsChange {
        Issue.record("cancelled policy must not reach transport")
        throw CancellationError()
    }
    func changeGroupMemberRole(command: V2GroupMemberRoleCommand) async throws -> V2GroupMemberRoleChange {
        Issue.record("cancelled role change must not reach transport")
        throw CancellationError()
    }
}

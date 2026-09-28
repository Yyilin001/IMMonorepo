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
        let account=UserID(uuid:UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()),userID:account)
        do {
            let now = Date(timeIntervalSince1970: 1_000)
            let service=V2GroupCapabilityOperationService(accountID:account,activationID:UUID(),store:store,client:UnexpectedGroupSettingTransport())
            let pinner = V2OperationGroupMessagePinner(service: service)
            let announcement = V2OperationGroupAnnouncementManager(service: service)
            let role = V2OperationGroupMemberRoleChanger(service: service)
            let policy = V2OperationGroupRolePolicyChanger(service: service)
            let room = RoomID(uuid: UUID())
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                switch kind {
                case "pin": return try await pinner.setPinned(roomID: room.rawValue, messageID: MessageID(uuid: UUID()).rawValue, isPinned: true, expectedRoomSequence: 1)
                case "announcement": return try await announcement.setAnnouncement(roomID: room.rawValue, body: "new announcement", expectedRevision: 1)
                case "role": return try await role.setRole(roomID: room.rawValue, userID: UserID(uuid: UUID()).rawValue, role: .admin, expectedMembershipRevision: 1)
                default: return try await policy.setPolicy(roomID: room.rawValue, role: .member, permissions: [.sendMessages], expectedRevision: 1)
                }
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.beginGroupCapabilityPreparation(now: now) == nil)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }
}

private struct UnexpectedGroupSettingTransport:V2GroupCapabilityOperationClient {
    func pinBaseline(roomID:RoomID,messageID:MessageID) async throws -> V2PinnedMessageBaseline { throw CancellationError() }
    func admit(_ intent:V2GroupCapabilityIntent) async throws -> V2GroupCapabilityAdmissionResult { Issue.record("cancelled action reached admission");throw CancellationError() }
    func submit(_ command:V2GroupCapabilityCommand) async throws -> V2GroupCapabilityRecoveryResult { Issue.record("cancelled action reached submit");throw CancellationError() }
    func recover(_ command:V2GroupCapabilityCommand,action:V2OperationRecoveryRequest.Action) async throws -> V2GroupCapabilityRecoveryResult { throw CancellationError() }
}

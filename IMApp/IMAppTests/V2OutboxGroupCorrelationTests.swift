import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2OutboxGroupCorrelationTests {
    @Test("cancelled group operations do not create durable commands", arguments: ["membership", "mute", "removal"])
    func cancelledGroupOperation(kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-app-cancelled-group-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        do {
            let room = RoomID(uuid: UUID())
            let target = UserID(uuid: UUID())
            let transport = GroupTransport(rejectedTarget: nil)
            let reason = try V2ModerationReasonCode("abuse_spam")
            let membership = V2OutboxGroupMembershipChanger(outbox: .init(store: store, transport: transport))
            let mute = V2OutboxGroupMemberMuter(outbox: .init(store: store, transport: transport))
            let removal = V2OutboxModeratedGroupMemberRemover(outbox: .init(store: store, transport: transport))
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                switch kind {
                case "membership": _ = try await membership.changeMembership(roomID: room.rawValue, targetUserID: target.rawValue, action: .add, expectedMembershipRevision: 1)
                case "mute": _ = try await mute.muteMember(roomID: room.rawValue, targetUserID: target.rawValue, muteUntil: Date().addingTimeInterval(60), reasonCode: reason)
                default: _ = try await removal.removeMemberByModerator(roomID: room.rawValue, targetUserID: target.rawValue, reasonCode: reason)
                }
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.pendingMembershipCommands().isEmpty)
            #expect(try await store.pendingMemberMutes().isEmpty)
            #expect(try await store.pendingModeratedMemberRemovals().isEmpty)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("group operation feedback is correlated with its durable command", arguments: ["membership", "mute", "removal"], [false, true])
    func groupCorrelation(kind: String, rejectOld: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-app-group-correlation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        do {
            let room = RoomID(uuid: UUID())
            let oldTarget = UserID(uuid: UUID())
            let target = UserID(uuid: UUID())
            let transport = GroupTransport(rejectedTarget: rejectOld ? oldTarget : nil)
            let reason = try V2ModerationReasonCode("abuse_spam")
            let expiry = Date(timeIntervalSince1970: 2_000)
            switch kind {
            case "membership":
                let old = V2MembershipCommandOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 999) })
                let older = try await old.enqueueMembershipChange(roomID: room, targetUserID: oldTarget, action: .add, expectedMembershipRevision: 1)
                let outbox = V2MembershipCommandOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_000) })
                let adapter = V2OutboxGroupMembershipChanger(outbox: outbox)
                #expect(try await adapter.changeMembership(roomID: room.rawValue, targetUserID: target.rawValue, action: .add, expectedMembershipRevision: 1) == .queuedForRetry)
                let commands = try await store.pendingMembershipCommands()
                let current = try #require(commands.first { $0.targetUserID == target })
                #expect(current.state == .pending)
                #expect(commands.first { $0.operationID == older.operationID }?.state == (rejectOld ? .rejected : .acknowledged))
                #expect(try await outbox.flushOnce() == .acknowledged(current.operationID))
                #expect(try await store.pendingMembershipCommands().first { $0.operationID == current.operationID }?.state == .acknowledged)
            case "mute":
                let old = V2MemberMuteOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 999) })
                let older = try await old.enqueueMute(roomID: room, targetUserID: oldTarget, muteUntil: expiry, reasonCode: reason)
                let outbox = V2MemberMuteOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_000) })
                let adapter = V2OutboxGroupMemberMuter(outbox: outbox)
                #expect(try await adapter.muteMember(roomID: room.rawValue, targetUserID: target.rawValue, muteUntil: expiry, reasonCode: reason) == .queuedForRetry)
                let commands = try await store.pendingMemberMutes()
                let current = try #require(commands.first { $0.targetUserID == target })
                #expect(current.state == .pending)
                #expect(commands.first { $0.operationID == older.operationID }?.state == (rejectOld ? .rejected : .acknowledged))
                #expect(try await outbox.flushOnce() == .acknowledged(current.operationID))
                #expect(try await store.pendingMemberMutes().first { $0.operationID == current.operationID }?.state == .acknowledged)
            default:
                let old = V2ModeratedMemberRemovalOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 999) })
                let older = try await old.enqueueRemoval(roomID: room, targetUserID: oldTarget, reasonCode: reason)
                let outbox = V2ModeratedMemberRemovalOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_000) })
                let adapter = V2OutboxModeratedGroupMemberRemover(outbox: outbox)
                #expect(try await adapter.removeMemberByModerator(roomID: room.rawValue, targetUserID: target.rawValue, reasonCode: reason) == .queuedForRetry)
                let commands = try await store.pendingModeratedMemberRemovals()
                let current = try #require(commands.first { $0.targetUserID == target })
                #expect(current.state == .pending)
                #expect(commands.first { $0.operationID == older.operationID }?.state == (rejectOld ? .rejected : .acknowledged))
                #expect(try await outbox.flushOnce() == .acknowledged(current.operationID))
                #expect(try await store.pendingModeratedMemberRemovals().first { $0.operationID == current.operationID }?.state == .acknowledged)
            }
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }
}

private struct GroupTransport: V2ClientMembershipTransport, V2ClientMemberMuteTransport, V2ClientModeratedMemberRemovalTransport {
    let rejectedTarget: UserID?
    private func check(_ target: UserID) throws {
        if target == rejectedTarget {
            throw V2RealtimeTransportError.server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: 0, currentRevision: nil)
        }
    }
    func changeMembership(roomID: RoomID, operationID: MembershipOperationID, targetUserID: UserID, action: V2RoomMembershipAction, expectedMembershipRevision: UInt64) async throws -> V2ClientMembershipChange {
        try check(targetUserID)
        return try .init(roomID: roomID, targetUserID: targetUserID, action: action, membershipRevision: 2, roomSequence: 1, createdAt: Date(timeIntervalSince1970: 1_000))
    }
    func muteMember(roomID: RoomID, operationID: ModerationOperationID, targetUserID: UserID, muteUntil: Date, reasonCode: V2ModerationReasonCode) async throws -> V2ClientMemberMute {
        try check(targetUserID)
        return try .init(roomID: roomID, targetUserID: targetUserID, muteUntil: muteUntil, roomSequence: 1, createdAt: Date(timeIntervalSince1970: 1_000))
    }
    func removeMemberByModerator(roomID: RoomID, operationID: ModerationOperationID, targetUserID: UserID, reasonCode: V2ModerationReasonCode) async throws -> V2ClientModeratedMemberRemoval {
        try check(targetUserID)
        return try .init(roomID: roomID, targetUserID: targetUserID, membershipRevision: 2, roomSequence: 1, createdAt: Date(timeIntervalSince1970: 1_000))
    }
}

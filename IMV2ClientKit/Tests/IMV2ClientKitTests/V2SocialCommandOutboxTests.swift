import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 social command outbox")
struct V2SocialCommandOutboxTests {
    @Test("relationship block and preference intents survive restart and dispatch once")
    func persistsAndDispatchesAllSocialCommandKinds() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-social-outbox-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(atPath: url.path + "-wal"); try? FileManager.default.removeItem(atPath: url.path + "-shm") }
        let binding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000361")!)
        let firstStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let transport = SocialOutboxTransport()
        let target = try UserID("00000000-0000-0000-0000-000000000362")
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let engine = V2SocialCommandOutboxEngine(store: firstStore, socialTransport: transport, directTransport: transport, now: { now })
        let relationship = try await engine.enqueueRelationship(targetUserID: target, action: V2RelationshipAction.request)
        #expect(relationship.kind == .relationship)
        let block = try await engine.enqueueUserBlock(targetUserID: target, action: V2UserBlockAction.block)
        #expect(block.kind == .userBlock)
        let preference = try await engine.enqueueStrangerMessagePermission(V2StrangerMessagePermission.deny)
        #expect(preference.kind == .strangerMessagePreference)
        #expect(try await firstStore.pendingSocialCommands().count == 3)

        let restartedStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let restartedEngine = V2SocialCommandOutboxEngine(store: restartedStore, socialTransport: transport, directTransport: transport, now: { now })
        for _ in 0..<3 {
            guard case .acknowledged = try await restartedEngine.flushOnce() else { Issue.record("expected acknowledgement"); return }
        }
        #expect(try await restartedStore.pendingSocialCommands().allSatisfy { $0.state == V2PendingSocialCommand.State.acknowledged })
        #expect((await transport.dispatchedKinds()).map(\.rawValue).sorted() == ["relationship", "strangerMessagePreference", "userBlock"])
    }

    @Test("重启后相同待隐私意图复用原操作而新目标状态保留顺序")
    func duplicatePendingPrivacyIntentReusesOnlyTheEquivalentOperation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "im-v2-social-reuse-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let firstStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let firstOperation = UUID(uuidString: "00000000-0000-0000-0000-000000000363")!
        let transport = SocialOutboxTransport()
        let firstEngine = V2SocialCommandOutboxEngine(
            store: firstStore,
            socialTransport: transport,
            directTransport: transport,
            makeUUID: { firstOperation }
        )

        let original = try await firstEngine.enqueueStrangerMessagePermission(.deny)
        let restartedStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let restartedEngine = V2SocialCommandOutboxEngine(
            store: restartedStore,
            socialTransport: transport,
            directTransport: transport
        )
        let reused = try await restartedEngine.enqueueStrangerMessagePermission(.deny)
        let changed = try await restartedEngine.enqueueStrangerMessagePermission(.allow)

        #expect(reused.operationID == original.operationID)
        #expect(changed.operationID != original.operationID)
        let pending = try await restartedStore.pendingSocialCommands()
        #expect(pending.count == 2)
        #expect(pending.map(\.strangerPermission) == [.deny, .allow])
    }

    @Test("explicit flush never reports an older queued command as the current action")
    func flushIfReadyLeavesAnEarlierCommandUntouched() async throws {
        let target = try UserID("00000000-0000-0000-0000-000000000372")
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let earlierID = "00000000-0000-0000-0000-000000000370"
        let requestedID = UUID(uuidString: "00000000-0000-0000-0000-000000000371")!
        let earlier = try V2PendingSocialCommand(
            operationID: earlierID,
            kind: .strangerMessagePreference,
            targetUserID: nil,
            relationshipAction: nil,
            blockAction: nil,
            strangerPermission: .deny,
            state: .pending,
            attemptCount: 0,
            nextAttemptAt: now,
            terminalCode: nil
        )
        let store = SocialOutboxStoreSpy(commands: [earlier])
        let transport = SocialOutboxTransport()
        let engine = V2SocialCommandOutboxEngine(
            store: store,
            socialTransport: transport,
            directTransport: transport,
            makeUUID: { requestedID },
            now: { now }
        )

        let requested = try await engine.enqueueRelationship(targetUserID: target, action: .request)
        let result = try await engine.flushIfReady(operationID: requested.operationID)

        #expect(result == nil)
        #expect(await transport.dispatchedKinds().isEmpty)
        #expect(await store.command(operationID: earlierID)?.state == .pending)
        #expect(await store.command(operationID: requested.operationID)?.state == .pending)
    }
}

private actor SocialOutboxStoreSpy: V2LocalSocialCommandStore {
    private var commands: [V2PendingSocialCommand]

    init(commands: [V2PendingSocialCommand]) {
        self.commands = commands
    }

    func enqueue(_ command: V2PendingSocialCommand) async throws {
        commands.append(command)
    }

    func enqueueOrReusePendingSocialCommand(_ command: V2PendingSocialCommand) async throws -> V2PendingSocialCommand {
        if let existing = commands.first(where: {
            $0.kind == command.kind
                && $0.targetUserID == command.targetUserID
                && $0.relationshipAction == command.relationshipAction
                && $0.blockAction == command.blockAction
                && $0.strangerPermission == command.strangerPermission
                && $0.state == .pending
        }) {
            return existing
        }
        commands.append(command)
        return command
    }

    func nextReadySocialCommand(now: Date) async throws -> V2PendingSocialCommand? {
        commands.first { $0.state == .pending && $0.nextAttemptAt <= now }
    }

    func markSocialCommandAcknowledged(operationID: String) async throws {
        try replace(operationID: operationID) { command in
            try V2PendingSocialCommand(
                operationID: command.operationID,
                kind: command.kind,
                targetUserID: command.targetUserID,
                relationshipAction: command.relationshipAction,
                blockAction: command.blockAction,
                strangerPermission: command.strangerPermission,
                state: .acknowledged,
                attemptCount: command.attemptCount,
                nextAttemptAt: command.nextAttemptAt,
                terminalCode: nil
            )
        }
    }

    func scheduleSocialCommandRetry(operationID: String, nextAttemptAt: Date) async throws {
        try replace(operationID: operationID) { command in
            try V2PendingSocialCommand(
                operationID: command.operationID,
                kind: command.kind,
                targetUserID: command.targetUserID,
                relationshipAction: command.relationshipAction,
                blockAction: command.blockAction,
                strangerPermission: command.strangerPermission,
                state: .pending,
                attemptCount: command.attemptCount + 1,
                nextAttemptAt: nextAttemptAt,
                terminalCode: nil
            )
        }
    }

    func rejectSocialCommand(operationID: String, code: String) async throws {
        try replace(operationID: operationID) { command in
            try V2PendingSocialCommand(
                operationID: command.operationID,
                kind: command.kind,
                targetUserID: command.targetUserID,
                relationshipAction: command.relationshipAction,
                blockAction: command.blockAction,
                strangerPermission: command.strangerPermission,
                state: .rejected,
                attemptCount: command.attemptCount,
                nextAttemptAt: command.nextAttemptAt,
                terminalCode: code
            )
        }
    }

    func command(operationID: String) -> V2PendingSocialCommand? {
        commands.first { $0.operationID == operationID }
    }

    private func replace(
        operationID: String,
        transform: (V2PendingSocialCommand) throws -> V2PendingSocialCommand
    ) throws {
        guard let index = commands.firstIndex(where: { $0.operationID == operationID }) else {
            throw V2ClientCommandError.commandNotPending
        }
        commands[index] = try transform(commands[index])
    }
}

private actor SocialOutboxTransport: V2ClientSocialRelationshipTransport, V2ClientDirectMessagingTransport {
    private var kinds: [V2PendingSocialCommandKind] = []
    func changeRelationship(operationID _: RelationshipOperationID, targetUserID: UserID, action: V2RelationshipAction) -> V2ClientRelationshipChange {
        kinds.append(.relationship)
        return .init(targetUserID: targetUserID, action: action, resultingState: .pending, updatedAt: .distantFuture)
    }
    func changeUserBlock(operationID _: UserBlockOperationID, targetUserID: UserID, action: V2UserBlockAction) -> V2ClientUserBlockChange {
        kinds.append(.userBlock)
        return .init(targetUserID: targetUserID, action: action, isBlocked: action == .block, updatedAt: .distantFuture)
    }
    func openDirectRoom(operationID _: DirectRoomOperationID, targetUserID _: UserID) throws -> V2ClientDirectRoom { throw V2RealtimeTransportError.unexpectedResponse }
    func setStrangerMessagePermission(operationID _: StrangerMessagePreferenceOperationID, permission _: V2StrangerMessagePermission) -> Date { kinds.append(.strangerMessagePreference); return .distantFuture }
    func dispatchedKinds() -> [V2PendingSocialCommandKind] { kinds }
}

#if DEBUG
import Foundation
import IMV2ClientKit
import IMV2Core
import SwiftUI

/// Opt-in, UUID-scoped UI fixture: real journal, engines, services and views;
/// only remote authorization/recovery and unavailable byte I/O are substituted.
/// It runs exclusively behind the signed-out DEBUG test launch mode.
struct V2GroupAvatarRecoveryUITestView: View {
    private enum State { case loading, ready(RecoveryUIFixture), failed, cleaned }
    private enum Sheet: String, Identifiable { case pending; var id: String { rawValue } }
    let scope: UUID
    let cleanup: Bool
    @State private var state: State = .loading
    @State private var sheet: Sheet?

    var body: some View {
        NavigationStack {
            switch state {
            case .loading: ProgressView()
            case .failed: Text("测试资源初始化失败").accessibilityIdentifier("v2.resource-test.failed")
            case .cleaned: Text("测试数据已清理").accessibilityIdentifier("v2.resource-test.cleaned")
            case .ready(let fixture):
                Text("群已离开，原操作仍待确认")
                    .navigationTitle("资源恢复测试")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            V2ConversationAccountMenu(canOpenPublicIdentity: false, canOpenDeviceSessions: false,
                                canOpenPendingGroupAvatars: true, openPublicIdentity: {}, openDeviceSessions: {},
                                openPendingGroupAvatars: { sheet = .pending }, openPrivacySettings: {}, openAccountSecurity: {}, signOut: {})
                        }
                    }
                    .sheet(item: $sheet) { _ in V2PendingGroupAvatarsView(store: fixture.pending) }
            }
        }
        .task { await run() }
    }

    private func run() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("v2-resource-ui-" + scope.uuidString, isDirectory: true)
        do {
            if cleanup {
                if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                state = .cleaned; return
            }
            let fixture = try await RecoveryUIFixture.make(scope: scope, directory: directory)
            if Task.isCancelled { await fixture.close(); return }
            state = .ready(fixture)
            let lifetime = AsyncStream<Void>.makeStream()
            await withTaskCancellationHandler {
                for await _ in lifetime.stream { }
            } onCancel: { lifetime.continuation.finish() }
            sheet = nil; state = .loading
            await fixture.close()
        } catch { if !Task.isCancelled { state = .failed } }
    }
}

@MainActor
private struct RecoveryUIFixture {
    let pending: V2PendingGroupAvatarsStore
    let manager: V2GroupAvatarManagementService
    let intents: V2GroupAvatarIntentEngine
    let transfers: V2ResourceTransferEngine
    let notifier: V2ProjectionChangeNotifier
    let journal: GRDBV2LocalSyncStore

    static func make(scope: UUID, directory: URL) async throws -> Self {
        try await V2AccountActivationScope.withPrepared { activation in
            let actor = UserID(uuid: scope), device = DeviceID(uuid: scope)
            let journal = try await V2LocalStoreBootstrapper(bindingStore: RecoveryUIBinding(value: scope))
                .open(databaseURL: directory.appendingPathComponent("journal.sqlite"), userID: actor)
            activation.onDiscard { try await journal.close() }
            let boundary = RecoveryUIBoundary(actor: actor, device: device)
            let transfers = V2ResourceTransferEngine(store: journal, control: boundary, executor: boundary, directory: directory)
            activation.onDiscard { await transfers.close() }
            let intents = V2GroupAvatarIntentEngine(actorUserID: actor, store: journal, transfers: transfers, submissions: boundary, recovery: boundary)
            activation.onDiscard { await intents.close() }
            let manager = V2GroupAvatarManagementService(actorUserID: actor, deviceID: device, store: journal, intents: intents,
                reader: boundary, capabilities: boundary, directory: directory)
            activation.onDiscard { await manager.close() }
            let notifier = V2ProjectionChangeNotifier(localStore: journal)
            activation.onDiscard { await notifier.finish() }
            let command = try V2GroupAvatarCommand(operationID: .init(uuid: scope), roomID: .init(uuid: scope), expectedRevision: 0, mutation: .remove)
            if try await journal.groupAvatarIntent(command.operationID) == nil {
                _ = try await journal.freezeGroupAvatarIntent(actorUserID: actor, command: command, uploadJobID: nil)
                try await journal.requestGroupAvatarRecovery(command.operationID, action: .query)
            }
            let pending = V2PendingGroupAvatarsStore(reader: manager, notifier: notifier) { room, operation in
                .init(roomID: room, manager: manager, stager: boundary, notifier: notifier, focusedOperationID: operation)
            }
            try Task.checkCancellation()
            try activation.adopt()
            return .init(pending: pending, manager: manager, intents: intents, transfers: transfers, notifier: notifier, journal: journal)
        }
    }

    func close() async {
        await pending.close(); await manager.close(); await intents.close(); await transfers.close(); await notifier.finish()
        try? await journal.close()
    }
}

private struct RecoveryUIBinding: V2InstallationBindingStore {
    let value: UUID
    func load() -> V2LocalInstallationBinding? { .init(value: value) }
    func save(_ binding: V2LocalInstallationBinding) throws {
        guard binding.value == value else { throw V2InstallationBindingStoreError.malformedRecord }
    }
    func delete() throws { throw V2InstallationBindingStoreError.unavailable }
}

private struct RecoveryUIBoundary: V2GroupAvatarPresentationReading, V2ResourceCapabilityReading,
    V2GroupAvatarCommandSubmitting, V2GroupAvatarOperationRecovering, V2ResourceUploadControlling,
    V2ResourcePlanExecuting, V2ConversationAttachmentStaging {
    let actor: UserID, device: DeviceID
    func readGroupAvatar(roomID: RoomID) throws -> V2GroupAvatarPresentation { throw V2GroupAvatarReadError.forbidden }
    func capabilities() throws -> V2ResourceCapabilities { throw V2GroupAvatarManagementError.unavailable }
    func submitGroupAvatar(_ command: V2GroupAvatarCommand) throws -> V2GroupAvatarCommandResponse { throw V2GroupAvatarSubmissionError.outcomeUnknown }
    func recoverGroupAvatar(_ request: V2GroupAvatarRecoveryRequest) throws -> V2GroupAvatarRecoveryResponse {
        try .init(actorUserID: actor, deviceID: device, request: request, result: request.action == .query ? .unresolved : .closed)
    }
    func create(_ request: V2ResourceUploadRequest) throws -> V2ResourceUploadSession { throw V2GroupAvatarManagementError.unavailable }
    func status(_ locator: V2ResourceUploadLocator) throws -> V2ResourceUploadSession { throw V2GroupAvatarManagementError.unavailable }
    func target(_ session: V2ResourceUploadSession) throws -> V2ResourceTransferPlan? { throw V2GroupAvatarManagementError.unavailable }
    func finalize(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw V2GroupAvatarManagementError.unavailable }
    func cancel(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw V2GroupAvatarManagementError.unavailable }
    func upload(fileURL: URL, plan: V2ResourceTransferPlan) throws { throw V2GroupAvatarManagementError.unavailable }
    func stageImportedFile(at sourceURL: URL) throws -> V2StagedConversationAttachment { throw V2GroupAvatarManagementError.unavailable }
    func discard(_ attachment: V2StagedConversationAttachment) { }
}
#endif

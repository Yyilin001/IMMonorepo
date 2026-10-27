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
    private enum Sheet: String, Identifiable { case avatar; var id: String { rawValue } }
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
                V2AccountHomeView(displayName: "头像测试账号", handle: "@avatar-test",
                    canOpenPublicIdentity: false, canOpenDevices: false, canOpenSecurity: false,
                    openPublicIdentity: {}, openDevices: {}, openPrivacy: {}, openSecurity: {},
                    openFavorites: {}, signOut: {})
                    .navigationTitle("我的")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("群头像") { sheet = .avatar }
                                .accessibilityIdentifier("v2.resource-test.avatar.open")
                        }
                    }
                    .sheet(item: $sheet) { _ in V2GroupAvatarManagementView(store: fixture.page) }
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
            do {
                try await fixture.journal.runResourcePreparation { try await fixture.intents.recoverOnce() }
            } catch { }
            sheet = nil; state = .loading
            await fixture.close()
        } catch { if !Task.isCancelled { state = .failed } }
    }
}

@MainActor
private struct RecoveryUIFixture {
    let page: V2GroupAvatarManagementStore
    let manager: V2GroupAvatarManagementService
    let intents: V2GroupAvatarIntentEngine
    let transfers: V2ResourceTransferEngine
    let notifier: V2ProjectionChangeNotifier
    let journal: GRDBV2LocalSyncStore
    let resources: V2ResourceCenter

    static func make(scope: UUID, directory: URL) async throws -> Self {
        try await V2AccountActivationScope.withPrepared { activation in
            let actor = UserID(uuid: scope), device = DeviceID(uuid: scope)
            let storage = try await V2AccountStorageDirectory(root: directory, cacheRoot: directory.appending(path: "cache-scopes")).openScope(accountID: actor)
            let journal = try await V2LocalStoreBootstrapper(bindingStore: RecoveryUIBinding(value: scope))
                .open(databaseURL: storage.database.primary, userID: actor)
            activation.onDiscard { try await journal.close() }
            let resources = try await V2ResourceCenter.make(scope: storage, store: journal)
            activation.onDiscard { await resources.close() }
            let boundary = RecoveryUIBoundary(actor: actor, device: device, resolves: ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-resolve"))
            let transfers = V2ResourceTransferEngine(store: journal, control: boundary, executor: boundary, resources: resources)
            activation.onDiscard { await transfers.close() }
            let intents = V2GroupAvatarIntentEngine(actorUserID: actor, store: journal, transfers: transfers, submissions: boundary, recovery: boundary)
            activation.onDiscard { await intents.close() }
            let manager = V2GroupAvatarManagementService(actorUserID: actor, deviceID: device, store: journal, intents: intents,
                reader: boundary, capabilities: boundary, resources: resources)
            activation.onDiscard { await manager.close() }
            let notifier = V2ProjectionChangeNotifier(localStore: journal)
            activation.onDiscard { await notifier.finish() }
            let command = try V2GroupAvatarCommand(operationID: .init(uuid: scope), roomID: .init(uuid: scope), expectedRevision: 0, mutation: .remove)
            if try await journal.groupAvatarIntent(command.operationID) == nil {
                _ = try await journal.freezeGroupAvatarIntent(actorUserID: actor, command: command, uploadJobID: nil)
                _ = try? await intents.resume(command.operationID)
            }
            let page = V2GroupAvatarManagementStore(roomID: command.roomID, manager: manager,
                stager: boundary, notifier: notifier)
            try Task.checkCancellation()
            try activation.adopt()
            return .init(page: page, manager: manager, intents: intents, transfers: transfers, notifier: notifier, journal: journal, resources: resources)
        }
    }

    func close() async {
        page.suspend(); await manager.close(); await intents.close(); await transfers.close(); await notifier.finish()
        await resources.close(); try? await journal.close()
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
    let resolves: Bool
    func readGroupAvatar(roomID: RoomID) throws -> V2GroupAvatarPresentation { throw V2GroupAvatarReadError.forbidden }
    func capabilities() throws -> V2ResourceCapabilities { throw V2GroupAvatarManagementError.unavailable }
    func submitGroupAvatar(_ command: V2GroupAvatarCommand) throws -> V2GroupAvatarCommandResponse { throw V2GroupAvatarSubmissionError.authorizationDenied }
    func recoverGroupAvatar(_ request: V2GroupAvatarRecoveryRequest) throws -> V2GroupAvatarRecoveryResponse {
        guard resolves else { throw V2GroupAvatarSubmissionError.outcomeUnknown }
        return try .init(actorUserID: actor, deviceID: device, request: request, result: .closed)
    }
    func create(_ request: V2ResourceUploadRequest) throws -> V2ResourceUploadSession { throw V2GroupAvatarManagementError.unavailable }
    func status(_ locator: V2ResourceUploadLocator) throws -> V2ResourceUploadSession { throw V2GroupAvatarManagementError.unavailable }
    func target(_ session: V2ResourceUploadSession) throws -> V2ResourceTransferPlan? { throw V2GroupAvatarManagementError.unavailable }
    func finalize(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw V2GroupAvatarManagementError.unavailable }
    func cancel(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw V2GroupAvatarManagementError.unavailable }
    func upload(fileURL: URL, plan: V2ResourceTransferPlan) throws { throw V2GroupAvatarManagementError.unavailable }
    func stageImportedFile(at sourceURL: URL, purpose: V2LocalResourceAssetPurpose) throws -> V2StagedConversationAttachment { throw V2GroupAvatarManagementError.unavailable }
    func stageNormalizedPhoto(_ photo: V2NormalizedPhoto, purpose: V2LocalResourceAssetPurpose) throws -> V2StagedConversationAttachment { throw V2GroupAvatarManagementError.unavailable }
    func selectedAttachments(purpose: V2LocalResourceAssetPurpose) -> [V2StagedConversationAttachment] { [] }
    func borrow(_ context: V2LocalResourceReadContext) throws -> V2ResourceFileLease { throw V2ResourceStorageError.unavailable }
    func discard(_ attachment: V2StagedConversationAttachment) { }
}
#endif

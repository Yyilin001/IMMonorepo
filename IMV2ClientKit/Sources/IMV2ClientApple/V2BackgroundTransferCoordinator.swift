import IMV2ClientRuntime
import IMV2ClientNetwork
import IMV2ClientPlatform
import IMV2Core
import Foundation
#if os(iOS)
extension V2BackgroundTransferCoordinator {
    public nonisolated static func native(store:GRDBV2LocalSyncStore,scheduler:V2AccountWorkScheduler,
                                         resources:V2ResourceCenter,activationID:UUID,diagnostics:V2NetworkDiagnostics? = nil) async throws -> V2BackgroundTransferCoordinator {
        try await resources.withBackgroundSetup(onCancelledValue: { await $0.close() }) { files, scope in
            guard try await store.resourceFileJournal().accountID() == scope.accountID else { throw V2AccountStorageError.scopeMismatch }
            let id=try await store.backgroundSessionID(),root=scope.backgroundDirectory
            try Task.checkCancellation()
            let driver=try V2NativeBackgroundSession.shared(sessionID:id,root:root)
            return try .init(sessionID:id,activationID:activationID,store:store,scheduler:scheduler,driver:driver,files:files,root:root,diagnostics:diagnostics)
        }
    }

}
#endif

import IMV2ClientRuntime
import IMV2ClientNetwork
import IMV2ClientPlatform
import IMV2Core
import Foundation
#if os(iOS)
extension V2BackgroundDownloadCoordinator {
    public nonisolated static func native(accountID: UserID, store: GRDBV2LocalSyncStore,
        scheduler: V2AccountWorkScheduler, resources: V2ResourceCenter,
        resolver: any V2ClientMediaDownloadTargetResolver) async throws -> V2BackgroundDownloadCoordinator {
        try await resources.withBackgroundSetup(onCancelledValue: { await $0.close() }) { files, scope in
            guard accountID == scope.accountID, try await store.resourceFileJournal().accountID() == accountID else { throw V2AccountStorageError.scopeMismatch }
            let id = try await store.backgroundSessionID(), root = scope.backgroundDirectory
            try Task.checkCancellation()
            return try .init(sessionID: id, accountID: accountID, store: store, scheduler: scheduler,
                resolver: resolver, driver: V2NativeBackgroundSession.sharedDownload(sessionID: id, root: root), files: files, root: root)
        }
    }

}
#endif

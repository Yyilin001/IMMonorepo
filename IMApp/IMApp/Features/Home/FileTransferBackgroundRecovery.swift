import Foundation
import IMClientKit

@MainActor
extension FileTransferManager {
    func observeBackgroundTransfers() {
        runtimeController.observeBackgroundTransfers()
    }

    func applyRecoveredBackgroundTransfers(
        _ snapshots: [BackgroundTransferSnapshot],
        excludingTaskID: IMTransferTaskID? = nil
    ) {
        runtimeController.applyRecoveredBackgroundTransfers(
            snapshots,
            excludingTaskID: excludingTaskID
        )
    }

    func applyBackgroundTransferUpdate(_ snapshot: BackgroundTransferSnapshot) async {
        await runtimeController.applyBackgroundTransferUpdate(snapshot)
    }

    @discardableResult
    func applyRecoveredBackgroundDownloadCompletion(_ snapshot: BackgroundTransferSnapshot) -> Bool {
        runtimeController.applyRecoveredBackgroundDownloadCompletion(snapshot)
    }
}

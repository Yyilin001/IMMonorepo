import Foundation
import IMClientKit

@MainActor
extension FileTransferManager {
    func startDownload() {
        runtimeController.startDownload()
    }

    func cancelDownload(resetStatus: Bool = true) {
        runtimeController.cancelDownload(resetStatus: resetStatus)
    }
}

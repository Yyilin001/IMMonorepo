import Foundation
import IMClientKit

@MainActor
extension FileTransferManager {
    func startUpload() {
        runtimeController.startUpload()
    }

    func cancelUpload(resetStatus: Bool = true) {
        runtimeController.cancelUpload(resetStatus: resetStatus)
    }
}

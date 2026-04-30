import Foundation
import IMClientKit

typealias IMController = ConversationRuntimeController

extension IMMessageLocalDownloadState {
    var pausedProgress: IMMessageLocalDownloadProgressSnapshot? {
        switch status {
        case .downloading(let progress, _), .waitingForConnectivity(let progress, _), .paused(let progress):
            return progress
        case .downloaded, .failed:
            return nil
        }
    }
}

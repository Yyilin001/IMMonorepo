import Foundation
import IMClientKit
import SwiftUI
import UIKit

extension AuthManager: ProbeManagerDelegate {
    func probeManagerDidFetchUser(_ user: AuthUser) {
        markServerOnline()
        applySignedInState(user)
    }

    func probeManagerDidReceiveFailure(_ failure: ProbeFailureContext) async {
        if failure.shouldPreserveSession {
            if failure.shouldMarkServerOffline {
                markServerOfflineMessage(failure.message)
            }
        } else {
            await clearSession(message: failure.message)
        }
    }
}

extension AuthManager: FileTransferManagerDelegate {
    func fileTransferManagerDidSucceed() {
        markServerOnline()
    }

    func fileTransferManagerDidReceiveFailure(_ failure: ProbeFailureContext) async {
        if failure.shouldPreserveSession {
            if failure.shouldMarkServerOffline {
                markServerOfflineMessage(failure.message)
            }
        } else {
            await clearSession(message: failure.message)
        }
    }
}

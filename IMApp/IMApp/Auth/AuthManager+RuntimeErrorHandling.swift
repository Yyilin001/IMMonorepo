import Foundation
import IMClientKit
import SwiftUI
import UIKit

@MainActor
extension AuthManager {
    func scheduleIMConversationSummaryReadModelCorrection(force: Bool = false) {
        conversationRuntimeController.scheduleConversationSummaryReadModelCorrection(force: force)
    }

    func handleIMDataRequestError(_ error: Error) async {
        imConversationStore.setStatusMessage(error.localizedDescription)

        if await shouldPreserveSession(for: error) {
            await markServerUnavailableIfNeeded(for: error)
        } else {
            await clearSession(message: error.localizedDescription)
        }
    }

    func handleContactRequestError(_ error: Error) async {
        contactsMessage = error.localizedDescription

        if await shouldPreserveSession(for: error) {
            await markServerUnavailableIfNeeded(for: error)
        } else {
            await clearSession(message: error.localizedDescription)
        }
    }

    func handleContactRequestsLoadError(_ error: Error) async {
        contactRequestsLoadMessage = error.localizedDescription

        if await shouldPreserveSession(for: error) {
            await markServerUnavailableIfNeeded(for: error)
        } else {
            await clearSession(message: error.localizedDescription)
        }
    }

    func handleContactRequestsActionError(_ error: Error) async {
        contactRequestActionMessage = error.localizedDescription

        if await shouldPreserveSession(for: error) {
            await markServerUnavailableIfNeeded(for: error)
        } else {
            await clearSession(message: error.localizedDescription)
        }
    }

    func shouldPreserveSession(for error: Error) async -> Bool {
        await sessionFacade.shouldPreserveSession(for: error)
    }

    func markServerUnavailableIfNeeded(for error: Error) async {
        if await sessionFacade.shouldMarkServerOffline(for: error) {
            markServerOffline(error)
        }
    }

    func markServerOnline() {
        serverStatus = .online
    }

    func markServerOffline(_ error: Error) {
        serverStatus = .offline(message: error.localizedDescription)
    }

    func markServerOfflineMessage(_ message: String) {
        serverStatus = .offline(message: message)
    }

    static func deviceMetadata() -> DeviceMetadataPayload {
        let info = Bundle.main.infoDictionary
        return DeviceMetadataPayload(
            deviceID: (try? KeychainDeviceIdentityStore().currentDeviceID())
                ?? UIDevice.current.identifierForVendor?.uuidString,
            deviceName: UIDevice.current.model,
            platform: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            appVersion: info?["CFBundleShortVersionString"] as? String
        )
    }
}

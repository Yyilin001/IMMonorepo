import Combine
import Foundation
import IMClientKit
import SwiftUI
import UIKit

@MainActor
extension AuthManager {
    func scheduleIMConnectionIfNeeded() {
        conversationRuntimeController.scheduleConnectionIfNeeded()
    }

    func disconnectIMConnection(flushCache: Bool = true) async {
        await conversationRuntimeController.disconnect(flushCache: flushCache)
    }

    func scheduleIMConversationBootstrap(for user: AuthUser) {
        imConversationListTask?.cancel()
        imConversationListTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.imConversationListTask = nil
            }
            await self.restoreIMConversationCacheIfAvailable(for: user)
            await self.reloadIMConversations(force: true)
        }
    }
}

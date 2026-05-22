import Foundation
import IMClientKit

@MainActor
extension AuthManager {
    func makeSessionRuntimeController() -> SessionRuntimeController {
        SessionRuntimeController(context: SessionRuntimeContext(
            sessionFacade: sessionFacade,
            sessionStore: sessionStore,
            currentUserProvider: { [weak self] in
                self?.currentUser
            },
            disconnectIMConnection: { [weak self] in
                guard let self else {
                    return
                }
                await self.disconnectIMConnection()
            },
            resetForSignedOut: { [weak self] signedOutUserID in
                guard let self else {
                    return
                }
                await self.resetApplicationStateForSignedOut(signedOutUserID: signedOutUserID)
            },
            startSignedInFeatures: { [weak self] user in
                self?.startSignedInFeatures(for: user)
            },
            shouldPreserveSession: { [weak self] error in
                await self?.shouldPreserveSession(for: error) ?? false
            },
            markServerUnavailableIfNeeded: { [weak self] error in
                guard let self else {
                    return
                }
                await self.markServerUnavailableIfNeeded(for: error)
            },
            markServerOnline: { [weak self] in
                self?.markServerOnline()
            },
            markServerOfflineMessage: { [weak self] message in
                self?.markServerOfflineMessage(message)
            },
            deviceMetadataProvider: {
                Self.deviceMetadata()
            }
        ))
    }
}

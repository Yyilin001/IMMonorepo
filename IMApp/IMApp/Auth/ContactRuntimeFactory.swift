import Foundation
import IMClientKit

@MainActor
extension AuthManager {
    func makeContactRuntimeController() -> ContactRuntimeController {
        ContactRuntimeController(context: ContactRuntimeContext(
            sessionFacade: sessionFacade,
            sessionClient: sessionClient,
            contactStore: contactStore,
            currentUserProvider: { [weak self] in
                self?.currentUser
            },
            markServerOnline: { [weak self] in
                self?.markServerOnline()
            },
            markServerUnavailableIfNeeded: { [weak self] error in
                guard let self else {
                    return
                }
                await self.markServerUnavailableIfNeeded(for: error)
            },
            shouldPreserveSession: { [weak self] error in
                await self?.shouldPreserveSession(for: error) ?? false
            },
            clearSession: { [weak self] message in
                guard let self else {
                    return
                }
                await self.clearSession(message: message)
            },
            handleIMDataRequestError: { [weak self] error in
                guard let self else {
                    return
                }
                await self.handleIMDataRequestError(error)
            }
        ))
    }
}

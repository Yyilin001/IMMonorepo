import Testing
@testable import IMApp

@MainActor
struct V2AppStoreTests {
    @Test("UI test startup mode bypasses device state and remains signed out")
    func uiTestingStartupModeStaysSignedOut() async {
        let store = V2AppStore(startupMode: .uiTestingSignedOut)

        await store.restore()

        #expect(store.route == .signedOut)
        #expect(store.authenticationMessage == nil)
    }
}

//
//  IMAppUITests.swift
//  IMAppUITests
//
//  Created by yy on 2026/3/25.
//

import XCTest

final class IMAppUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}

extension XCUIApplication {
    func contactRequestRow(id: String) -> XCUIElement {
        descendants(matching: .any)["contacts.request.row.\(id)"]
    }

    func blockedUserRow(id: String) -> XCUIElement {
        descendants(matching: .any)["contacts.blocked.row.\(id)"]
    }
}

extension XCUIElement {
    func contactRequestAction(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier]
    }

    var contactRequestAcceptButton: XCUIElement {
        contactRequestAction("contacts.request.accept")
    }

    var contactRequestRejectButton: XCUIElement {
        contactRequestAction("contacts.request.reject")
    }

    var contactRequestCancelButton: XCUIElement {
        contactRequestAction("contacts.request.cancel")
    }

    var contactRequestResendButton: XCUIElement {
        contactRequestAction("contacts.request.resend")
    }

    var contactRequestMessageButton: XCUIElement {
        contactRequestAction("contacts.request.message")
    }

    var blockedUserUnblockButton: XCUIElement {
        descendants(matching: .any)["contacts.blocked.unblock"]
    }
}

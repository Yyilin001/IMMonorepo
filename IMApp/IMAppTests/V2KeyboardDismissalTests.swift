import Testing
import UIKit
@testable import IMApp

@MainActor
struct V2KeyboardDismissalTests {
    @Test func blankAreasDismissButInputsAndControlsKeepTheirTouches() {
        let blank = UIView()
        #expect(V2KeyboardDismissal.Coordinator.shouldDismiss(touching: blank))
        for control in [UITextField(), UITextView(), UIButton()] as [UIView] {
            let child = UIView()
            control.addSubview(child)
            #expect(!V2KeyboardDismissal.Coordinator.shouldDismiss(touching: child))
        }
        #expect(!V2KeyboardDismissal.Coordinator.shouldDismiss(touching: nil))
    }

    @Test func attachmentIsIdempotentAndMovesBetweenWindows() {
        let coordinator = V2KeyboardDismissal.Coordinator()
        let first = UIWindow(), second = UIWindow()
        let initialCount = first.gestureRecognizers?.count ?? 0
        coordinator.attach(to: first)
        coordinator.attach(to: first)
        #expect(first.gestureRecognizers?.count == initialCount + 1)
        let gesture = first.gestureRecognizers!.last!
        #expect(!gesture.cancelsTouchesInView)
        coordinator.attach(to: second)
        #expect(!(first.gestureRecognizers ?? []).contains(gesture))
        #expect((second.gestureRecognizers ?? []).contains(gesture))
        coordinator.attach(to: nil)
        #expect(!(second.gestureRecognizers ?? []).contains(gesture))
    }
}
